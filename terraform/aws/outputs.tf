output "bucket_name" {
  description = "アップロード先の S3 バケット（terraform/gcp の s3_bucket に渡す）"
  value       = aws_s3_bucket.upload.bucket
}

output "role_arn" {
  description = "Cloud Run の SA が引き受ける IAM ロールの ARN（terraform/gcp の aws_role_arn に渡す）"
  value       = aws_iam_role.cloudrun_upload.arn
}

output "audience" {
  description = "ID トークンの audience（accounts.google.com:oaud）。既定ではロールの ARN と同じ"
  value       = local.audience
}

output "region" {
  description = "S3 のリージョン"
  value       = var.region
}
