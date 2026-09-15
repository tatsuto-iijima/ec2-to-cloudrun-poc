# Terraform と AWS provider のバージョン固定。
# state はローカル（terraform.tfstate。.gitignore 済み）。PoC は一人で作業する前提。
terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = var.region
}
