output "sns_topic_arn" {
  value = var.sns_topic_arn
}

output "remediation_lambda_arn" {
  value = aws_lambda_function.remediation.arn
}

output "rca_lambda_arn" {
  value = aws_lambda_function.rca_analysis.arn
}

output "eventbridge_rule_arn" {
  value = aws_cloudwatch_event_rule.alarm_to_remediation.arn
}
