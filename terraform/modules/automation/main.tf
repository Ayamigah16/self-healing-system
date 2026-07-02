################################################################################
# Automation Module
# EventBridge · Lambda Remediation · Lambda RCA
# SNS topic lives in the root module (shared with monitoring to avoid a cycle)
################################################################################

# ─── Lambda: Remediation ──────────────────────────────────────────────────────
data "archive_file" "remediation" {
  type        = "zip"
  source_dir  = "${path.module}/../../../lambda/remediation"
  output_path = "/tmp/remediation_${var.suffix}.zip"
}

resource "aws_cloudwatch_log_group" "remediation_lambda" {
  name              = "/aws/lambda/${var.name_prefix}-remediation"
  retention_in_days = 90
}

resource "aws_lambda_function" "remediation" {
  function_name    = "${var.name_prefix}-remediation"
  filename         = data.archive_file.remediation.output_path
  source_code_hash = data.archive_file.remediation.output_base64sha256
  handler          = "handler.lambda_handler"
  runtime          = "python3.12"
  role             = var.lambda_exec_role_arn
  timeout          = 300
  memory_size      = 256

  environment {
    variables = {
      ASG_NAME        = var.asg_name
      ASG_MAX_SIZE    = tostring(var.asg_max_size)
      SNS_TOPIC_ARN   = var.sns_topic_arn
      REGION          = var.region
      LOG_LEVEL       = "INFO"
    }
  }

  depends_on = [aws_cloudwatch_log_group.remediation_lambda]

  tags = { Name = "${var.name_prefix}-remediation-lambda" }
}

# ─── Lambda: RCA Analysis (AI-assisted) ──────────────────────────────────────
data "archive_file" "rca" {
  type        = "zip"
  source_dir  = "${path.module}/../../../lambda/rca-analysis"
  output_path = "/tmp/rca_${var.suffix}.zip"
}

resource "aws_cloudwatch_log_group" "rca_lambda" {
  name              = "/aws/lambda/${var.name_prefix}-rca-analysis"
  retention_in_days = 90
}

resource "aws_lambda_function" "rca_analysis" {
  function_name    = "${var.name_prefix}-rca-analysis"
  filename         = data.archive_file.rca.output_path
  source_code_hash = data.archive_file.rca.output_base64sha256
  handler          = "handler.lambda_handler"
  runtime          = "python3.12"
  role             = var.lambda_exec_role_arn
  timeout          = 300
  memory_size      = 512

  environment {
    variables = {
      SNS_TOPIC_ARN = var.sns_topic_arn
      REGION        = var.region
      LOG_LEVEL     = "INFO"
    }
  }

  depends_on = [aws_cloudwatch_log_group.rca_lambda]

  tags = { Name = "${var.name_prefix}-rca-lambda" }
}

# ─── EventBridge Rule: CloudWatch Alarm → Remediation Lambda ─────────────────
resource "aws_cloudwatch_event_rule" "alarm_to_remediation" {
  name        = "${var.name_prefix}-alarm-remediation"
  description = "Route CloudWatch ALARM state changes to self-healing Lambda"

  event_pattern = jsonencode({
    source      = ["aws.cloudwatch"]
    "detail-type" = ["CloudWatch Alarm State Change"]
    detail = {
      state = { value = ["ALARM"] }
      alarmName = [{ prefix = var.name_prefix }]
    }
  })

  tags = { Name = "${var.name_prefix}-alarm-remediation-rule" }
}

resource "aws_cloudwatch_event_target" "remediation_lambda" {
  rule      = aws_cloudwatch_event_rule.alarm_to_remediation.name
  target_id = "RemediationLambda"
  arn       = aws_lambda_function.remediation.arn
}

resource "aws_lambda_permission" "allow_eventbridge_remediation" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.remediation.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.alarm_to_remediation.arn
}

# ─── EventBridge Rule: DevOps Guru Insight → RCA Lambda ─────────────────────
resource "aws_cloudwatch_event_rule" "devops_guru_to_rca" {
  name        = "${var.name_prefix}-devops-guru-rca"
  description = "Route DevOps Guru new insights to RCA analysis Lambda"

  event_pattern = jsonencode({
    source        = ["aws.devops-guru"]
    "detail-type" = ["DevOps Guru New Insight Open"]
  })

  tags = { Name = "${var.name_prefix}-devops-guru-rca-rule" }
}

resource "aws_cloudwatch_event_target" "rca_lambda" {
  rule      = aws_cloudwatch_event_rule.devops_guru_to_rca.name
  target_id = "RCALambda"
  arn       = aws_lambda_function.rca_analysis.arn
}

resource "aws_lambda_permission" "allow_eventbridge_rca" {
  statement_id  = "AllowEventBridgeRCAInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.rca_analysis.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.devops_guru_to_rca.arn
}

# ─── SNS → Lambda trigger for CloudWatch alarm SNS notifications ─────────────
resource "aws_sns_topic_subscription" "remediation_lambda" {
  topic_arn = var.sns_topic_arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.remediation.arn
}

resource "aws_lambda_permission" "allow_sns_remediation" {
  statement_id  = "AllowSNSTrigger"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.remediation.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = var.sns_topic_arn
}
