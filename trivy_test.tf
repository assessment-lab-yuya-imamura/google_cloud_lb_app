# 検証用のあえてセキュアではないコード
resource "google_compute_instance_template" "test_vuln_template" {
  name         = "trivy-test-vm-template"
  machine_type = "e2-micro"
  project      = "dummy-project-id"

  disk {
    source_image = "debian-cloud/debian-12"
    auto_delete  = true
    boot         = true
  }

  network_interface {
    network = "default"
    # ⚠️ access_config の中身が空 ➜ パブリックIPが自動付与されるため Trivy で HIGH 判定になります
    access_config {}
  }

  service_account {
    # ⚠️ "cloud-platform" スコープは全権限を許可するため、Trivy で HIGH/CRITICAL 判定になります
    scopes = ["cloud-platform"]
  }
}
