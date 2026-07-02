#!/bin/bash
# EC2 User Data — bootstraps the TechStream web server on Amazon Linux 2023
# Templatefile variables: ${log_group_name}  ${region}
set -euo pipefail
exec > >(tee /var/log/user-data.log | logger -t user-data -s 2>/dev/console) 2>&1

REGION="${region}"
LOG_GROUP="${log_group_name}"
APP_DIR="/opt/techstream"
APP_USER="techstream"
SERVICE_NAME="techstream"

echo "=== TechStream bootstrap starting at $(date) ==="

# ─── System packages ─────────────────────────────────────────────────────────
dnf update -y --allowerasing || dnf update -y --skip-broken || true
dnf install -y python3.11 python3.11-pip git stress-ng wget curl jq --allowerasing

# ─── CloudWatch Agent ─────────────────────────────────────────────────────────
wget -q https://s3.amazonaws.com/amazoncloudwatch-agent/amazon_linux/amd64/latest/amazon-cloudwatch-agent.rpm
rpm -U amazon-cloudwatch-agent.rpm

# Retrieve instance metadata (IMDSv2)
TOKEN=$(curl -sf -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
INSTANCE_ID=$(curl -sf -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/instance-id)
ASG_NAME=$(aws autoscaling describe-auto-scaling-instances \
  --instance-ids "$INSTANCE_ID" \
  --region "$REGION" \
  --query 'AutoScalingInstances[0].AutoScalingGroupName' \
  --output text 2>/dev/null || echo "unknown-asg")

# Write CloudWatch Agent configuration
cat > /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json << CW_CONFIG
{
  "agent": {
    "metrics_collection_interval": 30,
    "run_as_user": "cwagent"
  },
  "metrics": {
    "namespace": "TechStream/System",
    "append_dimensions": {
      "InstanceId": "$INSTANCE_ID",
      "AutoScalingGroupName": "$ASG_NAME"
    },
    "metrics_collected": {
      "cpu": {
        "resources": ["*"],
        "measurement": ["cpu_usage_active", "cpu_usage_idle", "cpu_usage_user", "cpu_usage_system"],
        "metrics_collection_interval": 30,
        "totalcpu": true
      },
      "mem": {
        "measurement": ["mem_used_percent", "mem_available", "mem_total"],
        "metrics_collection_interval": 30
      },
      "disk": {
        "resources": ["/"],
        "measurement": ["disk_used_percent", "disk_free"],
        "metrics_collection_interval": 60
      },
      "net": {
        "resources": ["eth0"],
        "measurement": ["net_bytes_sent", "net_bytes_recv", "net_packets_sent", "net_packets_recv"],
        "metrics_collection_interval": 30
      },
      "netstat": {
        "measurement": ["tcp_established", "tcp_time_wait"],
        "metrics_collection_interval": 30
      }
    }
  },
  "logs": {
    "logs_collected": {
      "files": {
        "collect_list": [
          {
            "file_path": "/var/log/techstream/app.log",
            "log_group_name": "$LOG_GROUP",
            "log_stream_name": "{instance_id}",
            "timezone": "UTC",
            "timestamp_format": "%Y-%m-%dT%H:%M:%S"
          },
          {
            "file_path": "/var/log/user-data.log",
            "log_group_name": "/techstream/bootstrap",
            "log_stream_name": "{instance_id}"
          }
        ]
      }
    }
  }
}
CW_CONFIG

/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
  -a fetch-config \
  -m ec2 \
  -c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json \
  -s

# ─── Application setup ────────────────────────────────────────────────────────
useradd -r -s /bin/false "$APP_USER" || true
mkdir -p "$APP_DIR" /var/log/techstream
chown "$APP_USER:$APP_USER" "$APP_DIR" /var/log/techstream

# Pull app files from S3 (in production) or embed inline for lab use
# In this lab we write them inline via heredoc
cat > "$APP_DIR/requirements.txt" << 'REQS'
flask==3.0.3
boto3==1.34.144
psutil==5.9.8
gunicorn==22.0.0
REQS

# Install Python deps
python3.11 -m pip install -r "$APP_DIR/requirements.txt" --quiet

cat > "$APP_DIR/server.py" << 'APP_PY'
"""
TechStream Web Server — intentionally fragile for self-healing demonstrations.

Normal endpoints:  GET /  GET /api/data  GET /health
Chaos endpoints:   POST /chaos/{cpu,errors,latency,memory,reset}
Metrics endpoint:  GET /metrics  (Prometheus-compatible text output)
"""
import json
import logging
import math
import os
import platform
import random
import socket
import threading
import time
from datetime import datetime, timezone
from functools import wraps

import boto3
import psutil
from flask import Flask, Response, jsonify, request

# ─── Configuration ────────────────────────────────────────────────────────────
LOG_LEVEL   = os.environ.get("LOG_LEVEL", "INFO").upper()
PORT        = int(os.environ.get("PORT", "5000"))
REGION      = os.environ.get("AWS_DEFAULT_REGION", "us-east-1")
LOG_GROUP   = os.environ.get("CW_LOG_GROUP", "/techstream/app")
INSTANCE_ID = os.environ.get("INSTANCE_ID", socket.gethostname())
ASG_NAME    = os.environ.get("ASG_NAME", "unknown-asg")

logging.basicConfig(
    level=getattr(logging, LOG_LEVEL),
    format="%(asctime)s %(levelname)s %(name)s %(message)s",
)
logger = logging.getLogger("techstream")

app = Flask(__name__)

# ─── Chaos State (thread-safe) ────────────────────────────────────────────────
_chaos_lock = threading.Lock()
_chaos_state = {
    "inject_errors":  False,
    "error_rate":     1.0,
    "inject_latency": False,
    "latency_ms":     0,
    "cpu_workers":    [],
    "start_time":     time.time(),
}

# ─── Helpers ──────────────────────────────────────────────────────────────────

def _structured_log(level: str, message: str, **extra):
    record = {
        "timestamp":   datetime.now(timezone.utc).isoformat(),
        "level":       level,
        "message":     message,
        "instance_id": INSTANCE_ID,
        "asg_name":    ASG_NAME,
        **extra,
    }
    print(json.dumps(record), flush=True)


def _log_request(resp: Response) -> Response:
    duration_ms = round((time.time() - request.environ.get("_start", time.time())) * 1000, 2)
    _structured_log(
        "INFO" if resp.status_code < 500 else "ERROR",
        "http_request",
        method=request.method,
        path=request.path,
        status_code=resp.status_code,
        response_time_ms=duration_ms,
        remote_addr=request.remote_addr,
    )
    _push_cw_metric("ResponseTimeMs", duration_ms, "Milliseconds")
    if resp.status_code >= 500:
        _push_cw_metric("HTTP5xxCount", 1, "Count")
    _push_cw_metric("HTTPRequestCount", 1, "Count")
    return resp


app.after_request(_log_request)


@app.before_request
def _record_start():
    request.environ["_start"] = time.time()


def _push_cw_metric(name: str, value: float, unit: str = "None"):
    try:
        cw = boto3.client("cloudwatch", region_name=REGION)
        cw.put_metric_data(
            Namespace="TechStream/App",
            MetricData=[{
                "MetricName": name,
                "Value":      value,
                "Unit":       unit,
                "Dimensions": [
                    {"Name": "InstanceId", "Value": INSTANCE_ID},
                    {"Name": "AsgName",    "Value": ASG_NAME},
                ],
            }],
        )
    except Exception as exc:
        logger.debug("CW metric push failed (non-fatal): %s", exc)


# ─── Normal Endpoints ─────────────────────────────────────────────────────────

@app.route("/")
def index():
    with _chaos_lock:
        if _chaos_state["inject_latency"]:
            time.sleep(_chaos_state["latency_ms"] / 1000.0)
        if _chaos_state["inject_errors"] and random.random() < _chaos_state["error_rate"]:
            _structured_log("ERROR", "chaos_500_injected", endpoint="/")
            return jsonify({"error": "Internal Server Error", "chaos": True}), 500
    return jsonify({
        "service":  "TechStream Web",
        "status":   "ok",
        "instance": INSTANCE_ID,
        "uptime_s": round(time.time() - _chaos_state["start_time"], 1),
        "version":  "1.0.0",
    })


@app.route("/api/data")
def api_data():
    with _chaos_lock:
        if _chaos_state["inject_latency"]:
            time.sleep(_chaos_state["latency_ms"] / 1000.0)
        if _chaos_state["inject_errors"] and random.random() < _chaos_state["error_rate"]:
            _structured_log("ERROR", "chaos_500_injected", endpoint="/api/data")
            return jsonify({"error": "Database connection failed", "chaos": True}), 500
    payload = [
        {"id": i, "value": round(math.sin(i / 10.0) * 100, 2), "ts": time.time()}
        for i in range(20)
    ]
    return jsonify({"data": payload, "count": len(payload)})


@app.route("/health")
def health():
    mem   = psutil.virtual_memory()
    cpu   = psutil.cpu_percent(interval=0)
    state = {k: v for k, v in _chaos_state.items() if k != "cpu_workers"}
    state["active_cpu_workers"] = len(_chaos_state["cpu_workers"])
    return jsonify({
        "status":       "healthy",
        "instance":     INSTANCE_ID,
        "cpu_pct":      cpu,
        "mem_used_pct": mem.percent,
        "chaos":        state,
    })


@app.route("/metrics")
def metrics():
    mem  = psutil.virtual_memory()
    cpu  = psutil.cpu_percent(interval=0)
    disk = psutil.disk_usage("/")
    lines = [
        "# HELP techstream_cpu_usage_percent Current CPU utilisation",
        "# TYPE techstream_cpu_usage_percent gauge",
        f'techstream_cpu_usage_percent{{instance="{INSTANCE_ID}"}} {cpu}',
        "# HELP techstream_memory_used_percent Current memory utilisation",
        "# TYPE techstream_memory_used_percent gauge",
        f'techstream_memory_used_percent{{instance="{INSTANCE_ID}"}} {mem.percent}',
        "# HELP techstream_disk_used_percent Current disk utilisation",
        "# TYPE techstream_disk_used_percent gauge",
        f'techstream_disk_used_percent{{instance="{INSTANCE_ID}"}} {disk.percent}',
        "# HELP techstream_chaos_errors Whether error injection is active",
        "# TYPE techstream_chaos_errors gauge",
        f'techstream_chaos_errors{{instance="{INSTANCE_ID}"}} {int(_chaos_state["inject_errors"])}',
        "# HELP techstream_chaos_latency_ms Injected latency in ms",
        "# TYPE techstream_chaos_latency_ms gauge",
        f'techstream_chaos_latency_ms{{instance="{INSTANCE_ID}"}} {_chaos_state["latency_ms"]}',
    ]
    return Response("\n".join(lines) + "\n", mimetype="text/plain; version=0.0.4")


# ─── Chaos Endpoints ──────────────────────────────────────────────────────────

@app.route("/chaos/errors", methods=["POST"])
def chaos_errors():
    body = request.get_json(silent=True) or {}
    rate = min(max(float(body.get("rate", 0.8)), 0.0), 1.0)
    with _chaos_lock:
        _chaos_state["inject_errors"] = True
        _chaos_state["error_rate"]    = rate
    _structured_log("WARN", "chaos_errors_enabled", error_rate=rate)
    return jsonify({"chaos": "errors", "active": True, "rate": rate})


@app.route("/chaos/latency", methods=["POST"])
def chaos_latency():
    body       = request.get_json(silent=True) or {}
    latency_ms = int(body.get("latency_ms", 3000))
    with _chaos_lock:
        _chaos_state["inject_latency"] = True
        _chaos_state["latency_ms"]     = latency_ms
    _structured_log("WARN", "chaos_latency_enabled", latency_ms=latency_ms)
    return jsonify({"chaos": "latency", "active": True, "latency_ms": latency_ms})


@app.route("/chaos/cpu", methods=["POST"])
def chaos_cpu():
    body       = request.get_json(silent=True) or {}
    n_workers  = int(body.get("workers", psutil.cpu_count()))
    duration_s = int(body.get("duration_s", 120))

    def _cpu_burn(stop_evt: threading.Event):
        end = time.time() + duration_s
        while not stop_evt.is_set() and time.time() < end:
            _ = sum(i * i for i in range(100_000))

    with _chaos_lock:
        for evt in _chaos_state["cpu_workers"]:
            evt.set()
        _chaos_state["cpu_workers"] = []
        stop_events = []
        for _ in range(n_workers):
            evt = threading.Event()
            t = threading.Thread(target=_cpu_burn, args=(evt,), daemon=True)
            t.start()
            stop_events.append(evt)
        _chaos_state["cpu_workers"] = stop_events

    _structured_log("WARN", "chaos_cpu_enabled", workers=n_workers, duration_s=duration_s)
    return jsonify({"chaos": "cpu", "active": True, "workers": n_workers, "duration_s": duration_s})


@app.route("/chaos/memory", methods=["POST"])
def chaos_memory():
    body = request.get_json(silent=True) or {}
    mb   = int(body.get("mb", 256))
    try:
        app._chaos_mem = bytearray(mb * 1024 * 1024)
        _structured_log("WARN", "chaos_memory_enabled", mb=mb)
        return jsonify({"chaos": "memory", "active": True, "mb": mb})
    except MemoryError:
        return jsonify({"error": "Insufficient memory for allocation"}), 507


@app.route("/chaos/reset", methods=["POST"])
def chaos_reset():
    with _chaos_lock:
        for evt in _chaos_state["cpu_workers"]:
            evt.set()
        _chaos_state.update({
            "inject_errors":  False,
            "error_rate":     1.0,
            "inject_latency": False,
            "latency_ms":     0,
            "cpu_workers":    [],
        })
    if hasattr(app, "_chaos_mem"):
        del app._chaos_mem
    _structured_log("INFO", "chaos_reset")
    return jsonify({"chaos": "reset", "active": False})


if __name__ == "__main__":
    logger.info("TechStream server starting on port %d", PORT)
    app.run(host="0.0.0.0", port=PORT, threaded=True)
APP_PY
chown "$APP_USER:$APP_USER" "$APP_DIR/server.py"

# ─── Systemd service ──────────────────────────────────────────────────────────
cat > /etc/systemd/system/$${SERVICE_NAME}.service << SERVICE
[Unit]
Description=TechStream Web Server
After=network.target
Wants=amazon-cloudwatch-agent.service

[Service]
Type=simple
User=$APP_USER
WorkingDirectory=$APP_DIR
ExecStart=/usr/bin/python3.11 -m gunicorn \
  --workers 4 \
  --worker-class gthread \
  --threads 4 \
  --bind 0.0.0.0:5000 \
  --access-logfile - \
  --error-logfile - \
  --timeout 30 \
  server:app
Restart=always
RestartSec=5
StandardOutput=append:/var/log/techstream/app.log
StandardError=append:/var/log/techstream/app.log
Environment=PORT=5000
Environment=AWS_DEFAULT_REGION=$REGION
Environment=CW_LOG_GROUP=$LOG_GROUP
Environment=INSTANCE_ID=$INSTANCE_ID
Environment=ASG_NAME=$ASG_NAME
Environment=LOG_LEVEL=INFO

# Hardening
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ReadWritePaths=/var/log/techstream

[Install]
WantedBy=multi-user.target
SERVICE

systemctl daemon-reload
systemctl enable "$SERVICE_NAME"
systemctl start "$SERVICE_NAME"

# ─── Verify startup ───────────────────────────────────────────────────────────
sleep 5
if systemctl is-active --quiet "$SERVICE_NAME"; then
    echo "=== TechStream service started successfully ==="
else
    echo "=== ERROR: TechStream service failed to start ==="
    journalctl -u "$SERVICE_NAME" --no-pager -n 50
    exit 1
fi

echo "=== Bootstrap complete at $(date) ==="
