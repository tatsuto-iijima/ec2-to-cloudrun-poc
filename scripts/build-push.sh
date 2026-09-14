#!/usr/bin/env bash
# Cloud Build で実行イメージ（--target runtime）をビルドし、Artifact Registry へ push する。
# terraform/gcp の output からイメージ名と Cloud Build 用 SA を組み立てるので、引数は不要。
#
# 使い方（Dev Container 内、1 回目の terraform apply の後）:
#   scripts/build-push.sh
# push したタグを terraform/gcp/image.auto.tfvars に書き出すので、2 回目以降の
# terraform apply は -var image=... なしで実行できる（HEAD とビルド済みタグのずれを防ぐ）。
set -euo pipefail

cd "$(dirname "$0")/.."

tf() { terraform -chdir=terraform/gcp output -raw "$1"; }

image_uri=$(tf image_uri)
build_sa=$(tf build_service_account_email)
short_sha=$(git rev-parse --short HEAD)
project=$(gcloud config get-value project 2>/dev/null || true)

if [[ -z "$project" ]]; then
  echo "gcloud のプロジェクトが未設定です: gcloud config set project <PROJECT_ID>" >&2
  exit 1
fi

echo "project : $project"
echo "image   : ${image_uri}:${short_sha}"
echo "build SA: ${build_sa}"

gcloud builds submit --config cloudbuild.yaml \
  --substitutions "_IMAGE=${image_uri},_BUILD_SA=${build_sa},SHORT_SHA=${short_sha}" .

# ビルドしたタグを Terraform の変数として保存する（*.tfvars は .gitignore 済み）
tfvars=terraform/gcp/image.auto.tfvars
cat > "$tfvars" <<EOF
# scripts/build-push.sh が生成。最後に push したイメージ（コミットしない）
image = "${image_uri}:${short_sha}"
EOF

cat <<EOF

push 完了。${tfvars} に image を書き出しました。2 回目の apply:
  terraform -chdir=terraform/gcp apply
EOF
