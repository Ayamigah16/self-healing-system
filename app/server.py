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
    "error_rate":     1.0,     # fraction of requests that return 500
    "inject_latency": False,
    "latency_ms":     0,
    "cpu_workers":    [],      # list of active CPU worker threads
    "start_time":     time.time(),
}

# ─── Helpers ──────────────────────────────────────────────────────────────────

def _structured_log(level: str, message: str, **extra):
    """Emit a structured JSON log line for CloudWatch Logs Insights."""
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
    """After-request hook: emit structured access log + custom CW metric."""
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
    """Push a single data point to CloudWatch custom namespace (best-effort)."""
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
        "service":    "TechStream Web",
        "status":     "ok",
        "instance":   INSTANCE_ID,
        "uptime_s":   round(time.time() - _chaos_state["start_time"], 1),
        "version":    "1.0.0",
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
    """ALB health check — always returns 200 (chaos does not affect this)."""
    mem   = psutil.virtual_memory()
    cpu   = psutil.cpu_percent(interval=0)
    state = {k: v for k, v in _chaos_state.items() if k != "cpu_workers"}
    state["active_cpu_workers"] = len(_chaos_state["cpu_workers"])
    return jsonify({
        "status":      "healthy",
        "instance":    INSTANCE_ID,
        "cpu_pct":     cpu,
        "mem_used_pct": mem.percent,
        "chaos":       state,
    })


@app.route("/metrics")
def metrics():
    """Prometheus-compatible metrics endpoint."""
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

def _require_json(f):
    @wraps(f)
    def wrapper(*a, **kw):
        return f(*a, **kw)
    return wrapper


@app.route("/chaos/errors", methods=["POST"])
def chaos_errors():
    """
    Start injecting HTTP 500s at the requested rate.
    Body: {"rate": 0.8}  → 80% of requests return 500
    """
    body      = request.get_json(silent=True) or {}
    rate      = min(max(float(body.get("rate", 0.8)), 0.0), 1.0)
    with _chaos_lock:
        _chaos_state["inject_errors"] = True
        _chaos_state["error_rate"]    = rate
    _structured_log("WARN", "chaos_errors_enabled", error_rate=rate)
    logger.warning("CHAOS: error injection enabled at %.0f%%", rate * 100)
    return jsonify({"chaos": "errors", "active": True, "rate": rate})


@app.route("/chaos/latency", methods=["POST"])
def chaos_latency():
    """
    Inject artificial latency into every request.
    Body: {"latency_ms": 3000}
    """
    body       = request.get_json(silent=True) or {}
    latency_ms = int(body.get("latency_ms", 3000))
    with _chaos_lock:
        _chaos_state["inject_latency"] = True
        _chaos_state["latency_ms"]     = latency_ms
    _structured_log("WARN", "chaos_latency_enabled", latency_ms=latency_ms)
    logger.warning("CHAOS: latency injection enabled at %d ms", latency_ms)
    return jsonify({"chaos": "latency", "active": True, "latency_ms": latency_ms})


@app.route("/chaos/cpu", methods=["POST"])
def chaos_cpu():
    """
    Spawn CPU-intensive worker threads to spike utilisation.
    Body: {"workers": 4, "duration_s": 120}
    """
    body       = request.get_json(silent=True) or {}
    n_workers  = int(body.get("workers", psutil.cpu_count()))
    duration_s = int(body.get("duration_s", 120))

    def _cpu_burn(stop_evt: threading.Event):
        end = time.time() + duration_s
        while not stop_evt.is_set() and time.time() < end:
            _ = sum(i * i for i in range(100_000))

    stop_events = []
    with _chaos_lock:
        # Cancel existing workers first
        for evt in _chaos_state["cpu_workers"]:
            evt.set()
        _chaos_state["cpu_workers"] = []

        for _ in range(n_workers):
            evt = threading.Event()
            t = threading.Thread(target=_cpu_burn, args=(evt,), daemon=True)
            t.start()
            stop_events.append(evt)
        _chaos_state["cpu_workers"] = stop_events

    _structured_log("WARN", "chaos_cpu_enabled", workers=n_workers, duration_s=duration_s)
    logger.warning("CHAOS: %d CPU workers running for %ds", n_workers, duration_s)
    return jsonify({"chaos": "cpu", "active": True, "workers": n_workers, "duration_s": duration_s})


@app.route("/chaos/memory", methods=["POST"])
def chaos_memory():
    """
    Allocate a large block of memory to simulate memory pressure.
    Body: {"mb": 512}
    """
    body = request.get_json(silent=True) or {}
    mb   = int(body.get("mb", 256))
    try:
        # Hold a reference in app context so GC doesn't collect it
        app._chaos_mem = bytearray(mb * 1024 * 1024)
        _structured_log("WARN", "chaos_memory_enabled", mb=mb)
        logger.warning("CHAOS: allocated %d MB of memory pressure", mb)
        return jsonify({"chaos": "memory", "active": True, "mb": mb})
    except MemoryError:
        return jsonify({"error": "Insufficient memory for allocation"}), 507


@app.route("/chaos/reset", methods=["POST"])
def chaos_reset():
    """Reset all chaos injections back to normal operation."""
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
    logger.info("CHAOS: all injections reset")
    return jsonify({"chaos": "reset", "active": False})


# ─── Entry Point ──────────────────────────────────────────────────────────────

if __name__ == "__main__":
    logger.info("TechStream server starting on port %d", PORT)
    app.run(host="0.0.0.0", port=PORT, threaded=True)
