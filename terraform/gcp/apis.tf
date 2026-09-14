# 必要な API の有効化。destroy しても API は無効化しない（他の用途に影響させない）。
locals {
  services = [
    "run.googleapis.com",              # Cloud Run
    "artifactregistry.googleapis.com", # コンテナイメージの保管
    "cloudbuild.googleapis.com",       # イメージのビルド（gcloud builds submit）
    "iam.googleapis.com",              # サービスアカウント
    "storage.googleapis.com",          # Cloud Storage（ボリューム）
  ]
}

resource "google_project_service" "services" {
  for_each = toset(local.services)

  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}
