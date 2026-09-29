# 監視: Cloud Run の 5xx を検知してメールで知らせるアラートポリシー（Issue #10 の「アラートポリシーの例」。docs/08 §3）。
# alert_email が空なら何も作らない。メトリクス（リクエスト数・レイテンシ・インスタンス数など）は Cloud Run が自動で送るので、
# 見るだけならここで作るものは無い。
locals {
  alert_enabled = var.alert_email != ""
}

resource "google_monitoring_notification_channel" "email" {
  count = local.alert_enabled ? 1 : 0

  display_name = "${local.service_name} アラート通知"
  type         = "email"
  labels = {
    email_address = var.alert_email
  }

  depends_on = [google_project_service.services]
}

resource "google_monitoring_alert_policy" "errors_5xx" {
  count = local.alert_enabled ? 1 : 0

  display_name = "${local.service_name}: 5xx が発生"
  combiner     = "OR"

  conditions {
    display_name = "5 分間の 5xx 応答が 1 回以上"
    condition_threshold {
      # Cloud Run の標準メトリクス。response_code_class で 5xx だけに絞る
      filter          = "resource.type = \"cloud_run_revision\" AND resource.labels.service_name = \"${local.service_name}\" AND metric.type = \"run.googleapis.com/request_count\" AND metric.labels.response_code_class = \"5xx\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0
      duration        = "0s"

      aggregations {
        alignment_period     = "300s"
        per_series_aligner   = "ALIGN_SUM"
        cross_series_reducer = "REDUCE_SUM"
      }

      trigger {
        count = 1
      }
    }
  }

  alert_strategy {
    # 5xx が止まって 30 分たったらインシデントを自動で閉じる
    auto_close = "1800s"
  }

  notification_channels = [google_monitoring_notification_channel.email[0].id]

  documentation {
    mime_type = "text/markdown"
    content   = <<-EOT
      Cloud Run サービス `${local.service_name}` が 5xx を返しました。

      1. 原因のログを見る: `scripts/ops.sh errors 20`（Dev Container 内）
      2. 直前のデプロイが原因なら切り戻す: `scripts/ops.sh revisions` → `scripts/ops.sh rollback <1 つ前のリビジョン>`
      3. 手順の詳細は docs/08-operations.md
    EOT
  }

  depends_on = [google_project_service.services]
}
