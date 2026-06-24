terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.50"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
  }

  # Remote state — swap for your S3 bucket / DynamoDB table before apply
  # backend "s3" {
  #   bucket         = "techstream-terraform-state"
  #   key            = "self-healing/terraform.tfstate"
  #   region         = "us-east-1"
  #   dynamodb_table = "techstream-terraform-locks"
  #   encrypt        = true
  # }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "TechStream-SelfHealing"
      Environment = var.environment
      ManagedBy   = "Terraform"
      Owner       = "platform-team"
    }
  }
}
