# サービスアカウントと権限。
#
# - Cloud Run 実行用 SA: 作業領域バケットの読み書きだけを許可する（gcsfuse は list / get / create / delete を使う）。
#   #6 では、この SA の OIDC ID トークンで AWS の IAM ロールを引き受ける（Workload Identity Federation）
# - Cloud Build: 既定の Compute SA でビルドするため、Artifact Registry への push とログ書き込みを許可する

data "google_project" "this" {
  project_id = var.project_id
}

resource "google_service_account" "run" {
  account_id   = "${var.name_prefix}-run"
  display_name = "EC2 → Cloud Run PoC: Cloud Run 実行用"

  depends_on = [google_project_service.services]
}

# 作業領域バケットへの読み書き
resource "google_storage_bucket_iam_member" "run_data" {
  bucket = google_storage_bucket.data.name
  role   = "roles/storage.objectUser"
  member = "serviceAccount:${google_service_account.run.email}"
}

# Cloud Build（既定の Compute SA）からのイメージ push とログ書き込み
locals {
  cloud_build_sa = "serviceAccount:${data.google_project.this.number}-compute@developer.gserviceaccount.com"
}

resource "google_artifact_registry_repository_iam_member" "cloud_build_writer" {
  location   = google_artifact_registry_repository.app.location
  repository = google_artifact_registry_repository.app.name
  role       = "roles/artifactregistry.writer"
  member     = local.cloud_build_sa
}

resource "google_project_iam_member" "cloud_build_log_writer" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = local.cloud_build_sa
}
