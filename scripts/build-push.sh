#!/usr/bin/env bash
# Cloud Build で実行イメージ（--target runtime）をビルドし、Artifact Registry へ push する。
# terraform/gcp の output からイメージ名と Cloud Build 用 SA を組み立てるので、引数は不要。
#
# 使い方（Dev Container 内、1 回目の terraform apply の後）:
#   scripts/build-push.sh
# 終了時に、2 回目の terraform apply に渡す image の値を表示する。
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

cat <<EOF

push 完了。2 回目の apply:
  terraform -chdir=terraform/gcp apply -var image=${image_uri}:${short_sha}
EOF
