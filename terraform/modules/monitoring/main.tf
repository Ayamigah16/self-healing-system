################################################################################
# Monitoring Module
# CloudWatch Log Groups · Golden Signal Alarms · Dashboard
################################################################################

# ─── Log Groups ───────────────────────────────────────────────────────────────
resource "aws_cloudwatch_log_group" "app" {
  name              = "/techstream/${var.name_prefix}/app"
  retention_in_days = 30
  tags              = { Name = "${var.name_prefix}-app-logs" }
}

resource "aws_cloudwatch_log_group" "nginx" {
  name              = "/techstream/${var.name_prefix}/nginx"
  retention_in_days = 14
}

resource "aws_cloudwatch_log_group" "remediation" {
  name              = "/techstream/${var.name_prefix}/remediation"
  retention_in_days = 90
}

# ─── Log Metric Filters — extract Golden Signal metrics from logs ──────────────

# Error rate: count 5xx responses from the application
resource "aws_cloudwatch_log_metric_filter" "http_5xx" {
  name           = "${var.name_prefix}-http-5xx-filter"
  pattern        = "[..., status_code=5*, ...]"
  log_group_name = aws_cloudwatch_log_group.app.name

  metric_transformation {
    name          = "HTTP5xxCount"
    namespace     = "TechStream/App"
    value         = "1"
    default_value = "0"
  }
}

resource "aws_cloudwatch_log_metric_filter" "http_all" {
  name           = "${var.name_prefix}-http-all-filter"
  pattern        = "[..., status_code, ...]"
  log_group_name = aws_cloudwatch_log_group.app.name

  metric_transformation {
    name          = "HTTPRequestCount"
    namespace     = "TechStream/App"
    value         = "1"
    default_value = "0"
  }
}

# Latency: extract response_time_ms from structured JSON logs
resource "aws_cloudwatch_log_metric_filter" "response_time" {
  name           = "${var.name_prefix}-response-time-filter"
  pattern        = "{ $.response_time_ms = * }"
  log_group_name = aws_cloudwatch_log_group.app.name

  metric_transformation {
    name          = "ResponseTimeMs"
    namespace     = "TechStream/App"
    value         = "$.response_time_ms"
    default_value = "0"
    unit          = "Milliseconds"
  }
}

# ─── CloudWatch Alarms — Golden Signals ───────────────────────────────────────

# ── Golden Signal 1: ERRORS ────────────────────────────────────────────────────
# Alarm when ALB 5xx error count exceeds the threshold
resource "aws_cloudwatch_metric_alarm" "error_rate_high" {
  alarm_name          = "${var.name_prefix}-ALARM-HighErrorRate"
  alarm_description   = "GOLDEN SIGNAL: HTTP 5xx error rate exceeded ${var.error_rate_threshold}% — self-healing triggered"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  threshold           = var.error_rate_threshold

  # Use a math expression to compute error % from ALB metrics
  metric_query {
    id          = "error_rate"
    expression  = "IF(total > 0, (errors/total)*100, 0)"
    label       = "Error Rate (%)"
    return_data = true
  }

  metric_query {
    id = "errors"
    metric {
      namespace   = "AWS/ApplicationELB"
      metric_name = "HTTPCode_Target_5XX_Count"
      dimensions  = { LoadBalancer = var.alb_arn_suffix }
      period      = 60
      stat        = "Sum"
    }
  }

  metric_query {
    id = "total"
    metric {
      namespace   = "AWS/ApplicationELB"
      metric_name = "RequestCount"
      dimensions  = { LoadBalancer = var.alb_arn_suffix }
      period      = 60
      stat        = "Sum"
    }
  }

  alarm_actions             = [var.sns_topic_arn]
  ok_actions                = [var.sns_topic_arn]
  insufficient_data_actions = []
  treat_missing_data        = "notBreaching"

  tags = { GoldenSignal = "errors" }
}

# ── Golden Signal 2: LATENCY ───────────────────────────────────────────────────
resource "aws_cloudwatch_metric_alarm" "latency_p99_high" {
  alarm_name          = "${var.name_prefix}-ALARM-HighLatencyP99"
  alarm_description   = "GOLDEN SIGNAL: ALB P99 response time exceeded ${var.latency_threshold_ms}ms"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  threshold           = var.latency_threshold_ms / 1000.0 # ALB metric is in seconds
  metric_name         = "TargetResponseTime"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "p99"
  dimensions          = { LoadBalancer = var.alb_arn_suffix }

  alarm_actions      = [var.sns_topic_arn]
  ok_actions         = [var.sns_topic_arn]
  treat_missing_data = "notBreaching"

  tags = { GoldenSignal = "latency" }
}

# ── Golden Signal 3: SATURATION ────────────────────────────────────────────────
resource "aws_cloudwatch_metric_alarm" "cpu_high" {
  alarm_name          = "${var.name_prefix}-ALARM-HighCPUSaturation"
  alarm_description   = "GOLDEN SIGNAL: Average EC2 CPU utilisation exceeded ${var.cpu_threshold}%"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  threshold           = var.cpu_threshold
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 60
  statistic           = "Average"
  dimensions          = { AutoScalingGroupName = var.asg_name }

  alarm_actions      = [var.sns_topic_arn]
  ok_actions         = [var.sns_topic_arn]
  treat_missing_data = "notBreaching"

  tags = { GoldenSignal = "saturation" }
}

# Memory saturation (from CloudWatch Agent custom metrics)
resource "aws_cloudwatch_metric_alarm" "memory_high" {
  alarm_name          = "${var.name_prefix}-ALARM-HighMemorySaturation"
  alarm_description   = "GOLDEN SIGNAL: Average memory utilisation exceeded 85%"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  threshold           = 85
  metric_name         = "mem_used_percent"
  namespace           = "TechStream/System"
  period              = 60
  statistic           = "Average"
  dimensions          = { AutoScalingGroupName = var.asg_name }

  alarm_actions      = [var.sns_topic_arn]
  ok_actions         = [var.sns_topic_arn]
  treat_missing_data = "missing"

  tags = { GoldenSignal = "saturation" }
}

# ── Golden Signal 4: TRAFFIC — no alert, dashboard metric only ────────────────
# Alarms aren't needed for traffic alone — monitored on the dashboard.

# ─── Composite Alarm — requires BOTH error AND latency to fire remediation ──
resource "aws_cloudwatch_composite_alarm" "service_degraded" {
  alarm_name        = "${var.name_prefix}-COMPOSITE-ServiceDegraded"
  alarm_description = "Service degraded: high errors AND high latency detected simultaneously"

  alarm_rule = "ALARM(\"${aws_cloudwatch_metric_alarm.error_rate_high.alarm_name}\") OR ALARM(\"${aws_cloudwatch_metric_alarm.latency_p99_high.alarm_name}\")"

  alarm_actions = [var.sns_topic_arn]
  ok_actions    = [var.sns_topic_arn]

  tags = { Role = "remediation-trigger" }
}

# ─── CloudWatch Dashboard — Golden Signals ────────────────────────────────────
resource "aws_cloudwatch_dashboard" "golden_signals" {
  dashboard_name = "${var.name_prefix}-golden-signals"
  dashboard_body = templatefile("${path.module}/../../../dashboards/golden_signals.json.tpl", {
    region       = var.region
    alb_suffix   = var.alb_arn_suffix
    asg_name     = var.asg_name
    account_id   = var.account_id
    name_prefix  = var.name_prefix
  })
}
