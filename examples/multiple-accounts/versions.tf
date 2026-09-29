terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0"
    }
  }
}

provider "aws" {
  alias  = "production"
  region = "us-east-1"

  assume_role {
    role_arn = var.production_deployment_role_arn
  }
}

provider "aws" {
  alias  = "staging"
  region = "us-east-1"

  assume_role {
    role_arn = var.staging_deployment_role_arn
  }
}
