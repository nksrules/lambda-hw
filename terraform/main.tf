# Provider, backend, and global tags for the lambda-hw project.
#
# State lives in a shared bucket; the key prefix scopes it to this project.
# `use_lockfile = true` uses S3's native conditional-write lock (terraform
# 1.10+) instead of a separate DynamoDB table.

terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.70"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
  }

  backend "s3" {
    bucket       = "ksastry-tf-state"
    key          = "lambda-hw/terraform.tfstate"
    region       = "us-east-1"
    use_lockfile = true
    encrypt      = true
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = "lambda-hw"
      ManagedBy = "terraform"
    }
  }
}
