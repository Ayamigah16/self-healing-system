################################################################################
# TechStream Self-Healing System — Root Module
#
# Orchestrates: networking → IAM → compute → monitoring → automation → ai-ops
################################################################################

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

resource "random_id" "suffix" {
  byte_length = 4
}

locals {
  name_prefix  = "${var.project_name}-${var.environment}"
  account_id   = data.aws_caller_identity.current.account_id
  region       = data.aws_region.current.name
  suffix       = random_id.suffix.hex
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
  log_group_name       = module.monitoring.app_log_group_name

  depends_on = [module.iam, module.networking, module.monitoring]
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
  sns_topic_arn        = module.automation.sns_topic_arn
  region               = local.region
  account_id           = local.account_id

  depends_on = [module.compute, module.automation]
}

# ─── 5. Automation (EventBridge + Lambda + SSM) ──────────────────────────────
module "automation" {
  source = "./modules/automation"

  name_prefix            = local.name_prefix
  suffix                 = local.suffix
  alert_email            = var.alert_email
  region                 = local.region
  account_id             = local.account_id
  asg_name               = module.compute.asg_name
  lambda_exec_role_arn   = module.iam.lambda_exec_role_arn
  asg_max_size           = var.asg_max_size

  depends_on = [module.iam, module.compute]
}

# ─── 6. AI Ops (DevOps Guru) ─────────────────────────────────────────────────
module "ai_ops" {
  source = "./modules/ai-ops"

  name_prefix        = local.name_prefix
  enable_devops_guru = var.enable_devops_guru
  sns_topic_arn      = module.automation.sns_topic_arn
  region             = local.region
  account_id         = local.account_id
  asg_name           = module.compute.asg_name

  depends_on = [module.compute, module.automation]
}
