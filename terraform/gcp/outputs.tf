output "artifact_registry_repository" {
  description = "Artifact Registry のリポジトリ URL"
  value       = local.repository_url
}

output "image_uri" {
  description = "イメージ名（タグなし）。cloudbuild.yaml の _IMAGE と var.image に使う"
  value       = local.image_uri
}

output "bucket_name" {
  description = "作業領域バケット（Cloud Run の /mnt/data）"
  value       = google_storage_bucket.data.name
}

output "service_account_email" {
  description = "Cloud Run 実行用サービスアカウント（#6 の WIF で AWS 側の信頼ポリシーに使う）"
  value       = google_service_account.run.email
}

output "build_service_account_email" {
  description = "Cloud Build 用サービスアカウント（cloudbuild.yaml の serviceAccount に使う）"
  value       = google_service_account.build.email
}

output "service_account_unique_id" {
  description = "サービスアカウントの一意 ID（#6 の WIF で accounts.google.com:sub / aud の条件に使う）"
  value       = google_service_account.run.unique_id
}

output "service_url" {
  description = "Cloud Run サービスの URL（var.image を指定して apply した後に出る）"
  value       = var.image == "" ? null : google_cloud_run_v2_service.app[0].uri
}

output "service_name" {
  description = "Cloud Run サービス名（gcloud run services proxy 等で使う）"
  value       = var.image == "" ? null : google_cloud_run_v2_service.app[0].name
}

output "cold_start_config" {
  description = "コールドスタート計測の構成ラベル（scripts/cold-start.sh が結果に記録する）"
  value       = "min${var.min_instances}-boost${var.startup_cpu_boost ? 1 : 0}"
}
