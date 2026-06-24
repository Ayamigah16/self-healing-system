################################################################################
# AI-Ops Module — Amazon DevOps Guru
#
# DevOps Guru analyses CloudWatch metrics, logs, and X-Ray traces across the
# resources in this stack and surfaces proactive + reactive insights.
#
# Resource coverage is scoped to the ASG by CloudFormation stack tag so Guru
# only watches TechStream resources (not your whole account).
################################################################################

# DevOps Guru requires an SNS topic for notifications.
# We reuse the incidents topic from the automation module via var.sns_topic_arn.

resource "aws_devopsguru_notification_channel" "main" {
  count = var.enable_devops_guru ? 1 : 0

  sns {
    topic_arn = var.sns_topic_arn
  }
}

# Scope DevOps Guru to watch resources tagged with our project
resource "aws_devopsguru_resource_collection" "main" {
  count = var.enable_devops_guru ? 1 : 0

  type = "AWS_TAGS"

  tags {
    app_boundary_key   = "Project"
    tag_values         = ["TechStream-SelfHealing"]
  }
}

# DevOps Guru service integration — enable CloudWatch anomaly detection models
# These are account-level resources; enabling them on this stack turns them on
resource "aws_devopsguru_service_integration" "main" {
  count = var.enable_devops_guru ? 1 : 0

  logs_anomaly_detection {
    opt_in_status = "ENABLED"
  }

  ops_center {
    opt_in_status = "ENABLED"
  }
}

# EventBridge rule to capture DevOps Guru insight events is defined in the
# automation module so the RCA Lambda can be triggered there.
# This module exports the resource collection ARN for reference.
