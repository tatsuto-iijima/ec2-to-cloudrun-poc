# 入力変数。bucket_name と google_service_account_unique_id は terraform.tfvars で渡す（terraform.tfvars.example を参照）。

variable "region" {
  description = "S3 のリージョン。現行アプリのバケットと同じ東京"
  type        = string
  default     = "ap-northeast-1"
}

variable "name_prefix" {
  description = "リソース名の接頭辞"
  type        = string
  default     = "poc"
}

variable "bucket_name" {
  description = "アップロード先の S3 バケット名（全世界で一意。例: ec2-to-cloudrun-poc-<任意の英数字>）"
  type        = string
}

variable "key_prefix" {
  description = "PutObject を許すオブジェクトキーの接頭辞（アプリの S3_KEY_PREFIX と合わせる）。空なら バケット直下すべて"
  type        = string
  default     = ""
}

variable "google_service_account_unique_id" {
  description = "Cloud Run 実行用サービスアカウントの一意 ID（terraform -chdir=terraform/gcp output -raw service_account_unique_id）。ID トークンの sub / azp と一致させる"
  type        = string

  validation {
    condition     = can(regex("^[0-9]{10,30}$", var.google_service_account_unique_id))
    error_message = "google_service_account_unique_id は数字だけの一意 ID を指定してください（メールアドレスではない）。"
  }
}

variable "audience" {
  description = "ID トークンの audience（AWS 側の accounts.google.com:oaud）。空なら IAM ロールの ARN を使う。アプリの AWS_WIF_AUDIENCE と一致させる"
  type        = string
  default     = ""
}

variable "max_session_duration" {
  description = "AssumeRoleWithWebIdentity で得る一時クレデンシャルの最長有効期間（秒）。アプリの AWS_ROLE_DURATION_SECONDS はこれ以下にする"
  type        = number
  default     = 3600
}
