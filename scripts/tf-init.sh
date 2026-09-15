#!/usr/bin/env bash
# Terraform の state を置く GCS バケットを用意し、terraform/<dir> を remote backend（gcs）で init する。
#
# 使い方: scripts/tf-init.sh gcp | aws  [terraform init の追加引数]
#   - バケット名は「gcloud の現在のプロジェクト」-tfstate（環境変数 TFSTATE_BUCKET で上書き可）。
#     無ければ作る（asia-northeast1、uniform access、public access prevention、バージョニング有効）。
#     Terraform の管理外（鶏と卵）なので terraform destroy では消えない。PoC 終了時に gcloud storage rm -r で消す
#   - backend ブロックには変数が使えないので、バケット名は -backend-config で渡す（versions.tf には prefix だけ書いてある）
#   - ローカルに state が残っていれば -migrate-state で移行する（Terraform が確認を出す。-force-copy はしない）
#   - 認証は gcloud の Application Default Credentials（terraform/aws の init にも GCP の認証が要る）
set -euo pipefail

dir=${1:?usage: scripts/tf-init.sh gcp|aws [terraform init args]}
shift
cd "$(dirname "$0")/.."

if [[ ! -d "terraform/$dir" ]]; then
  echo "terraform/$dir がありません（gcp か aws を指定）" >&2
  exit 1
fi

project=$(gcloud config get-value project 2>/dev/null || true)
if [[ -z "$project" ]]; then
  echo "gcloud のプロジェクトが未設定です: gcloud config set project <PROJECT_ID>" >&2
  exit 1
fi

bucket="${TFSTATE_BUCKET:-${project}-tfstate}"

if gcloud storage buckets describe "gs://$bucket" >/dev/null 2>&1; then
  echo "state bucket: gs://$bucket（既存）"
else
  echo "state bucket: gs://$bucket を作成します"
  gcloud storage buckets create "gs://$bucket" --project "$project" --location asia-northeast1 \
    --uniform-bucket-level-access --public-access-prevention
  gcloud storage buckets update "gs://$bucket" --versioning
fi

terraform -chdir="terraform/$dir" init -backend-config="bucket=$bucket" -migrate-state "$@"
