"""
TechStream Self-Healing Lambda — Remediation Handler

Triggered by: EventBridge (CloudWatch ALARM state change) or SNS

Remediation runbook (in priority order):
  1. Log the incident with full context
  2. Notify on-call via SNS
  3. Attempt service restart via SSM Run Command on all ALARM instances
  4. If restart fails or alarm persists → scale out the ASG by 2 instances
  5. Emit remediation metrics to CloudWatch
"""
import json
import logging
import os
import time
from datetime import datetime, timezone
from typing import Any, Optional

import boto3
from botocore.exceptions import ClientError

# ─── Configuration ────────────────────────────────────────────────────────────
LOG_LEVEL     = os.environ.get("LOG_LEVEL", "INFO").upper()
ASG_NAME      = os.environ.get("ASG_NAME", "")
ASG_MAX_SIZE  = int(os.environ.get("ASG_MAX_SIZE", "6"))
SNS_TOPIC_ARN = os.environ.get("SNS_TOPIC_ARN", "")
REGION        = os.environ.get("REGION", "us-east-1")
SERVICE_NAME  = "techstream"

logging.basicConfig(level=getattr(logging, LOG_LEVEL))
logger = logging.getLogger("remediation")

# AWS clients
ssm = boto3.client("ssm",            region_name=REGION)
asg = boto3.client("autoscaling",    region_name=REGION)
cw  = boto3.client("cloudwatch",     region_name=REGION)
sns = boto3.client("sns",            region_name=REGION)
ec2 = boto3.client("ec2",            region_name=REGION)


# ─── Entry Point ──────────────────────────────────────────────────────────────

def lambda_handler(event: dict, context: Any) -> dict:
    logger.info("Remediation triggered. Event source: %s", _detect_source(event))
    logger.debug("Full event: %s", json.dumps(event, default=str))

    alarm_info = _extract_alarm_info(event)
    if not alarm_info:
        logger.warning("Could not parse alarm info from event — skipping remediation")
        return {"status": "skipped", "reason": "unparseable_event"}

    logger.info("Processing alarm: %s (state: %s)", alarm_info["name"], alarm_info["state"])

    # Only remediate ALARM state — skip OK transitions
    if alarm_info["state"] != "ALARM":
        logger.info("Alarm transitioned to %s — no remediation needed", alarm_info["state"])
        return {"status": "ok", "reason": "not_alarm_state"}

    start_ts = datetime.now(timezone.utc).isoformat()
    remediation_result = {
        "alarm_name":   alarm_info["name"],
        "trigger_time": start_ts,
        "steps":        [],
    }

    # Step 1 — Notify on-call
    _step_notify(alarm_info, remediation_result)

    # Step 2 — Get degraded instances from ASG
    instance_ids = _get_unhealthy_instances()
    healthy_ids  = _get_all_asg_instances()
    logger.info("Unhealthy instances: %s", instance_ids)
    logger.info("All ASG instances:   %s", healthy_ids)

    # Step 3 — Try SSM service restart on unhealthy instances
    restart_success = False
    if instance_ids:
        restart_success = _step_ssm_restart(instance_ids, remediation_result)
    else:
        # No specific instance is unhealthy; restart all
        if healthy_ids:
            restart_success = _step_ssm_restart(healthy_ids[:1], remediation_result)

    # Step 4 — If restart failed (or no instances), scale out ASG
    if not restart_success:
        _step_scale_out(remediation_result)

    # Step 5 — Emit remediation outcome metric
    _emit_remediation_metric(alarm_info["name"], restart_success)

    # Step 6 — Post-remediation summary notification
    _notify_summary(alarm_info, remediation_result)

    logger.info("Remediation complete: %s", json.dumps(remediation_result, default=str))
    return {"status": "remediated", "details": remediation_result}


# ─── Alarm Parsing ────────────────────────────────────────────────────────────

def _detect_source(event: dict) -> str:
    if "source" in event and event.get("source") == "aws.cloudwatch":
        return "eventbridge"
    if "Records" in event and event["Records"][0].get("EventSource") == "aws:sns":
        return "sns"
    return "unknown"


def _extract_alarm_info(event: dict) -> Optional[dict]:
    try:
        # EventBridge format
        if event.get("source") == "aws.cloudwatch":
            detail = event.get("detail", {})
            return {
                "name":        detail.get("alarmName", ""),
                "state":       detail.get("state", {}).get("value", ""),
                "reason":      detail.get("state", {}).get("reason", ""),
                "metric":      detail.get("configuration", {}).get("metrics", []),
                "description": detail.get("configuration", {}).get("description", ""),
            }
        # SNS format (CloudWatch alarm notification)
        if "Records" in event:
            for record in event["Records"]:
                if record.get("EventSource") == "aws:sns":
                    msg = json.loads(record["Sns"]["Message"])
                    return {
                        "name":        msg.get("AlarmName", ""),
                        "state":       msg.get("NewStateValue", ""),
                        "reason":      msg.get("NewStateReason", ""),
                        "metric":      msg.get("Trigger", {}),
                        "description": msg.get("AlarmDescription", ""),
                    }
    except (KeyError, json.JSONDecodeError, TypeError) as exc:
        logger.error("Failed to parse alarm info: %s", exc)
    return None


# ─── Step Implementations ─────────────────────────────────────────────────────

def _step_notify(alarm_info: dict, result: dict):
    """Send an incident notification via SNS."""
    if not SNS_TOPIC_ARN:
        logger.warning("SNS_TOPIC_ARN not set — skipping initial notification")
        return

    subject = f"[INCIDENT] Alarm TRIGGERED: {alarm_info['name']}"
    message = (
        f"Self-Healing System — Incident Detected\n"
        f"{'='*50}\n"
        f"Alarm:       {alarm_info['name']}\n"
        f"State:       {alarm_info['state']}\n"
        f"Time:        {datetime.now(timezone.utc).isoformat()}\n"
        f"Reason:      {alarm_info['reason']}\n"
        f"Description: {alarm_info['description']}\n\n"
        f"Automated remediation has been initiated.\n"
        f"ASG: {ASG_NAME}\n"
    )
    try:
        sns.publish(TopicArn=SNS_TOPIC_ARN, Subject=subject, Message=message)
        result["steps"].append({"step": "notify_oncall", "status": "sent"})
        logger.info("Incident notification sent")
    except ClientError as exc:
        logger.error("SNS notification failed: %s", exc)
        result["steps"].append({"step": "notify_oncall", "status": "failed", "error": str(exc)})


def _get_unhealthy_instances() -> list:
    """Return instance IDs currently marked Unhealthy in the ASG."""
    try:
        resp = asg.describe_auto_scaling_groups(AutoScalingGroupNames=[ASG_NAME])
        groups = resp.get("AutoScalingGroups", [])
        if not groups:
            return []
        return [
            i["InstanceId"]
            for i in groups[0].get("Instances", [])
            if i.get("HealthStatus") == "Unhealthy" and i.get("LifecycleState") == "InService"
        ]
    except ClientError as exc:
        logger.error("Failed to get unhealthy instances: %s", exc)
        return []


def _get_all_asg_instances() -> list:
    """Return all InService instance IDs in the ASG."""
    try:
        resp = asg.describe_auto_scaling_groups(AutoScalingGroupNames=[ASG_NAME])
        groups = resp.get("AutoScalingGroups", [])
        if not groups:
            return []
        return [
            i["InstanceId"]
            for i in groups[0].get("Instances", [])
            if i.get("LifecycleState") == "InService"
        ]
    except ClientError as exc:
        logger.error("Failed to get ASG instances: %s", exc)
        return []


def _step_ssm_restart(instance_ids: list, result: dict) -> bool:
    """
    Send SSM Run Command to restart the techstream service on the given instances.
    Returns True if ALL commands succeeded.
    """
    if not instance_ids:
        logger.info("No instances to restart")
        return False

    restart_script = f"""
#!/bin/bash
set -euo pipefail
echo "[$(date)] Starting remediation restart of {SERVICE_NAME}"

# Graceful restart attempt
if systemctl is-active --quiet {SERVICE_NAME}; then
    systemctl restart {SERVICE_NAME}
    sleep 5
    if systemctl is-active --quiet {SERVICE_NAME}; then
        echo "[$(date)] Service restarted successfully"
        exit 0
    fi
fi

# Force restart if graceful failed
systemctl stop {SERVICE_NAME} || true
sleep 2
systemctl start {SERVICE_NAME}
sleep 5

if systemctl is-active --quiet {SERVICE_NAME}; then
    echo "[$(date)] Service force-started successfully"
    exit 0
else
    echo "[$(date)] ERROR: Service failed to start"
    journalctl -u {SERVICE_NAME} --no-pager -n 30
    exit 1
fi
"""

    try:
        logger.info("Sending SSM restart command to instances: %s", instance_ids)
        resp = ssm.send_command(
            InstanceIds=instance_ids,
            DocumentName="AWS-RunShellScript",
            Parameters={"commands": [restart_script]},
            Comment=f"Self-healing restart of {SERVICE_NAME}",
            TimeoutSeconds=120,
        )
        command_id = resp["Command"]["CommandId"]
        result["steps"].append({
            "step":       "ssm_restart",
            "status":     "sent",
            "command_id": command_id,
            "instances":  instance_ids,
        })

        # Poll for completion (max 90s)
        success = _wait_for_ssm_command(command_id, instance_ids)
        result["steps"][-1]["outcome"] = "success" if success else "failed"
        logger.info("SSM restart outcome: %s", "success" if success else "failed")
        return success

    except ClientError as exc:
        logger.error("SSM command failed: %s", exc)
        result["steps"].append({"step": "ssm_restart", "status": "error", "error": str(exc)})
        return False


def _wait_for_ssm_command(command_id: str, instance_ids: list, timeout: int = 90) -> bool:
    """Poll SSM until the command finishes or times out. Returns True if all succeeded."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        time.sleep(5)
        all_done = True
        all_success = True
        for iid in instance_ids:
            try:
                inv = ssm.get_command_invocation(CommandId=command_id, InstanceId=iid)
                status = inv.get("StatusDetails", "Pending")
                logger.debug("SSM %s on %s: %s", command_id, iid, status)
                if status in ("Pending", "InProgress", "Delayed"):
                    all_done = False
                elif status not in ("Success",):
                    all_success = False
            except ClientError:
                all_done = False
        if all_done:
            return all_success
    logger.warning("SSM command timed out after %ds", timeout)
    return False


def _step_scale_out(result: dict):
    """Scale out the ASG by 2 to absorb load when restart alone is insufficient."""
    try:
        resp = asg.describe_auto_scaling_groups(AutoScalingGroupNames=[ASG_NAME])
        groups = resp.get("AutoScalingGroups", [])
        if not groups:
            logger.error("ASG %s not found", ASG_NAME)
            return

        group      = groups[0]
        current    = group["DesiredCapacity"]
        max_cap    = group["MaxSize"]
        new_desired = min(current + 2, max_cap)

        if new_desired <= current:
            logger.warning("Already at max capacity (%d) — cannot scale further", max_cap)
            result["steps"].append({
                "step":   "scale_out",
                "status": "skipped",
                "reason": "already_at_max_capacity",
            })
            return

        logger.info("Scaling ASG %s: %d → %d (max: %d)", ASG_NAME, current, new_desired, max_cap)
        asg.set_desired_capacity(
            AutoScalingGroupName=ASG_NAME,
            DesiredCapacity=new_desired,
            HonorCooldown=False,
        )
        result["steps"].append({
            "step":        "scale_out",
            "status":      "success",
            "from":        current,
            "to":          new_desired,
        })
        logger.info("Scale-out initiated: %d → %d", current, new_desired)

    except ClientError as exc:
        logger.error("Scale-out failed: %s", exc)
        result["steps"].append({"step": "scale_out", "status": "error", "error": str(exc)})


def _emit_remediation_metric(alarm_name: str, restarted: bool):
    """Push a custom metric so we can graph MTTR and remediation success rate."""
    try:
        cw.put_metric_data(
            Namespace="TechStream/Remediation",
            MetricData=[
                {
                    "MetricName": "RemediationAttempt",
                    "Value":      1,
                    "Unit":       "Count",
                    "Dimensions": [{"Name": "AlarmName", "Value": alarm_name}],
                },
                {
                    "MetricName": "RestartSuccess" if restarted else "RestartFailed",
                    "Value":      1,
                    "Unit":       "Count",
                    "Dimensions": [{"Name": "AlarmName", "Value": alarm_name}],
                },
            ],
        )
    except ClientError as exc:
        logger.warning("Failed to emit remediation metric: %s", exc)


def _notify_summary(alarm_info: dict, result: dict):
    """Send a post-remediation summary notification."""
    if not SNS_TOPIC_ARN:
        return

    steps_summary = "\n".join(
        f"  [{s.get('status', '?').upper()}] {s.get('step', '?')}: "
        + json.dumps({k: v for k, v in s.items() if k not in ("step", "status")})
        for s in result.get("steps", [])
    )
    subject = f"[REMEDIATION] Steps completed for: {alarm_info['name']}"
    message = (
        f"Self-Healing Remediation Summary\n"
        f"{'='*50}\n"
        f"Alarm:    {alarm_info['name']}\n"
        f"Trigger:  {result['trigger_time']}\n"
        f"Complete: {datetime.now(timezone.utc).isoformat()}\n\n"
        f"Steps Executed:\n{steps_summary}\n\n"
        f"Monitor the CloudWatch dashboard to confirm recovery.\n"
    )
    try:
        sns.publish(TopicArn=SNS_TOPIC_ARN, Subject=subject, Message=message)
    except ClientError as exc:
        logger.error("Post-remediation notification failed: %s", exc)
