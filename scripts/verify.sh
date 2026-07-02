#!/bin/bash
# =============================================================================
# TechStream — Post-Deployment Verification Script
#
# Runs a series of checks to confirm the self-healing stack is healthy.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

PASS=0; FAIL=0; WARN=0
ALB_URL=""
REGION="${AWS_DEFAULT_REGION:-us-east-1}"

log_info()  { echo -e "${CYAN}  ●  ${RESET}$*"; }
log_pass()  { echo -e "${GREEN}  ✓  ${RESET}$*"; (( ++PASS )); }
log_fail()  { echo -e "${RED}  ✗  ${RESET}$*"; (( ++FAIL )); }
log_warn()  { echo -e "${YELLOW}  !  ${RESET}$*"; (( ++WARN )); }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --alb-url) ALB_URL="$2"; shift 2 ;;
        --region)  REGION="$2";  shift 2 ;;
        *) shift ;;
    esac
done

[[ -n "$ALB_URL" && "$ALB_URL" != http* ]] && ALB_URL="http://$ALB_URL"

echo ""
echo -e "${BOLD}TechStream — Deployment Verification${RESET}"
echo "────────────────────────────────────────"

# ─── 1. Application Endpoints ─────────────────────────────────────────────────
if [[ -n "$ALB_URL" ]]; then
    log_info "Checking application endpoints..."

    check_endpoint() {
        local path="$1" expected="$2" label="$3"
        local code
        code=$(curl -sf -o /dev/null -w "%{http_code}" --max-time 10 "$ALB_URL$path" 2>/dev/null || echo "000")
        if [[ "$code" == "$expected" ]]; then
            log_pass "GET $path → HTTP $code [$label]"
        else
            log_fail "GET $path → HTTP $code (expected $expected) [$label]"
        fi
    }

    check_endpoint "/health"   "200" "Health Check"
    check_endpoint "/"         "200" "Index"
    check_endpoint "/api/data" "200" "API"
    check_endpoint "/metrics"  "200" "Prometheus Metrics"

    # Verify chaos endpoints exist but don't trigger them
    chaos_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 -X GET "$ALB_URL/chaos/reset" 2>/dev/null || echo "000")
    [[ "$chaos_code" == "405" || "$chaos_code" == "200" ]] && \
        log_pass "Chaos endpoints reachable" || \
        log_warn "Chaos endpoints returned unexpected: HTTP $chaos_code"

    # Verify response structure
    health_json=$(curl -sf --max-time 10 "$ALB_URL/health" 2>/dev/null || echo "{}")
    if echo "$health_json" | python3 -c "import sys,json; d=json.load(sys.stdin); assert d['status']=='healthy'" 2>/dev/null; then
        log_pass "Health check returns status=healthy"
    else
        log_fail "Health check response malformed: $health_json"
    fi
else
    log_warn "No --alb-url provided — skipping endpoint checks"
fi

# ─── 2. AWS Resources ─────────────────────────────────────────────────────────
log_info "Checking AWS resources..."

check_alarms() {
    local alarms
    alarms=$(aws cloudwatch describe-alarms \
        --region "$REGION" \
        --query "MetricAlarms[?contains(AlarmName, 'techstream')].{Name:AlarmName,State:StateValue}" \
        --output json 2>/dev/null || echo "[]")
    local count
    count=$(echo "$alarms" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo 0)
    if [[ "$count" -ge 3 ]]; then
        log_pass "$count CloudWatch alarms configured"
        echo "$alarms" | python3 -c "
import sys, json
for a in json.load(sys.stdin):
    state = a['State']
    icon = '✓' if state == 'OK' else ('⚠' if state == 'INSUFFICIENT_DATA' else '✗')
    print(f'     {icon} {a[\"Name\"]} → {state}')
" 2>/dev/null || true
    else
        log_fail "Expected ≥3 CloudWatch alarms, found $count"
    fi
}

check_lambdas() {
    for fn_suffix in "remediation" "rca-analysis"; do
        local fn_name="techstream-sh-prod-${fn_suffix}"
        local state
        state=$(aws lambda get-function-configuration \
            --function-name "$fn_name" \
            --region "$REGION" \
            --query "State" \
            --output text 2>/dev/null || echo "NOT_FOUND")
        if [[ "$state" == "Active" ]]; then
            log_pass "Lambda $fn_name → Active"
        else
            log_fail "Lambda $fn_name → $state"
        fi
    done
}

check_eventbridge() {
    local rules
    rules=$(aws events list-rules \
        --region "$REGION" \
        --query "Rules[?contains(Name, 'techstream')].{Name:Name,State:State}" \
        --output json 2>/dev/null || echo "[]")
    local count
    count=$(echo "$rules" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo 0)
    if [[ "$count" -ge 1 ]]; then
        log_pass "$count EventBridge rules configured"
    else
        log_fail "No EventBridge rules found for techstream"
    fi
}

check_asg() {
    local asg_info
    asg_info=$(aws autoscaling describe-auto-scaling-groups \
        --region "$REGION" \
        --query "AutoScalingGroups[?contains(AutoScalingGroupName, 'techstream')].{Name:AutoScalingGroupName,Desired:DesiredCapacity,InService:length(Instances[?HealthStatus=='Healthy'])}" \
        --output json 2>/dev/null || echo "[]")
    local count
    count=$(echo "$asg_info" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo 0)
    if [[ "$count" -ge 1 ]]; then
        log_pass "ASG found"
        echo "$asg_info" | python3 -c "
import sys, json
for a in json.load(sys.stdin):
    print(f'     → {a[\"Name\"]}: desired={a[\"Desired\"]}, healthy={a[\"InService\"]}')
" 2>/dev/null || true
    else
        log_warn "No TechStream ASG found (may still be initialising)"
    fi
}

check_alarms
check_lambdas
check_eventbridge
check_asg

# ─── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "────────────────────────────────────────"
echo -e "${BOLD}Verification Summary:${RESET}"
echo -e "  ${GREEN}Passed: $PASS${RESET}  ${YELLOW}Warnings: $WARN${RESET}  ${RED}Failed: $FAIL${RESET}"
echo ""

if [[ $FAIL -eq 0 ]]; then
    log_pass "Stack is healthy — ready for chaos testing!"
    echo ""
    echo "  Run your first chaos scenario:"
    echo "  ./scripts/chaos.sh errors --alb-url $ALB_URL --duration 300"
    exit 0
else
    log_fail "Some checks failed — review the output above before running chaos tests"
    exit 1
fi
