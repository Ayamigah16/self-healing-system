{
  "widgets": [

    %{ ~}
    // ── Header ──────────────────────────────────────────────────────────────
    {
      "type": "text",
      "x": 0, "y": 0, "width": 24, "height": 2,
      "properties": {
        "markdown": "# TechStream — Golden Signals Dashboard\n**Region:** ${region} | **ASG:** ${asg_name} | **Self-Healing:** Active\n\nMonitors the four SRE Golden Signals: **Latency · Traffic · Errors · Saturation**"
      }
    },

    // ── Row 1: ERRORS ────────────────────────────────────────────────────────
    {
      "type": "text",
      "x": 0, "y": 2, "width": 24, "height": 1,
      "properties": { "markdown": "## 🔴 Golden Signal 1: Errors" }
    },
    {
      "type": "metric",
      "x": 0, "y": 3, "width": 8, "height": 6,
      "properties": {
        "title": "HTTP 5xx Error Count (ALB)",
        "view": "timeSeries",
        "stacked": false,
        "region": "${region}",
        "metrics": [
          ["AWS/ApplicationELB", "HTTPCode_Target_5XX_Count", "LoadBalancer", "${alb_suffix}", { "stat": "Sum", "period": 60, "color": "#d62728", "label": "5xx Errors" }],
          ["AWS/ApplicationELB", "HTTPCode_Target_4XX_Count", "LoadBalancer", "${alb_suffix}", { "stat": "Sum", "period": 60, "color": "#ff7f0e", "label": "4xx Errors" }]
        ],
        "annotations": {
          "horizontal": [{ "color": "#ff0000", "label": "Alert Threshold", "value": 10 }]
        },
        "yAxis": { "left": { "min": 0 } }
      }
    },
    {
      "type": "metric",
      "x": 8, "y": 3, "width": 8, "height": 6,
      "properties": {
        "title": "HTTP Error Rate % (5xx / Total)",
        "view": "timeSeries",
        "region": "${region}",
        "metrics": [
          [{ "expression": "IF(total > 0, (errors/total)*100, 0)", "label": "Error Rate %", "id": "error_rate", "color": "#d62728" }],
          ["AWS/ApplicationELB", "HTTPCode_Target_5XX_Count", "LoadBalancer", "${alb_suffix}", { "id": "errors", "visible": false, "period": 60, "stat": "Sum" }],
          ["AWS/ApplicationELB", "RequestCount",              "LoadBalancer", "${alb_suffix}", { "id": "total",  "visible": false, "period": 60, "stat": "Sum" }]
        ],
        "annotations": {
          "horizontal": [{ "color": "#ff0000", "label": "Alarm Threshold (5%)", "value": 5 }]
        },
        "yAxis": { "left": { "min": 0, "max": 100 } }
      }
    },
    {
      "type": "alarm",
      "x": 16, "y": 3, "width": 8, "height": 6,
      "properties": {
        "title": "Error Rate Alarm Status",
        "alarms": [
          "arn:aws:cloudwatch:${region}:${account_id}:alarm:${name_prefix}-ALARM-HighErrorRate",
          "arn:aws:cloudwatch:${region}:${account_id}:alarm:${name_prefix}-COMPOSITE-ServiceDegraded"
        ]
      }
    },

    // ── Row 2: LATENCY ───────────────────────────────────────────────────────
    {
      "type": "text",
      "x": 0, "y": 9, "width": 24, "height": 1,
      "properties": { "markdown": "## 🟡 Golden Signal 2: Latency" }
    },
    {
      "type": "metric",
      "x": 0, "y": 10, "width": 8, "height": 6,
      "properties": {
        "title": "ALB Target Response Time",
        "view": "timeSeries",
        "region": "${region}",
        "metrics": [
          ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", "${alb_suffix}", { "stat": "p99",  "period": 60, "label": "p99",  "color": "#d62728" }],
          ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", "${alb_suffix}", { "stat": "p95",  "period": 60, "label": "p95",  "color": "#ff7f0e" }],
          ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", "${alb_suffix}", { "stat": "p50",  "period": 60, "label": "p50",  "color": "#2ca02c" }],
          ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", "${alb_suffix}", { "stat": "Average", "period": 60, "label": "avg", "color": "#1f77b4" }]
        ],
        "annotations": {
          "horizontal": [{ "color": "#ff0000", "label": "p99 Threshold (2s)", "value": 2 }]
        },
        "yAxis": { "left": { "min": 0 } }
      }
    },
    {
      "type": "metric",
      "x": 8, "y": 10, "width": 8, "height": 6,
      "properties": {
        "title": "Custom App Latency (CloudWatch Logs metric)",
        "view": "timeSeries",
        "region": "${region}",
        "metrics": [
          ["TechStream/App", "ResponseTimeMs", { "stat": "p99",  "period": 60, "label": "App p99 ms",  "color": "#d62728" }],
          ["TechStream/App", "ResponseTimeMs", { "stat": "p50",  "period": 60, "label": "App p50 ms",  "color": "#2ca02c" }],
          ["TechStream/App", "ResponseTimeMs", { "stat": "Average", "period": 60, "label": "App avg ms", "color": "#1f77b4" }]
        ],
        "yAxis": { "left": { "min": 0 } }
      }
    },
    {
      "type": "alarm",
      "x": 16, "y": 10, "width": 8, "height": 6,
      "properties": {
        "title": "Latency Alarm Status",
        "alarms": [
          "arn:aws:cloudwatch:${region}:${account_id}:alarm:${name_prefix}-ALARM-HighLatencyP99"
        ]
      }
    },

    // ── Row 3: TRAFFIC ───────────────────────────────────────────────────────
    {
      "type": "text",
      "x": 0, "y": 16, "width": 24, "height": 1,
      "properties": { "markdown": "## 🟢 Golden Signal 3: Traffic" }
    },
    {
      "type": "metric",
      "x": 0, "y": 17, "width": 8, "height": 6,
      "properties": {
        "title": "Request Volume (ALB)",
        "view": "timeSeries",
        "region": "${region}",
        "metrics": [
          ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", "${alb_suffix}", { "stat": "Sum", "period": 60, "label": "Total Requests", "color": "#1f77b4" }]
        ],
        "yAxis": { "left": { "min": 0 } }
      }
    },
    {
      "type": "metric",
      "x": 8, "y": 17, "width": 8, "height": 6,
      "properties": {
        "title": "Target Health (Healthy / Unhealthy Hosts)",
        "view": "timeSeries",
        "region": "${region}",
        "metrics": [
          ["AWS/ApplicationELB", "HealthyHostCount",   "LoadBalancer", "${alb_suffix}", { "stat": "Average", "period": 60, "label": "Healthy",   "color": "#2ca02c" }],
          ["AWS/ApplicationELB", "UnHealthyHostCount", "LoadBalancer", "${alb_suffix}", { "stat": "Average", "period": 60, "label": "Unhealthy", "color": "#d62728" }]
        ],
        "yAxis": { "left": { "min": 0 } }
      }
    },
    {
      "type": "metric",
      "x": 16, "y": 17, "width": 8, "height": 6,
      "properties": {
        "title": "HTTP Status Distribution",
        "view": "timeSeries",
        "stacked": true,
        "region": "${region}",
        "metrics": [
          ["AWS/ApplicationELB", "HTTPCode_Target_2XX_Count", "LoadBalancer", "${alb_suffix}", { "stat": "Sum", "period": 60, "label": "2xx", "color": "#2ca02c" }],
          ["AWS/ApplicationELB", "HTTPCode_Target_3XX_Count", "LoadBalancer", "${alb_suffix}", { "stat": "Sum", "period": 60, "label": "3xx", "color": "#1f77b4" }],
          ["AWS/ApplicationELB", "HTTPCode_Target_4XX_Count", "LoadBalancer", "${alb_suffix}", { "stat": "Sum", "period": 60, "label": "4xx", "color": "#ff7f0e" }],
          ["AWS/ApplicationELB", "HTTPCode_Target_5XX_Count", "LoadBalancer", "${alb_suffix}", { "stat": "Sum", "period": 60, "label": "5xx", "color": "#d62728" }]
        ]
      }
    },

    // ── Row 4: SATURATION ────────────────────────────────────────────────────
    {
      "type": "text",
      "x": 0, "y": 23, "width": 24, "height": 1,
      "properties": { "markdown": "## 🔵 Golden Signal 4: Saturation" }
    },
    {
      "type": "metric",
      "x": 0, "y": 24, "width": 8, "height": 6,
      "properties": {
        "title": "EC2 CPU Utilisation (ASG Average)",
        "view": "timeSeries",
        "region": "${region}",
        "metrics": [
          ["AWS/EC2", "CPUUtilization", "AutoScalingGroupName", "${asg_name}", { "stat": "Average", "period": 60, "label": "CPU %", "color": "#1f77b4" }],
          ["AWS/EC2", "CPUUtilization", "AutoScalingGroupName", "${asg_name}", { "stat": "Maximum", "period": 60, "label": "CPU Max %", "color": "#ff7f0e" }]
        ],
        "annotations": {
          "horizontal": [{ "color": "#ff0000", "label": "Saturation Threshold (80%)", "value": 80 }]
        },
        "yAxis": { "left": { "min": 0, "max": 100 } }
      }
    },
    {
      "type": "metric",
      "x": 8, "y": 24, "width": 8, "height": 6,
      "properties": {
        "title": "Memory Utilisation (CloudWatch Agent)",
        "view": "timeSeries",
        "region": "${region}",
        "metrics": [
          ["TechStream/System", "mem_used_percent", "AutoScalingGroupName", "${asg_name}", { "stat": "Average", "period": 60, "label": "Memory %", "color": "#9467bd" }]
        ],
        "annotations": {
          "horizontal": [{ "color": "#ff0000", "label": "Alert Threshold (85%)", "value": 85 }]
        },
        "yAxis": { "left": { "min": 0, "max": 100 } }
      }
    },
    {
      "type": "metric",
      "x": 16, "y": 24, "width": 8, "height": 6,
      "properties": {
        "title": "ASG Instance Count",
        "view": "timeSeries",
        "region": "${region}",
        "metrics": [
          ["AWS/AutoScaling", "GroupInServiceInstances", "AutoScalingGroupName", "${asg_name}", { "stat": "Average", "period": 60, "label": "InService",   "color": "#2ca02c" }],
          ["AWS/AutoScaling", "GroupDesiredCapacity",    "AutoScalingGroupName", "${asg_name}", { "stat": "Average", "period": 60, "label": "Desired",     "color": "#1f77b4" }],
          ["AWS/AutoScaling", "GroupPendingInstances",   "AutoScalingGroupName", "${asg_name}", { "stat": "Average", "period": 60, "label": "Pending",     "color": "#ff7f0e" }],
          ["AWS/AutoScaling", "GroupTerminatingInstances","AutoScalingGroupName","${asg_name}", { "stat": "Average", "period": 60, "label": "Terminating", "color": "#d62728" }]
        ]
      }
    },

    // ── Row 5: SELF-HEALING METRICS ──────────────────────────────────────────
    {
      "type": "text",
      "x": 0, "y": 30, "width": 24, "height": 1,
      "properties": { "markdown": "## ⚡ Self-Healing Metrics" }
    },
    {
      "type": "metric",
      "x": 0, "y": 31, "width": 8, "height": 6,
      "properties": {
        "title": "Remediation Attempts",
        "view": "timeSeries",
        "region": "${region}",
        "metrics": [
          ["TechStream/Remediation", "RemediationAttempt", { "stat": "Sum",   "period": 300, "label": "Attempts",       "color": "#ff7f0e" }],
          ["TechStream/Remediation", "RestartSuccess",     { "stat": "Sum",   "period": 300, "label": "Restart Success","color": "#2ca02c" }],
          ["TechStream/Remediation", "RestartFailed",      { "stat": "Sum",   "period": 300, "label": "Restart Failed", "color": "#d62728" }]
        ]
      }
    },
    {
      "type": "metric",
      "x": 8, "y": 31, "width": 8, "height": 6,
      "properties": {
        "title": "Network I/O (TechStream/System)",
        "view": "timeSeries",
        "region": "${region}",
        "metrics": [
          ["TechStream/System", "net_bytes_sent", "AutoScalingGroupName", "${asg_name}", { "stat": "Sum", "period": 60, "label": "Bytes Sent",     "color": "#1f77b4" }],
          ["TechStream/System", "net_bytes_recv", "AutoScalingGroupName", "${asg_name}", { "stat": "Sum", "period": 60, "label": "Bytes Received", "color": "#2ca02c" }]
        ]
      }
    },
    {
      "type": "log",
      "x": 16, "y": 31, "width": 8, "height": 6,
      "properties": {
        "title": "Recent Application Errors (Live)",
        "region": "${region}",
        "query": "SOURCE '/techstream/${name_prefix}/app' | fields @timestamp, message, status_code, path, instance_id | filter level = \"ERROR\" | sort @timestamp desc | limit 20",
        "view": "table"
      }
    }

  ]
}
