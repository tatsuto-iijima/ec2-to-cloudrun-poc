# Terraform と Google provider のバージョン固定。
# state はローカル（terraform.tfstate。.gitignore 済み）。PoC は一人で作業する前提。
terraform {
  required_version = ">= 1.5"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 8.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}
