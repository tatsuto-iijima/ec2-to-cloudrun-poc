# Cloud Run の実行用サービスアカウントが引き受ける IAM ロール（Workload Identity Federation の逆方向）。
#
# - AWS には Google（accounts.google.com）用の OIDC プロバイダが組み込まれているので、IAM OIDC プロバイダの作成は不要
# - 信頼ポリシーの条件キーと Google ID トークンのクレームの対応:
#     accounts.google.com:sub  = sub （サービスアカウントの一意 ID）
#     accounts.google.com:aud  = azp （サービスアカウントの ID トークンでは sub と同じ一意 ID）
#     accounts.google.com:oaud = aud （トークン取得時に指定した audience。既定はこのロールの ARN）
#   3 つとも StringEquals で縛り、Cloud Run の SA が「このロールのために」取ったトークン以外を拒否する
# - ロールの権限はアップロード先バケットへの s3:PutObject のみ

data "aws_caller_identity" "current" {}

locals {
  role_name = "${var.name_prefix}-cloudrun-s3-upload"
  # ロール自身の ARN を信頼ポリシーで参照すると循環するので、アカウント ID と名前から組み立てる
  role_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${local.role_name}"
  audience = var.audience != "" ? var.audience : local.role_arn
}

data "aws_iam_policy_document" "trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = ["accounts.google.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "accounts.google.com:sub"
      values   = [var.google_service_account_unique_id]
    }
    condition {
      test     = "StringEquals"
      variable = "accounts.google.com:aud"
      values   = [var.google_service_account_unique_id]
    }
    condition {
      test     = "StringEquals"
      variable = "accounts.google.com:oaud"
      values   = [local.audience]
    }
  }
}

resource "aws_iam_role" "cloudrun_upload" {
  name                 = local.role_name
  description          = "EC2 -> Cloud Run PoC: Cloud Run service account (Google OIDC) uploads JSON to S3"
  assume_role_policy   = data.aws_iam_policy_document.trust.json
  max_session_duration = var.max_session_duration
}

data "aws_iam_policy_document" "upload" {
  statement {
    effect    = "Allow"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.upload.arn}/${var.key_prefix}*"]
  }
}

resource "aws_iam_role_policy" "upload" {
  name   = "s3-put-object"
  role   = aws_iam_role.cloudrun_upload.id
  policy = data.aws_iam_policy_document.upload.json
}
