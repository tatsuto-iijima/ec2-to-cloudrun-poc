# アップロード先の S3 バケット（現行アプリの配布先に相当）。
# PoC 用なので force_destroy = true（terraform destroy で中身ごと消す）。
resource "aws_s3_bucket" "upload" {
  bucket        = var.bucket_name
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "upload" {
  bucket = aws_s3_bucket.upload.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
