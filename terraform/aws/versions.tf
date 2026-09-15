# Terraform と AWS provider のバージョン固定。
# state は GCS の remote backend（バケット <PROJECT_ID>-tfstate、prefix "aws"）。複数の環境から apply できるようにする。
# bucket は backend ブロックに書けない（変数が使えず、プロジェクト ID はコミットしない）ので、
# scripts/tf-init.sh が -backend-config で渡す。init は必ず scripts/tf-init.sh aws で行う。
terraform {
  required_version = ">= 1.5"

  backend "gcs" {
    prefix = "aws"
  }

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
