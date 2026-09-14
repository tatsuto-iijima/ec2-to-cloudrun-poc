# 入力変数。project_id と invoker_member は terraform.tfvars で渡す（terraform.tfvars.example を参照）。

variable "project_id" {
  description = "GCP プロジェクト ID"
  type        = string
}

variable "region" {
  description = "リージョン。S3 の ap-northeast-1 と同じ東京にする"
  type        = string
  default     = "asia-northeast1"
}

variable "name_prefix" {
  description = "リソース名の接頭辞"
  type        = string
  default     = "poc"
}

variable "image" {
  description = "Cloud Run にデプロイするイメージ（例: asia-northeast1-docker.pkg.dev/PROJECT/poc-app/app:abc1234）。空なら Cloud Run サービスを作らない（1 回目の apply 用）"
  type        = string
  default     = ""
}

variable "invoker_member" {
  description = "Cloud Run を呼び出せるメンバー（例: user:you@example.com）。空なら付与しない。allUsers は指定しない（非公開運用）"
  type        = string
  default     = ""
}

variable "s3_bucket" {
  description = "アップロード先の S3 バケット名（#6 で実バケットに置き換える）"
  type        = string
  default     = "poc-bucket"
}

variable "aws_region" {
  description = "S3 のリージョン"
  type        = string
  default     = "ap-northeast-1"
}

variable "write_mode" {
  description = "JSON の書き込み方式。lock（file_put_contents + LOCK_EX）または rename（一時ファイル + rename）"
  type        = string
  default     = "lock"

  validation {
    condition     = contains(["lock", "rename"], var.write_mode)
    error_message = "write_mode は lock か rename を指定してください。"
  }
}

variable "max_instances" {
  description = "Cloud Run の最大インスタンス数。一人で操作する前提のため 1（複数インスタンスに起因する gcsfuse のキャッシュ不整合を避ける）"
  type        = number
  default     = 1
}

variable "concurrency" {
  description = "1 インスタンスあたりの同時リクエスト数。二重送信対策として 1 にするかは #8 で決める"
  type        = number
  default     = 80
}

variable "request_timeout" {
  description = "リクエストタイムアウト（#8 で実測と比較する）"
  type        = string
  default     = "300s"
}

variable "cpu" {
  description = "コンテナの CPU"
  type        = string
  default     = "1"
}

variable "memory" {
  description = "コンテナのメモリ。/tmp はインメモリなので余裕を持たせる"
  type        = string
  default     = "512Mi"
}
