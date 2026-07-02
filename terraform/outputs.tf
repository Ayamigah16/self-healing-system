output "alb_dns_name" {
  description = "Public DNS name of the Application Load Balancer"
  value       = module.compute.alb_dns_name
}

output "alb_url" {
  description = "HTTP URL to reach the web application"
  value       = "http://${module.compute.alb_dns_name}"
}

output "cloudwatch_dashboard_url" {
  description = "Direct link to the Golden Signals dashboard"
  value       = "https://${var.aws_region}.console.aws.amazon.com/cloudwatch/home?region=${var.aws_region}#dashboards:name=${module.monitoring.dashboard_name}"
}

output "asg_name" {
  description = "Name of the Auto Scaling Group"
  value       = module.compute.asg_name
}

output "sns_topic_arn" {
  description = "ARN of the SNS topic used for incident notifications"
  value       = aws_sns_topic.incidents.arn
}

output "remediation_lambda_arn" {
  description = "ARN of the self-healing Lambda function"
  value       = module.automation.remediation_lambda_arn
}

output "vpc_id" {
  description = "ID of the VPC"
  value       = module.networking.vpc_id
}

output "devops_guru_enabled" {
  description = "Whether DevOps Guru is enabled on this stack"
  value       = var.enable_devops_guru
}
