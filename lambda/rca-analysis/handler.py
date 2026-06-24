"""
TechStream AI-Assisted Root Cause Analysis Lambda

Triggered by:
  - EventBridge: DevOps Guru "New Insight Open" events
  - Direct invocation for on-demand analysis

Analysis pipeline:
  1. Fetch recent CloudWatch Logs around the incident window
  2. Query DevOps Guru for correlated anomalies and recommendations
  3. Send logs + anomaly data to Amazon Bedrock (Claude) for RCA narrative
  4. Publish the RCA report to SNS and store in CloudWatch Logs
"""
import json
import logging
import os
import time
from datetime import datetime, timedelta, timezone
from typing import Any, Optional

import boto3
from botocore.exceptions import ClientError

# ─── Configuration ────────────────────────────────────────────────────────────
LOG_LEVEL     = os.environ.get("LOG_LEVEL", "INFO").upper()
SNS_TOPIC_ARN = os.environ.get("SNS_TOPIC_ARN", "")
REGION        = os.environ.get("REGION", "us-east-1")
APP_LOG_GROUP = os.environ.get("APP_LOG_GROUP", "/techstream/app")
# Bedrock model for RCA — Claude Haiku for speed + cost, Sonnet for quality
BEDROCK_MODEL = os.environ.get("BEDROCK_MODEL_ID", "anthropic.claude-3-haiku-20240307-v1:0")

logging.basicConfig(level=getattr(logging, LOG_LEVEL))
logger = logging.getLogger("rca-analysis")

logs    = boto3.client("logs",       region_name=REGION)
dg      = boto3.client("devops-guru",region_name=REGION)
bedrock = boto3.client("bedrock-runtime", region_name=REGION)
sns     = boto3.client("sns",        region_name=REGION)


# ─── Entry Point ──────────────────────────────────────────────────────────────

def lambda_handler(event: dict, context: Any) -> dict:
    logger.info("RCA analysis triggered")
    logger.debug("Event: %s", json.dumps(event, default=str))

    insight_id   = _extract_insight_id(event)
    incident_end = datetime.now(timezone.utc)
    incident_start = incident_end - timedelta(minutes=30)

    # Step 1 — Fetch log evidence
    log_evidence = _fetch_log_evidence(incident_start, incident_end)

    # Step 2 — Fetch DevOps Guru anomalies
    dg_context = _fetch_devops_guru_context(insight_id) if insight_id else {}

    # Step 3 — AI-powered RCA via Bedrock
    rca_report = _run_ai_rca(log_evidence, dg_context, incident_start, incident_end)

    # Step 4 — Publish report
    _publish_rca_report(rca_report, insight_id)

    return {"status": "completed", "insight_id": insight_id, "rca_length": len(rca_report)}


# ─── DevOps Guru Context ─────────────────────────────────────────────────────

def _extract_insight_id(event: dict) -> Optional[str]:
    try:
        if event.get("source") == "aws.devops-guru":
            return event["detail"]["insightId"]
    except (KeyError, TypeError):
        pass
    return event.get("insight_id")


def _fetch_devops_guru_context(insight_id: str) -> dict:
    """Retrieve the DevOps Guru insight and its associated anomalies."""
    context = {}
    try:
        insight_resp = dg.describe_insight(Id=insight_id)
        insight      = insight_resp.get("ReactiveInsight") or insight_resp.get("ProactiveInsight") or {}
        context["insight"] = {
            "id":          insight.get("Id"),
            "name":        insight.get("Name"),
            "severity":    insight.get("Severity"),
            "status":      insight.get("Status"),
            "description": insight.get("Description", ""),
        }

        # Fetch correlated anomalies
        anomalies = []
        paginator = dg.get_paginator("list_anomalies_for_insight")
        for page in paginator.paginate(InsightId=insight_id):
            for anomaly in page.get("ReactiveAnomalies", []) + page.get("ProactiveAnomalies", []):
                anomalies.append({
                    "id":          anomaly.get("Id"),
                    "type":        anomaly.get("Type"),
                    "severity":    anomaly.get("Severity"),
                    "description": str(anomaly.get("AnomalyReportedTimeRange", {})),
                })
        context["anomalies"] = anomalies[:10]  # cap for prompt size
        logger.info("Fetched DevOps Guru context: %d anomalies", len(anomalies))
    except ClientError as exc:
        logger.warning("DevOps Guru fetch failed (non-fatal): %s", exc)
    return context


# ─── CloudWatch Logs Evidence ─────────────────────────────────────────────────

def _fetch_log_evidence(start: datetime, end: datetime) -> dict:
    """
    Run CloudWatch Logs Insights queries to extract error patterns,
    latency spikes, and request distributions from the incident window.
    """
    evidence = {}

    queries = {
        "error_summary": f"""
fields @timestamp, message, status_code, response_time_ms, instance_id
| filter level = "ERROR" or status_code >= 500
| stats count() as error_count by bin(1m)
| sort @timestamp desc
| limit 50
""",
        "latency_p99": f"""
fields @timestamp, response_time_ms, path, instance_id
| filter ispresent(response_time_ms)
| stats pct(response_time_ms, 99) as p99, pct(response_time_ms, 50) as p50,
        count() as requests by bin(1m)
| sort @timestamp desc
| limit 30
""",
        "top_errors": f"""
fields message, status_code, path
| filter level = "ERROR"
| stats count() as cnt by message
| sort cnt desc
| limit 10
""",
    }

    start_ms = int(start.timestamp() * 1000)
    end_ms   = int(end.timestamp() * 1000)

    for name, query in queries.items():
        try:
            resp = logs.start_query(
                logGroupName=APP_LOG_GROUP,
                startTime=start_ms,
                endTime=end_ms,
                queryString=query,
            )
            query_id = resp["queryId"]
            results  = _poll_logs_query(query_id)
            evidence[name] = results
        except ClientError as exc:
            logger.warning("Log query '%s' failed: %s", name, exc)
            evidence[name] = []

    logger.info("Log evidence collected: %d query results", len(evidence))
    return evidence


def _poll_logs_query(query_id: str, timeout: int = 60) -> list:
    """Poll a CloudWatch Logs Insights query until complete."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        resp   = logs.get_query_results(queryId=query_id)
        status = resp.get("status")
        if status == "Complete":
            return resp.get("results", [])
        if status in ("Failed", "Cancelled", "Timeout"):
            logger.warning("Query %s ended with status: %s", query_id, status)
            return []
        time.sleep(3)
    return []


# ─── AI RCA via Amazon Bedrock ────────────────────────────────────────────────

def _run_ai_rca(log_evidence: dict, dg_context: dict, start: datetime, end: datetime) -> str:
    """
    Send incident evidence to Claude via Bedrock and receive an RCA narrative.
    Falls back to a structured text summary if Bedrock is unavailable.
    """
    incident_window = f"{start.isoformat()} → {end.isoformat()} UTC"

    # Serialise evidence compactly for the prompt
    evidence_text = json.dumps({
        "cloudwatch_logs": log_evidence,
        "devops_guru":     dg_context,
    }, indent=2, default=str)

    # Truncate to ~8k chars to stay within Bedrock context limits
    if len(evidence_text) > 8000:
        evidence_text = evidence_text[:8000] + "\n...[truncated]"

    prompt = f"""You are a senior Site Reliability Engineer performing a Root Cause Analysis (RCA) for the TechStream platform.

## Incident Window
{incident_window}

## Evidence
{evidence_text}

## Instructions
Analyse the evidence above and produce a concise RCA report with the following sections:

1. **Executive Summary** (2-3 sentences): What happened and what was the customer impact?
2. **Root Cause**: The specific technical cause (be precise — name metrics, error messages, instance IDs).
3. **Contributing Factors**: Any secondary conditions that amplified the incident.
4. **Timeline**: Key events reconstructed from the log evidence.
5. **Automated Remediation Applied**: What the self-healing system did.
6. **Recommended Follow-up Actions**: 3-5 concrete items to prevent recurrence (with owners).
7. **Golden Signal Analysis**:
   - Latency: (p50/p99 values and trend)
   - Traffic: (request rate and any anomalies)
   - Errors: (error rate, types, affected endpoints)
   - Saturation: (CPU/memory pressure indicators)

Keep the report factual, precise, and actionable. Avoid speculation not supported by the evidence."""

    try:
        body = json.dumps({
            "anthropic_version": "bedrock-2023-05-31",
            "max_tokens": 2000,
            "messages": [{"role": "user", "content": prompt}],
        })
        resp = bedrock.invoke_model(
            modelId=BEDROCK_MODEL,
            body=body,
            contentType="application/json",
            accept="application/json",
        )
        result     = json.loads(resp["body"].read())
        rca_text   = result["content"][0]["text"]
        logger.info("Bedrock RCA generated (%d chars)", len(rca_text))
        return rca_text

    except ClientError as exc:
        logger.error("Bedrock invocation failed: %s", exc)
        return _fallback_rca(log_evidence, dg_context, incident_window)


def _fallback_rca(log_evidence: dict, dg_context: dict, window: str) -> str:
    """Produce a structured RCA without AI when Bedrock is unavailable."""
    error_count = len(log_evidence.get("error_summary", []))
    top_errors  = log_evidence.get("top_errors", [])
    anomalies   = dg_context.get("anomalies", [])

    error_list = "\n".join(
        f"  - {e[0]['value'] if e else 'unknown'}"
        for e in top_errors[:5]
    ) or "  No errors captured"

    anom_list = "\n".join(
        f"  - [{a.get('severity')}] {a.get('type')}: {a.get('description')}"
        for a in anomalies[:5]
    ) or "  No DevOps Guru anomalies available"

    return f"""# TechStream Incident RCA (Automated)

## Incident Window
{window}

## Error Summary
Approximately {error_count} error data points captured in the incident window.

## Top Error Types
{error_list}

## DevOps Guru Anomalies
{anom_list}

## Note
Amazon Bedrock was unavailable for AI-assisted analysis.
Review the CloudWatch Logs Insights queries and DevOps Guru insights console
for full correlation details.

## Recommended Actions
1. Review CloudWatch Dashboard for Golden Signal trends during the incident window.
2. Check DevOps Guru console for full insight details and recommendations.
3. Verify that automated remediation (SSM restart / ASG scale-out) resolved the issue.
4. Update runbook with findings.
"""


# ─── Publish Report ───────────────────────────────────────────────────────────

def _publish_rca_report(rca_report: str, insight_id: Optional[str]):
    """Publish the RCA report to SNS and to CloudWatch Logs."""
    # SNS
    if SNS_TOPIC_ARN:
        subject = f"[RCA REPORT] TechStream Incident Analysis" + (
            f" — Insight {insight_id}" if insight_id else ""
        )
        try:
            sns.publish(TopicArn=SNS_TOPIC_ARN, Subject=subject[:100], Message=rca_report)
            logger.info("RCA report published to SNS")
        except ClientError as exc:
            logger.error("SNS publish failed: %s", exc)

    # CloudWatch Logs — store for audit trail
    try:
        log_group  = "/techstream/rca-reports"
        log_stream = f"rca-{datetime.now(timezone.utc).strftime('%Y%m%d-%H%M%S')}"
        try:
            logs.create_log_group(logGroupName=log_group)
        except ClientError:
            pass  # already exists
        try:
            logs.create_log_stream(logGroupName=log_group, logStreamName=log_stream)
        except ClientError:
            pass
        logs.put_log_events(
            logGroupName=log_group,
            logStreamName=log_stream,
            logEvents=[{
                "timestamp": int(datetime.now(timezone.utc).timestamp() * 1000),
                "message":   rca_report,
            }],
        )
        logger.info("RCA report stored in CloudWatch Logs: %s/%s", log_group, log_stream)
    except ClientError as exc:
        logger.warning("Failed to store RCA in CloudWatch Logs: %s", exc)
