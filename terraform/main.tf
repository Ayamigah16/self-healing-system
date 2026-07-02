################################################################################
# TechStream Self-Healing System — Root Module
#
# Dependency order (no cycles):
#   networking, iam  (no deps)
#   sns              (no deps — shared by monitoring + automation)
#   compute          (networking, iam)
#   monitoring       (compute, sns)
#   automation       (iam, compute, sns)
#   ai_ops           (compute, sns)
################################################################################

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

resource "random_id" "suffix" {
  byte_length = 4
}

locals {
  name_prefix        = "${var.project_name}-${var.environment}"
  account_id         = data.aws_caller_identity.current.account_id
  region             = data.aws_region.current.name
  suffix             = random_id.suffix.hex
  # Computed here so compute module does not need to depend on monitoring
  app_log_group_name = "/techstream/${var.project_name}-${var.environment}/app"
}

# ─── SNS Topic (shared) ──────────────────────────────────────────────────────
# Defined at root so both monitoring (alarm_actions) and automation (Lambda
# env var, SNS→Lambda trigger) can reference it without creating a cycle.
resource "aws_sns_topic" "incidents" {
  name = "${local.name_prefix}-incidents"
  tags = { Name = "${local.name_prefix}-incidents" }
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.incidents.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

resource "aws_sns_topic_policy" "cloudwatch" {
  arn = aws_sns_topic.incidents.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowCloudWatchAlarms"
        Effect    = "Allow"
        Principal = { Service = "cloudwatch.amazonaws.com" }
        Action    = "SNS:Publish"
        Resource  = aws_sns_topic.incidents.arn
      },
      {
        Sid       = "AllowEventBridge"
        Effect    = "Allow"
        Principal = { Service = "events.amazonaws.com" }
        Action    = "SNS:Publish"
        Resource  = aws_sns_topic.incidents.arn
      }
    ]
  })
}

# ─── 1. Networking ───────────────────────────────────────────────────────────
module "networking" {
  source = "./modules/networking"

  name_prefix          = local.name_prefix
  vpc_cidr             = var.vpc_cidr
  availability_zones   = var.availability_zones
  public_subnet_cidrs  = var.public_subnet_cidrs
  private_subnet_cidrs = var.private_subnet_cidrs
}

# ─── 2. IAM Roles & Policies ─────────────────────────────────────────────────
module "iam" {
  source = "./modules/iam"

  name_prefix = local.name_prefix
  account_id  = local.account_id
  region      = local.region
}

# ─── 3. Compute (ALB + ASG) ──────────────────────────────────────────────────
module "compute" {
  source = "./modules/compute"

  name_prefix          = local.name_prefix
  suffix               = local.suffix
  vpc_id               = module.networking.vpc_id
  public_subnet_ids    = module.networking.public_subnet_ids
  private_subnet_ids   = module.networking.private_subnet_ids
  instance_type        = var.instance_type
  ami_id               = var.ami_id
  key_pair_name        = var.key_pair_name
  ec2_instance_profile = module.iam.ec2_instance_profile_name
  asg_min_size         = var.asg_min_size
  asg_max_size         = var.asg_max_size
  asg_desired_capacity = var.asg_desired_capacity
  alb_sg_id            = module.networking.alb_sg_id
  ec2_sg_id            = module.networking.ec2_sg_id
  log_group_name       = local.app_log_group_name

  depends_on = [module.iam, module.networking]
}

# ─── 4. Monitoring (CloudWatch) ──────────────────────────────────────────────
module "monitoring" {
  source = "./modules/monitoring"

  name_prefix          = local.name_prefix
  alb_arn_suffix       = module.compute.alb_arn_suffix
  asg_name             = module.compute.asg_name
  error_rate_threshold = var.error_rate_threshold
  latency_threshold_ms = var.latency_threshold_ms
  cpu_threshold        = var.cpu_threshold_percent
  sns_topic_arn        = aws_sns_topic.incidents.arn
  region               = local.region
  account_id           = local.account_id

  depends_on = [module.compute]
}

# ─── 5. Automation (EventBridge + Lambda + SSM) ──────────────────────────────
module "automation" {
  source = "./modules/automation"

  name_prefix          = local.name_prefix
  suffix               = local.suffix
  sns_topic_arn        = aws_sns_topic.incidents.arn
  region               = local.region
  account_id           = local.account_id
  asg_name             = module.compute.asg_name
  lambda_exec_role_arn = module.iam.lambda_exec_role_arn
  asg_max_size         = var.asg_max_size

  depends_on = [module.iam, module.compute]
}

# ─── 6. AI Ops (DevOps Guru) ─────────────────────────────────────────────────
module "ai_ops" {
  source = "./modules/ai-ops"

  name_prefix        = local.name_prefix
  enable_devops_guru = var.enable_devops_guru
  sns_topic_arn      = aws_sns_topic.incidents.arn
  region             = local.region
  account_id         = local.account_id
  asg_name           = module.compute.asg_name

  depends_on = [module.compute]
}
