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
dnf update -y
dnf install -y python3.11 python3.11-pip git stress-ng wget curl jq

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
      "InstanceId": "\${aws:InstanceId}",
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

# Copy application source (injected by Terraform templatefile or S3 sync)
# For a real deployment, replace this with:
#   aws s3 cp s3://techstream-artefacts/app/ $APP_DIR/ --recursive
# For this lab, the server.py is installed via cfn-init or SSM document.

# ─── Systemd service ──────────────────────────────────────────────────────────
cat > /etc/systemd/system/${SERVICE_NAME}.service << SERVICE
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
