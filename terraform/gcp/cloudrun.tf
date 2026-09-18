# Cloud Run サービス。var.image が空なら作らない（1 回目の apply で AR / バケット / SA だけ作り、
# Cloud Build でイメージを push してから 2 回目の apply で作る）。
locals {
  service_name = var.service_name != "" ? var.service_name : "${var.name_prefix}-app"
}

resource "google_cloud_run_v2_service" "app" {
  count = var.image == "" ? 0 : 1

  name     = local.service_name
  location = var.region

  # 認証は IAM（roles/run.invoker）で制御する。ネットワーク上は到達可能だが allUsers には付与しない
  ingress             = "INGRESS_TRAFFIC_ALL"
  deletion_protection = false

  template {
    # Cloud Storage ボリュームは第2世代実行環境が必須
    execution_environment = "EXECUTION_ENVIRONMENT_GEN2"
    service_account       = google_service_account.run.email
    timeout               = var.request_timeout

    # 一人で操作する前提。max 1 で複数インスタンスに起因する gcsfuse のキャッシュ不整合を構造的に排除する
    scaling {
      min_instance_count = var.min_instances
      max_instance_count = var.max_instances
    }
    max_instance_request_concurrency = var.concurrency

    containers {
      image = var.image

      ports {
        container_port = 8080
      }

      resources {
        limits = {
          cpu    = var.cpu
          memory = var.memory
        }
        # リクエスト処理中のみ CPU を割り当てる（従量課金の基本構成）
        cpu_idle = true
        # 起動時の CPU 増強（#9 でコールドスタートへの効果を比較）
        startup_cpu_boost = var.startup_cpu_boost
      }

      # アプリの設定（app/src/Config.php が読む）。AWS のアクセスキーは渡さず、
      # SA の ID トークンで AWS_ROLE_ARN のロールを引き受ける（鍵レス。docs/04）
      env {
        name  = "DATA_DIR"
        value = "/mnt/data"
      }
      env {
        name  = "WRITE_MODE"
        value = var.write_mode
      }
      env {
        name  = "S3_BUCKET"
        value = var.s3_bucket
      }
      env {
        name  = "AWS_REGION"
        value = var.aws_region
      }
      env {
        name  = "AWS_ROLE_ARN"
        value = var.aws_role_arn
      }
      env {
        name  = "AWS_WIF_AUDIENCE"
        value = var.aws_wif_audience
      }
      # gcsfuse 検証用の診断経路（#7）。空文字なら無効（Config は空を未設定扱いにする）
      env {
        name  = "FS_CHECK"
        value = var.fs_check ? "1" : ""
      }

      volume_mounts {
        name       = "data"
        mount_path = "/mnt/data"
      }

      # /health はファイルにも S3 にも触らない（app/public/index.php）
      startup_probe {
        http_get {
          path = "/health"
          port = 8080
        }
        initial_delay_seconds = 0
        period_seconds        = 2
        timeout_seconds       = 2
        failure_threshold     = 15
      }
    }

    # 作業領域バケットを gcsfuse でマウントする。
    # Apache の worker は www-data（uid/gid 33）で動くので、マウント上のファイルの所有者を合わせて書き込めるようにする
    # （gcsfuse の既定はマウントしたユーザー所有・0644/0755。docs/01 §4、docs/02 §6 参照）
    volumes {
      name = "data"
      gcs {
        bucket        = google_storage_bucket.data.name
        read_only     = false
        mount_options = ["uid=33", "gid=33"]
      }
    }
  }

  depends_on = [
    google_project_service.services,
    google_storage_bucket_iam_member.run_data,
  ]
}

# 呼び出し許可。非公開運用なので allUsers ではなく、指定したメンバーだけに付与する
resource "google_cloud_run_v2_service_iam_member" "invoker" {
  count = var.image != "" && var.invoker_member != "" ? 1 : 0

  name     = google_cloud_run_v2_service.app[0].name
  location = google_cloud_run_v2_service.app[0].location
  role     = "roles/run.invoker"
  member   = var.invoker_member
}
