variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Deployment environment (prod, staging, dev)"
  type        = string
  default     = "prod"

  validation {
    condition     = contains(["prod", "staging", "dev"], var.environment)
    error_message = "Environment must be prod, staging, or dev."
  }
}

variable "project_name" {
  description = "Project identifier used as a name prefix for all resources"
  type        = string
  default     = "techstream-sh"
}

# ─── Networking ──────────────────────────────────────────────────────────────
variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "availability_zones" {
  description = "List of AZs to spread resources across (min 2 for HA)"
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b", "us-east-1c"]
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for public subnets (one per AZ)"
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
}

variable "private_subnet_cidrs" {
  description = "CIDR blocks for private subnets (one per AZ)"
  type        = list(string)
  default     = ["10.0.11.0/24", "10.0.12.0/24", "10.0.13.0/24"]
}

# ─── Compute ─────────────────────────────────────────────────────────────────
variable "instance_type" {
  description = "EC2 instance type for the web server fleet"
  type        = string
  default     = "t3.micro"
}

variable "asg_min_size" {
  description = "Minimum number of instances in the Auto Scaling Group"
  type        = number
  default     = 2
}

variable "asg_max_size" {
  description = "Maximum number of instances the ASG can scale to"
  type        = number
  default     = 6
}

variable "asg_desired_capacity" {
  description = "Initial desired instance count"
  type        = number
  default     = 2
}

variable "ami_id" {
  description = "Amazon Linux 2023 AMI — leave empty to use latest AL2023 in region"
  type        = string
  default     = ""
}

variable "key_pair_name" {
  description = "EC2 key pair name for SSH access (optional)"
  type        = string
  default     = ""
}

# ─── Alerting ────────────────────────────────────────────────────────────────
variable "alert_email" {
  description = "Email address to receive incident and remediation notifications"
  type        = string
  default     = "oncall@techstream.io"
}

variable "error_rate_threshold" {
  description = "HTTP 5xx error rate (%) that triggers the self-healing alarm"
  type        = number
  default     = 5
}

variable "latency_threshold_ms" {
  description = "P99 latency threshold in milliseconds that triggers an alarm"
  type        = number
  default     = 2000
}

variable "cpu_threshold_percent" {
  description = "EC2 CPU utilisation (%) that triggers a saturation alarm"
  type        = number
  default     = 80
}

# ─── DevOps Guru ─────────────────────────────────────────────────────────────
variable "enable_devops_guru" {
  description = "Enable Amazon DevOps Guru on the CloudFormation stack scope"
  type        = bool
  default     = true
}
