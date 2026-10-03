# 1. 誰でも読み書き可能な危険な Cloud Storage バケット（CRITICAL）
resource "google_storage_bucket" "insecure_bucket" {
  name     = "trivy-insecure-test-bucket-example"
  location = "US"
  project  = "dummy-project"

  # 一般公開防止（Public Access Prevention）を無効化
  public_access_prevention = "inherited"
}

resource "google_storage_bucket_iam_member" "public_access" {
  bucket = google_storage_bucket.insecure_bucket.name
  role   = "roles/storage.objectAdmin"
  member = "allUsers" # ⚠️ インターネット上の誰でも管理者権限（CRITICAL）
}

# 2. 全ポートがインターネットにフルオープンなファイアウォール（HIGH）
resource "google_compute_firewall" "open_all" {
  name    = "open-everything-firewall"
  network = "default"
  project = "dummy-project"

  allow {
    protocol = "all" # ⚠️ 全プロトコル・全ポートを許可
  }

  source_ranges = ["0.0.0.0/0"] # ⚠️ 全世界（インターネット全体）から許可（HIGH）
}

# 3. 全権限が付与された危険な Service Account
resource "google_service_account" "test_sa" {
  account_id   = "trivy-test-sa"
  display_name = "Trivy Test Service Account"
}

resource "google_project_iam_member" "test_sa_full_privileges" {
  project = "dummy-project"
  role    = "roles/owner" # ⚠️ 全ての権限を付与
  member  = "serviceAccount:${google_service_account.test_sa.email}"
}
