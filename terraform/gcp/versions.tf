# Terraform と Google provider のバージョン固定。
# state は GCS の remote backend（バケット <PROJECT_ID>-tfstate、prefix "gcp"）。複数の環境から apply できるようにする。
# bucket は backend ブロックに書けない（変数が使えず、プロジェクト ID はコミットしない）ので、
# scripts/tf-init.sh が -backend-config で渡す。init は必ず scripts/tf-init.sh gcp で行う。
terraform {
  required_version = ">= 1.5"

  backend "gcs" {
    prefix = "gcp"
  }

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
