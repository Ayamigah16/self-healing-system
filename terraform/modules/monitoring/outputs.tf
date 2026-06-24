output "app_log_group_name" {
  value = aws_cloudwatch_log_group.app.name
}

output "remediation_log_group_name" {
  value = aws_cloudwatch_log_group.remediation.name
}

output "dashboard_name" {
  value = aws_cloudwatch_dashboard.golden_signals.dashboard_name
}

output "error_alarm_arn" {
  value = aws_cloudwatch_metric_alarm.error_rate_high.arn
}

output "composite_alarm_arn" {
  value = aws_cloudwatch_composite_alarm.service_degraded.arn
}
