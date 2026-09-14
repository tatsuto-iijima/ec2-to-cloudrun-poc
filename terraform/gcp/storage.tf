# JSON マスタの作業領域（EC2 のローカルディスク相当）。Cloud Run に /mnt/data としてマウントする。
# PoC 用なので force_destroy = true（terraform destroy で中身ごと消す）。
resource "google_storage_bucket" "data" {
  name     = "${var.project_id}-${var.name_prefix}-data"
  location = var.region

  uniform_bucket_level_access = true
  force_destroy               = true
  public_access_prevention    = "enforced"

  depends_on = [google_project_service.services]
}
