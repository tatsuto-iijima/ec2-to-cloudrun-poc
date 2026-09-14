# コンテナイメージの保管先（Artifact Registry、Docker 形式）。
resource "google_artifact_registry_repository" "app" {
  location      = var.region
  repository_id = "${var.name_prefix}-app"
  description   = "EC2 → Cloud Run PoC のサンプルアプリのイメージ"
  format        = "DOCKER"

  depends_on = [google_project_service.services]
}

locals {
  # 例: asia-northeast1-docker.pkg.dev/PROJECT/poc-app
  repository_url = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.app.repository_id}"
  image_uri      = "${local.repository_url}/app"
}
