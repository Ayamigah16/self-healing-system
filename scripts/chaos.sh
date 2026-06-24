#!/bin/bash
# =============================================================================
# TechStream Chaos Engineering Script
# Simulates production incidents to test the self-healing system.
#
# Usage: ./chaos.sh <scenario> [options]
#
# Scenarios:
#   errors     - Inject HTTP 500 errors (triggers Error Rate alarm)
#   latency    - Inject response latency (triggers P99 Latency alarm)
#   cpu        - Spike CPU utilisation (triggers Saturation alarm)
#   memory     - Simulate memory pressure
#   combined   - Errors + Latency + CPU simultaneously (worst-case scenario)
#   kill       - Kill the application process (tests restart remediation)
#   reset      - Reset all chaos injections
#
# Options:
#   --alb-url URL       ALB URL (required for errors/latency scenarios)
#   --duration N        Duration in seconds (default: 300)
#   --error-rate N      Error injection rate 0.0-1.0 (default: 0.85)
#   --latency-ms N      Artificial latency in ms (default: 3000)
#   --workers N         CPU worker threads (default: all cores)
#   --instance-id ID    Target EC2 instance (for kill/cpu via SSM)
#   --region REGION     AWS region (default: us-east-1)
# =============================================================================
set -euo pipefail

# ─── Defaults ─────────────────────────────────────────────────────────────────
SCENARIO=""
ALB_URL="${ALB_URL:-}"
DURATION=300
ERROR_RATE=0.85
LATENCY_MS=3000
CPU_WORKERS=$(nproc 2>/dev/null || echo "2")
INSTANCE_ID=""
REGION="${AWS_DEFAULT_REGION:-us-east-1}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

log_info()  { echo -e "${CYAN}[$(date '+%H:%M:%S')] INFO  ${RESET}$*"; }
log_warn()  { echo -e "${YELLOW}[$(date '+%H:%M:%S')] WARN  ${RESET}$*"; }
log_error() { echo -e "${RED}[$(date '+%H:%M:%S')] ERROR ${RESET}$*" >&2; }
log_ok()    { echo -e "${GREEN}[$(date '+%H:%M:%S')] OK    ${RESET}$*"; }

# ─── Argument Parsing ─────────────────────────────────────────────────────────
usage() {
    cat <<EOF
${BOLD}TechStream Chaos Engineering Script${RESET}

Usage: $(basename "$0") <scenario> [options]

${BOLD}Scenarios:${RESET}
  errors     Inject HTTP 500s  (triggers ErrorRate alarm → self-healing)
  latency    Inject slow resp  (triggers P99Latency alarm → self-healing)
  cpu        Spike CPU         (triggers CPUSaturation alarm → self-healing)
  memory     Memory pressure   (triggers MemorySaturation alarm)
  combined   All of the above  (worst-case scenario)
  kill       Kill app process  (tests SSM restart remediation)
  reset      Reset everything  (stops all active chaos)

${BOLD}Options:${RESET}
  --alb-url URL         ALB DNS name or full HTTP URL (required for errors/latency)
  --duration N          Duration in seconds (default: $DURATION)
  --error-rate N        Error rate 0.0-1.0 (default: $ERROR_RATE)
  --latency-ms N        Artificial latency ms (default: $LATENCY_MS)
  --workers N           CPU worker count (default: all cores)
  --instance-id ID      EC2 instance ID (for kill/cpu via SSM)
  --region REGION       AWS region (default: $REGION)
  -h, --help            Show this help

${BOLD}Examples:${RESET}
  # Trigger high error rate for 5 minutes
  $(basename "$0") errors --alb-url http://my-alb.us-east-1.elb.amazonaws.com --duration 300

  # Spike CPU for 2 minutes via SSM
  $(basename "$0") cpu --instance-id i-0abc123 --workers 4 --duration 120

  # Run worst-case combined scenario
  $(basename "$0") combined --alb-url http://my-alb... --duration 180

  # Reset after a test
  $(basename "$0") reset --alb-url http://my-alb...
EOF
    exit 0
}

[[ $# -eq 0 ]] && usage
SCENARIO="$1"; shift

while [[ $# -gt 0 ]]; do
    case "$1" in
        --alb-url)      ALB_URL="$2";       shift 2 ;;
        --duration)     DURATION="$2";      shift 2 ;;
        --error-rate)   ERROR_RATE="$2";    shift 2 ;;
        --latency-ms)   LATENCY_MS="$2";    shift 2 ;;
        --workers)      CPU_WORKERS="$2";   shift 2 ;;
        --instance-id)  INSTANCE_ID="$2";   shift 2 ;;
        --region)       REGION="$2";        shift 2 ;;
        -h|--help)      usage ;;
        *) log_error "Unknown option: $1"; usage ;;
    esac
done

# Normalise ALB URL
[[ -n "$ALB_URL" && "$ALB_URL" != http* ]] && ALB_URL="http://$ALB_URL"

# ─── Pre-flight Checks ────────────────────────────────────────────────────────
check_dependencies() {
    local missing=()
    for cmd in curl jq aws; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required tools: ${missing[*]}"
        exit 1
    fi
}

check_alb_reachable() {
    if [[ -z "$ALB_URL" ]]; then
        log_error "--alb-url is required for this scenario"
        exit 1
    fi
    log_info "Testing connectivity to $ALB_URL/health ..."
    local http_code
    http_code=$(curl -sf -o /dev/null -w "%{http_code}" --max-time 10 "$ALB_URL/health" 2>/dev/null || echo "000")
    if [[ "$http_code" == "200" ]]; then
        log_ok "ALB reachable (HTTP $http_code)"
    else
        log_error "ALB not reachable at $ALB_URL (HTTP $http_code)"
        log_warn "Ensure the ALB URL is correct and the stack is deployed."
        exit 1
    fi
}

# ─── Chaos Functions ──────────────────────────────────────────────────────────

inject_errors() {
    check_alb_reachable
    log_warn "${RED}=== CHAOS: Injecting HTTP 500 errors at ${ERROR_RATE} rate ===${RESET}"
    log_warn "Duration: ${DURATION}s | Expected: triggers ErrorRate alarm after ~2 minutes"

    curl -sf -X POST "$ALB_URL/chaos/errors" \
        -H "Content-Type: application/json" \
        -d "{\"rate\": $ERROR_RATE}" | jq .

    log_info "Generating traffic to amplify error signal (background)..."
    _generate_traffic "$ALB_URL" "$DURATION" &
    TRAFFIC_PID=$!

    log_info "Monitoring error rate for ${DURATION}s ..."
    _monitor_errors "$ALB_URL" "$DURATION"

    wait "$TRAFFIC_PID" 2>/dev/null || true
    log_ok "Error injection phase complete"
}

inject_latency() {
    check_alb_reachable
    log_warn "${RED}=== CHAOS: Injecting ${LATENCY_MS}ms artificial latency ===${RESET}"
    log_warn "Duration: ${DURATION}s | Expected: triggers P99Latency alarm after ~3 minutes"

    curl -sf -X POST "$ALB_URL/chaos/latency" \
        -H "Content-Type: application/json" \
        -d "{\"latency_ms\": $LATENCY_MS}" | jq .

    _generate_traffic "$ALB_URL" "$DURATION" &
    TRAFFIC_PID=$!
    _monitor_latency "$ALB_URL" "$DURATION"
    wait "$TRAFFIC_PID" 2>/dev/null || true
    log_ok "Latency injection phase complete"
}

inject_cpu() {
    log_warn "${RED}=== CHAOS: Spiking CPU with ${CPU_WORKERS} workers for ${DURATION}s ===${RESET}"

    if [[ -n "$ALB_URL" ]]; then
        # Trigger via application endpoint
        curl -sf -X POST "$ALB_URL/chaos/cpu" \
            -H "Content-Type: application/json" \
            -d "{\"workers\": $CPU_WORKERS, \"duration_s\": $DURATION}" | jq .
    elif [[ -n "$INSTANCE_ID" ]]; then
        # Trigger via SSM Run Command on EC2
        log_info "Sending SSM command to instance $INSTANCE_ID ..."
        local cmd_id
        cmd_id=$(aws ssm send-command \
            --instance-ids "$INSTANCE_ID" \
            --document-name "AWS-RunShellScript" \
            --parameters "commands=[\"stress-ng --cpu $CPU_WORKERS --timeout ${DURATION}s --quiet &\"]" \
            --region "$REGION" \
            --query "Command.CommandId" \
            --output text)
        log_ok "SSM command sent: $cmd_id"
    else
        # Local CPU stress (for running on the EC2 instance directly)
        log_info "Running local CPU stress (stress-ng)..."
        stress-ng --cpu "$CPU_WORKERS" --timeout "${DURATION}s" --quiet &
        CPU_PID=$!
        log_ok "stress-ng PID: $CPU_PID — running for ${DURATION}s"
    fi
}

inject_memory() {
    log_warn "${RED}=== CHAOS: Injecting memory pressure ===${RESET}"

    if [[ -n "$ALB_URL" ]]; then
        local mb=512
        curl -sf -X POST "$ALB_URL/chaos/memory" \
            -H "Content-Type: application/json" \
            -d "{\"mb\": $mb}" | jq .
        log_ok "Memory pressure injected (${mb}MB)"
    else
        log_info "Running local memory stress (512MB)..."
        stress-ng --vm 1 --vm-bytes 512m --timeout "${DURATION}s" --quiet &
        log_ok "Memory stress started"
    fi
}

inject_kill() {
    log_warn "${RED}=== CHAOS: Killing the techstream process ===${RESET}"
    log_warn "Expected: SSM remediation Lambda restarts the service"

    if [[ -n "$INSTANCE_ID" ]]; then
        log_info "Sending kill command to instance $INSTANCE_ID via SSM ..."
        local cmd_id
        cmd_id=$(aws ssm send-command \
            --instance-ids "$INSTANCE_ID" \
            --document-name "AWS-RunShellScript" \
            --parameters "commands=[\"systemctl stop techstream && echo KILLED\"]" \
            --region "$REGION" \
            --query "Command.CommandId" \
            --output text)
        log_ok "Kill command sent: $cmd_id"
        log_info "Waiting 10s for health check failures to propagate..."
        sleep 10
        log_info "Checking service status..."
        aws ssm send-command \
            --instance-ids "$INSTANCE_ID" \
            --document-name "AWS-RunShellScript" \
            --parameters "commands=[\"systemctl status techstream || echo SERVICE_DOWN\"]" \
            --region "$REGION" \
            --output text >/dev/null 2>&1 || true
    else
        log_error "--instance-id is required for the kill scenario"
        exit 1
    fi
}

chaos_reset() {
    log_info "=== Resetting all chaos injections ==="
    if [[ -n "$ALB_URL" ]]; then
        curl -sf -X POST "$ALB_URL/chaos/reset" | jq . || log_warn "Reset request failed (service may be down)"
    fi
    # Kill any local stress-ng processes
    pkill -f stress-ng 2>/dev/null && log_ok "stress-ng processes killed" || true
    log_ok "Chaos reset complete"
}

combined_scenario() {
    log_warn "${RED}${BOLD}=== CHAOS: COMBINED WORST-CASE SCENARIO ===${RESET}"
    log_warn "Injecting: errors + latency + CPU spike simultaneously"
    log_warn "Duration: ${DURATION}s"
    echo ""

    check_alb_reachable

    # Inject all simultaneously
    curl -sf -X POST "$ALB_URL/chaos/errors"  -H "Content-Type: application/json" \
        -d "{\"rate\": $ERROR_RATE}" > /dev/null
    curl -sf -X POST "$ALB_URL/chaos/latency" -H "Content-Type: application/json" \
        -d "{\"latency_ms\": $LATENCY_MS}" > /dev/null
    curl -sf -X POST "$ALB_URL/chaos/cpu"     -H "Content-Type: application/json" \
        -d "{\"workers\": $CPU_WORKERS, \"duration_s\": $DURATION}" > /dev/null

    log_warn "All chaos injectors active. Generating load..."
    _generate_traffic "$ALB_URL" "$DURATION" &
    TRAFFIC_PID=$!

    log_info "Watching Golden Signals for ${DURATION}s..."
    _monitor_combined "$ALB_URL" "$DURATION"

    wait "$TRAFFIC_PID" 2>/dev/null || true
    log_ok "Combined scenario phase complete"
}

# ─── Traffic Generator ────────────────────────────────────────────────────────

_generate_traffic() {
    local url="$1"
    local duration="$2"
    local end_time=$(( $(date +%s) + duration ))
    local req=0 errors=0

    log_info "Traffic generator started (target: $url)"
    while [[ $(date +%s) -lt $end_time ]]; do
        local endpoints=("/" "/api/data" "/" "/api/data" "/" "/health")
        for ep in "${endpoints[@]}"; do
            http_code=$(curl -sf -o /dev/null -w "%{http_code}" --max-time 5 "$url$ep" 2>/dev/null || echo "000")
            (( req++ ))
            [[ "$http_code" -ge 500 ]] && (( errors++ ))
        done
        # Print progress every 30 iterations
        if (( req % 30 == 0 )); then
            local pct=0
            [[ $req -gt 0 ]] && pct=$(( errors * 100 / req ))
            log_info "Traffic: ${req} requests | ${errors} errors | ${pct}% error rate"
        fi
        sleep 0.5
    done
    log_info "Traffic generator stopped: ${req} total requests, ${errors} errors"
}

# ─── Monitoring Helpers ───────────────────────────────────────────────────────

_monitor_errors() {
    local url="$1" duration="$2"
    local end_time=$(( $(date +%s) + duration ))
    while [[ $(date +%s) -lt $end_time ]]; do
        local health
        health=$(curl -sf --max-time 5 "$url/health" 2>/dev/null | jq -r \
            '"CPU: \(.cpu_pct)% | Chaos errors: \(.chaos.inject_errors) @ \(.chaos.error_rate)"' \
            2>/dev/null || echo "health check unreachable")
        log_info "$health"
        sleep 15
    done
}

_monitor_latency() {
    local url="$1" duration="$2"
    local end_time=$(( $(date +%s) + duration ))
    while [[ $(date +%s) -lt $end_time ]]; do
        local response_time
        response_time=$(curl -sf -o /dev/null -w "%{time_total}s" --max-time 10 "$url/" 2>/dev/null || echo "timeout")
        log_info "Response time: $response_time"
        sleep 10
    done
}

_monitor_combined() {
    local url="$1" duration="$2"
    local end_time=$(( $(date +%s) + duration ))
    while [[ $(date +%s) -lt $end_time ]]; do
        local rt
        rt=$(curl -sf -o /dev/null -w "%{time_total}" --max-time 10 "$url/" 2>/dev/null || echo "err")
        local code
        code=$(curl -sf -o /dev/null -w "%{http_code}" --max-time 5 "$url/api/data" 2>/dev/null || echo "000")
        log_warn "Response: ${rt}s | Status: HTTP $code | $(date '+%H:%M:%S')"
        sleep 10
    done
}

# ─── Pre-flight ───────────────────────────────────────────────────────────────
check_dependencies

# ─── Banner ───────────────────────────────────────────────────────────────────
echo -e "${BOLD}${CYAN}"
echo "╔═══════════════════════════════════════════════════╗"
echo "║   TechStream Chaos Engineering Framework          ║"
echo "║   Scenario: $(printf '%-38s' "$SCENARIO")║"
echo "║   Duration:  ${DURATION}s                                   ║"
echo "╚═══════════════════════════════════════════════════╝"
echo -e "${RESET}"
echo ""
log_warn "This script will deliberately degrade the application."
log_warn "The self-healing system should automatically remediate within 5-10 minutes."
log_warn "Monitor the CloudWatch dashboard to observe the response."
echo ""

# ─── Dispatch ────────────────────────────────────────────────────────────────
trap 'echo ""; log_warn "Interrupted — cleaning up..."; chaos_reset; exit 0' INT TERM

case "$SCENARIO" in
    errors)   inject_errors   ;;
    latency)  inject_latency  ;;
    cpu)      inject_cpu      ;;
    memory)   inject_memory   ;;
    kill)     inject_kill     ;;
    combined) combined_scenario ;;
    reset)    chaos_reset     ;;
    *)
        log_error "Unknown scenario: $SCENARIO"
        usage
        ;;
esac

echo ""
log_ok "=== Chaos scenario '${SCENARIO}' complete ==="
log_info "Check the CloudWatch Golden Signals dashboard to observe remediation."
log_info "AWS Console → CloudWatch → Dashboards → ${PROJECT:-techstream-sh}-prod-golden-signals"
