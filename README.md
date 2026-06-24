# TechStream Self-Healing System

> **Goal:** Reduce MTTR by detecting anomalies and automatically remediating incidents before waking an engineer.

## Architecture Overview

```
Internet
    │
    ▼
┌───────────────────────────────────────────────────────┐
│                Application Load Balancer              │
│           (Golden Signal: Traffic + Errors)           │
└─────────────────────────┬─────────────────────────────┘
                          │
              ┌───────────▼────────────┐
              │   Auto Scaling Group   │ ◄── Scale-out remediation
              │  (2-6 × EC2 t3.micro) │
              │  ┌─────────────────┐  │
              │  │  Flask App      │  │
              │  │  + CW Agent     │  │
              │  └─────────────────┘  │
              └────────────┬──────────┘
                           │ metrics + logs
                           ▼
┌──────────────────────────────────────────────────────────────────┐
│                     CloudWatch                                   │
│  ┌────────────────┐  ┌─────────────────┐  ┌──────────────────┐  │
│  │ Golden Signals │  │  Log Groups      │  │  Custom Metrics  │  │
│  │  Dashboard     │  │  (structured)    │  │ TechStream/App   │  │
│  └───────┬────────┘  └──────┬──────────┘  └────────┬─────────┘  │
│          │                  │                       │            │
│          └──────────────────┴───────────────────────┘            │
│                             │                                    │
│                    ┌────────▼────────┐                           │
│                    │  Metric Alarms  │  (error rate > 5%,        │
│                    │  Composite      │   P99 > 2s, CPU > 80%)    │
│                    └────────┬────────┘                           │
└─────────────────────────────┼────────────────────────────────────┘
                              │ ALARM state change
                              ▼
                  ┌───────────────────────┐
                  │    Amazon EventBridge │
                  │  (alarm → rule match) │
                  └───────────┬───────────┘
                              │
               ┌──────────────▼──────────────────┐
               │     Lambda: Remediation          │
               │  1. Notify on-call (SNS)         │
               │  2. SSM restart via Run Command  │
               │  3. ASG scale-out (+2 instances) │
               │  4. Emit MTTR metrics            │
               └──────────────┬──────────────────┘
                              │ SSM Run Command
                              ▼
                    ┌──────────────────┐
                    │   EC2 Instance   │
                    │ systemctl restart│
                    │   techstream     │
                    └──────────────────┘

   DevOps Guru ──────────────────────► Lambda: RCA Analysis
   (AI anomaly detection)              (Bedrock Claude → RCA report → SNS)
```

### Golden Signals Mapped to AWS Resources

| Signal | Metric Source | Alarm | Threshold |
|--------|--------------|-------|-----------|
| **Errors** | `AWS/ApplicationELB HTTPCode_Target_5XX_Count` | `HighErrorRate` | > 5% of requests |
| **Latency** | `AWS/ApplicationELB TargetResponseTime` (p99) | `HighLatencyP99` | > 2000ms |
| **Traffic** | `AWS/ApplicationELB RequestCount` | _(dashboard only)_ | — |
| **Saturation** | `AWS/EC2 CPUUtilization` (ASG average) | `HighCPUSaturation` | > 80% |
| **Saturation** | `TechStream/System mem_used_percent` (CW Agent) | `HighMemorySaturation` | > 85% |

---

## Project Structure

```
self-healing-system/
├── terraform/                    # Infrastructure as Code (Terraform ≥ 1.6)
│   ├── main.tf                   # Root module — module orchestration
│   ├── providers.tf              # AWS provider + backend config
│   ├── variables.tf              # All input variables with validation
│   ├── outputs.tf                # Key stack outputs (ALB URL, dashboard link)
│   └── modules/
│       ├── networking/           # VPC, subnets, SGs, NAT GW, Flow Logs
│       ├── iam/                  # Least-privilege roles (EC2, Lambda)
│       ├── compute/              # ALB, Target Group, Launch Template, ASG
│       ├── monitoring/           # CloudWatch log groups, alarms, dashboard
│       ├── automation/           # SNS, EventBridge rules, Lambda packaging
│       └── ai-ops/               # DevOps Guru configuration
│
├── app/
│   ├── server.py                 # Flask web server with chaos endpoints
│   ├── requirements.txt          # Python dependencies
│   └── user_data.sh              # EC2 bootstrap (CW Agent, systemd service)
│
├── lambda/
│   ├── remediation/
│   │   └── handler.py            # Self-healing: SSM restart → ASG scale-out
│   └── rca-analysis/
│       └── handler.py            # AI RCA: DevOps Guru + Bedrock Claude
│
├── scripts/
│   ├── chaos.sh                  # Chaos injection scenarios
│   ├── deploy.sh                 # Deployment helper (wraps Terraform)
│   └── verify.sh                 # Post-deploy verification
│
├── dashboards/
│   └── golden_signals.json.tpl   # CloudWatch dashboard template
│
└── .github/workflows/
    └── terraform.yml             # CI/CD: validate → tfsec → plan → apply
```

---

## Prerequisites

| Tool | Version | Purpose |
|------|---------|---------|
| Terraform | ≥ 1.6 | Infrastructure provisioning |
| AWS CLI | ≥ 2.x | Credentials + resource queries |
| Python | ≥ 3.11 | Lambda runtime (local testing) |
| curl, jq | any | Chaos script + verification |

**AWS Permissions required:**
- Full access: EC2, ELB, AutoScaling, Lambda, CloudWatch, EventBridge, SNS, SSM, S3, IAM
- Read access: DevOps Guru, Bedrock (for RCA)

---

## Quick Start

### 1. Configure

```bash
cd terraform
cp ../terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars — at minimum set alert_email
```

### 2. Deploy

```bash
./scripts/deploy.sh
# Or with auto-approve:
./scripts/deploy.sh --auto-approve
```

### 3. Verify

```bash
./scripts/verify.sh --alb-url http://<your-alb-dns>
```

### 4. Trigger Chaos

```bash
# Scenario 1: High error rate (triggers ErrorRate alarm → self-healing)
./scripts/chaos.sh errors --alb-url http://<alb-url> --duration 300

# Scenario 2: Latency spike (triggers P99 alarm)
./scripts/chaos.sh latency --alb-url http://<alb-url> --latency-ms 4000

# Scenario 3: CPU saturation
./scripts/chaos.sh cpu --alb-url http://<alb-url> --workers 4

# Scenario 4: Worst-case (all three simultaneously)
./scripts/chaos.sh combined --alb-url http://<alb-url> --duration 180

# Scenario 5: Kill the app process (tests SSM restart)
./scripts/chaos.sh kill --instance-id i-0abc123

# Reset everything
./scripts/chaos.sh reset --alb-url http://<alb-url>
```

### 5. Watch the Self-Healing

1. **CloudWatch Dashboard** → `techstream-sh-prod-golden-signals`
2. **CloudWatch Alarms** → watch `HighErrorRate` transition ALARM → OK
3. **Lambda logs** → `/aws/lambda/techstream-sh-prod-remediation`
4. **SNS email** → incident + remediation summary notifications
5. **DevOps Guru** → Console → Insights (AI-generated anomaly correlation)

---

## Self-Healing Runbook

When an alarm fires, the automation executes in this order:

```
Alarm ALARM state
       │
       ▼ (< 2 min)
EventBridge rule matches
       │
       ▼
Lambda: Remediation
  ├─ [1] Publish incident notification to SNS → email on-call
  ├─ [2] List unhealthy ASG instances
  ├─ [3] SSM Run Command: systemctl restart techstream
  │       ├─ SUCCESS → done, publish summary
  │       └─ FAILURE →
  │              [4] Scale out ASG by +2 instances
  └─ [5] Emit RemediationAttempt / RestartSuccess metrics

       │
       ▼ (5-10 min)
DevOps Guru: New Insight
       │
       ▼
EventBridge rule matches
       │
       ▼
Lambda: RCA Analysis
  ├─ [1] CloudWatch Logs Insights query (error patterns, latency)
  ├─ [2] DevOps Guru anomaly correlation
  ├─ [3] Bedrock Claude: AI-generated RCA narrative
  └─ [4] Publish RCA report to SNS + CloudWatch Logs
```

**Expected MTTR:** 3–8 minutes from alarm trigger to service recovery.

---

## Application Chaos Endpoints

The Flask app exposes chaos endpoints for testing:

| Endpoint | Method | Description |
|----------|--------|-------------|
| `GET /` | GET | Normal index |
| `GET /api/data` | GET | Normal API response |
| `GET /health` | GET | Health check (always 200) |
| `GET /metrics` | GET | Prometheus metrics |
| `POST /chaos/errors` | POST | Inject HTTP 500s `{"rate": 0.8}` |
| `POST /chaos/latency` | POST | Inject latency `{"latency_ms": 3000}` |
| `POST /chaos/cpu` | POST | CPU spike `{"workers": 4, "duration_s": 120}` |
| `POST /chaos/memory` | POST | Memory pressure `{"mb": 512}` |
| `POST /chaos/reset` | POST | Reset all injections |

---

## Security Design

- **IMDSv2 enforced** on all EC2 instances (`http_tokens = "required"`)
- **No SSH** — access via SSM Session Manager only
- **Least-privilege IAM** — EC2 and Lambda roles grant only what they need
- **VPC Flow Logs** enabled for network forensics
- **S3 bucket** for ALB logs has lifecycle policy (30-day expiry)
- **Lambda** runs Python 3.12 on ARM64-equivalent managed runtime
- **ALB access logs** retained 30 days for audit
- **CloudWatch Log Groups** have retention policies (14–90 days)
- **tfsec + checkov** run in CI on every PR

---

## Terraform Modules

| Module | Resources |
|--------|-----------|
| `networking` | VPC, public/private subnets (3 AZs), IGW, NAT GW ×3, route tables, ALB SG, EC2 SG, VPC Flow Logs |
| `iam` | EC2 instance role (SSM + CW Agent), Lambda execution role (SSM + ASG + Bedrock + DevOps Guru) |
| `compute` | ALB, target group, launch template (AL2023, IMDSv2, CW detailed monitoring), ASG (2-6), target tracking + emergency scale-out policies |
| `monitoring` | CloudWatch log groups, log metric filters (5xx, latency, request count), alarms (errors, latency P99, CPU, memory), composite alarm, dashboard |
| `automation` | SNS topic, email subscription, EventBridge rules (alarm→Lambda, DevOps Guru→RCA), Lambda packaging, Lambda permissions |
| `ai-ops` | DevOps Guru notification channel, resource collection (tag-scoped), service integration (logs anomaly detection) |

---

## Costs (Estimate — us-east-1)

| Resource | Approx Monthly Cost |
|----------|-------------------|
| 2× EC2 t3.micro (ASG min) | ~$17 |
| ALB | ~$20 |
| NAT Gateways ×3 | ~$100 |
| CloudWatch metrics + logs | ~$5–15 |
| Lambda (low invocation) | ~$0 |
| DevOps Guru | ~$0.0028/resource-hour |
| **Total (min capacity)** | **~$145/month** |

> **Cost tip:** Use a single NAT Gateway (`count = 1`) for non-prod environments to cut NAT costs to ~$33.

---

## Teardown

```bash
./scripts/deploy.sh --destroy
# or
cd terraform && terraform destroy
```
