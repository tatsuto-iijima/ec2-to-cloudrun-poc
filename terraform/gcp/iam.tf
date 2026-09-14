# サービスアカウントと権限。
#
# - Cloud Run 実行用 SA: 作業領域バケットの読み書きだけを許可する（gcsfuse は list / get / create / delete を使う）。
#   #6 では、この SA の OIDC ID トークンで AWS の IAM ロールを引き受ける（Workload Identity Federation）
# - Cloud Build 用 SA: 専用の SA を作り、ソースの読み取り・Artifact Registry への push・ログ書き込みだけを許可する。
#   既定の Compute SA は Compute Engine API を有効にしないと存在せず（新規プロジェクトで apply が失敗した）、
#   組織ポリシーで無効化されていることもあるため使わない

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

# Cloud Build 用 SA（cloudbuild.yaml の serviceAccount で指定する）
resource "google_service_account" "build" {
  account_id   = "${var.name_prefix}-build"
  display_name = "EC2 → Cloud Run PoC: Cloud Build 用"

  depends_on = [google_project_service.services]
}

# gcloud builds submit がソースを置くバケット。既定名 PROJECT_ID_cloudbuild を先に作っておき、
# ビルド用 SA に読み取りを許可する（既定の Compute SA のような広い権限を持たせない）
resource "google_storage_bucket" "build_source" {
  name     = "${var.project_id}_cloudbuild"
  location = var.region

  uniform_bucket_level_access = true
  force_destroy               = true
  public_access_prevention    = "enforced"

  depends_on = [google_project_service.services]
}

resource "google_storage_bucket_iam_member" "build_source_viewer" {
  bucket = google_storage_bucket.build_source.name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.build.email}"
}

resource "google_artifact_registry_repository_iam_member" "build_writer" {
  location   = google_artifact_registry_repository.app.location
  repository = google_artifact_registry_repository.app.name
  role       = "roles/artifactregistry.writer"
  member     = "serviceAccount:${google_service_account.build.email}"
}

resource "google_project_iam_member" "build_log_writer" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.build.email}"
}
