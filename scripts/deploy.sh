#!/bin/bash
# =============================================================================
# TechStream Self-Healing System — Deployment Script
#
# Validates prerequisites, packages Lambda functions, runs Terraform plan/apply.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TF_DIR="$PROJECT_ROOT/terraform"

RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

log_info()  { echo -e "${CYAN}[$(date '+%H:%M:%S')] INFO  ${RESET}$*"; }
log_warn()  { echo -e "${YELLOW}[$(date '+%H:%M:%S')] WARN  ${RESET}$*"; }
log_error() { echo -e "${RED}[$(date '+%H:%M:%S')] ERROR ${RESET}$*" >&2; }
log_ok()    { echo -e "${GREEN}[$(date '+%H:%M:%S')] OK    ${RESET}$*"; }

PLAN_ONLY=false
AUTO_APPROVE=false
DESTROY=false

usage() {
    cat <<EOF
${BOLD}TechStream Deployment Script${RESET}

Usage: $(basename "$0") [options]

Options:
  --plan-only      Run terraform plan only (no apply)
  --auto-approve   Apply without interactive approval
  --destroy        Destroy all infrastructure
  -h, --help       Show this help
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --plan-only)    PLAN_ONLY=true;     shift ;;
        --auto-approve) AUTO_APPROVE=true;  shift ;;
        --destroy)      DESTROY=true;       shift ;;
        -h|--help)      usage ;;
        *) log_error "Unknown option: $1"; usage ;;
    esac
done

echo -e "${BOLD}${CYAN}"
echo "╔═══════════════════════════════════════════════════════════╗"
echo "║   TechStream Self-Healing System — Deployment             ║"
echo "╚═══════════════════════════════════════════════════════════╝"
echo -e "${RESET}"

# ─── Prerequisites ────────────────────────────────────────────────────────────
log_info "Checking prerequisites..."

check_cmd() {
    command -v "$1" &>/dev/null || { log_error "$1 not found — install it first"; exit 1; }
}
check_cmd terraform
check_cmd aws
check_cmd python3

# Verify AWS credentials
if ! aws sts get-caller-identity &>/dev/null; then
    log_error "AWS credentials not configured. Run 'aws configure' or set environment variables."
    exit 1
fi
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION=$(aws configure get region 2>/dev/null || echo "${AWS_DEFAULT_REGION:-us-east-1}")
log_ok "AWS authenticated: account=$ACCOUNT_ID region=$REGION"

# Verify Terraform version
TF_VERSION=$(terraform version -json | python3 -c "import sys,json; print(json.load(sys.stdin)['terraform_version'])")
log_ok "Terraform $TF_VERSION"

# ─── Package Lambda Functions ────────────────────────────────────────────────
log_info "Packaging Lambda functions..."

package_lambda() {
    local name="$1"
    local src_dir="$PROJECT_ROOT/lambda/$name"
    local zip_out="$src_dir/${name}.zip"
    log_info "Packaging $name..."
    cd "$src_dir"
    zip -qr "$zip_out" . -x "*.pyc" -x "__pycache__/*" -x "*.zip"
    log_ok "Packaged $name → $zip_out ($(du -sh "$zip_out" | cut -f1))"
    cd "$PROJECT_ROOT"
}

package_lambda "remediation"
package_lambda "rca-analysis"

# ─── Copy Application Source ──────────────────────────────────────────────────
log_info "Copying application source to terraform modules..."
cp "$PROJECT_ROOT/app/server.py"       "$TF_DIR/"
cp "$PROJECT_ROOT/app/user_data.sh"    "$TF_DIR/modules/compute/"
log_ok "Application files copied"

# ─── Terraform ────────────────────────────────────────────────────────────────
cd "$TF_DIR"

log_info "Initialising Terraform..."
terraform init -upgrade

if [[ "$DESTROY" == "true" ]]; then
    log_warn "DESTROY mode — this will tear down ALL infrastructure!"
    if [[ "$AUTO_APPROVE" == "true" ]]; then
        terraform destroy -auto-approve
    else
        terraform destroy
    fi
    log_ok "Infrastructure destroyed"
    exit 0
fi

log_info "Running terraform plan..."
terraform plan -out=tfplan

if [[ "$PLAN_ONLY" == "true" ]]; then
    log_ok "Plan complete. Review tfplan before applying."
    exit 0
fi

log_info "Applying infrastructure..."
if [[ "$AUTO_APPROVE" == "true" ]]; then
    terraform apply -auto-approve tfplan
else
    terraform apply tfplan
fi

# ─── Post-deploy Output ───────────────────────────────────────────────────────
log_ok "Deployment complete!"
echo ""
echo -e "${BOLD}Stack Outputs:${RESET}"
terraform output

ALB_URL=$(terraform output -raw alb_url 2>/dev/null || echo "")
DASHBOARD_URL=$(terraform output -raw cloudwatch_dashboard_url 2>/dev/null || echo "")

if [[ -n "$ALB_URL" ]]; then
    echo ""
    log_info "Verifying application health..."
    sleep 30  # Wait for instances to pass health checks
    "$SCRIPT_DIR/verify.sh" --alb-url "$ALB_URL"
fi

echo ""
echo -e "${BOLD}Next steps:${RESET}"
echo "  1. Confirm SNS email subscription (check $ALERT_EMAIL)"
echo "  2. Open the dashboard: $DASHBOARD_URL"
echo "  3. Run a chaos scenario: ./scripts/chaos.sh errors --alb-url $ALB_URL"
