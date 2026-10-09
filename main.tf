variable "gcp_credentials" {
  type        = string
  sensitive   = true
  description = "GCP credential in JSON format"
}

variable "project_id" {
  type        = string
  description = "GCP project ID"
}

variable "region" {
  type        = string
  description = "GCP region"
}

variable "trusted_ssh_source_ranges" {
  type        = list(string)
  description = "List of trusted IP CIDR ranges allowed to SSH into instances (e.g., your public IP or Google Cloud IAP '35.235.240.0/20')"
  default     = ["35.235.240.0/20"]
}

provider "google" {
  project     = var.project_id
  region      = var.region
  credentials = var.gcp_credentials
}

# -----------------------------------------------------------------------------
# Least Privilege Service Account for VM
# (roles/editor や roles/owner 使わず最小限の権限のみ付与)
# -----------------------------------------------------------------------------
resource "google_service_account" "vm_sa" {
  project      = var.project_id
  account_id   = "tf-lb-sa"
  display_name = "Service Account for Load Balancer VM"
}

resource "google_project_iam_member" "vm_sa_logging" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = google_service_account.vm_sa.member
}

resource "google_project_iam_member" "vm_sa_monitoring" {
  project = var.project_id
  role    = "roles/monitoring.metricWriter"
  member  = google_service_account.vm_sa.member
}

resource "google_service_account_iam_member" "deployer_sa_user" {
  service_account_id = google_service_account.vm_sa.name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:terraform-cloud-deployer-for-g@${var.project_id}.iam.gserviceaccount.com"
}

resource "google_compute_network" "vpc_network" {
  project                 = var.project_id
  name                    = "vpc-network"
  auto_create_subnetworks = false
  /* network_firewall_policy_enforcement_order = "BEFORE_CLASSIC_FIREWALLa" */
}


resource "google_compute_subnetwork" "subnet_public" {
  name          = "public-subnet"
  ip_cidr_range = "10.0.1.0/24"
  region        = var.region
  network       = google_compute_network.vpc_network.id
  project       = var.project_id
}

resource "google_compute_subnetwork" "subnet_private" {
  name                     = "private-subnet"
  ip_cidr_range            = "10.0.2.0/24"
  region                   = var.region
  network                  = google_compute_network.vpc_network.id
  project                  = var.project_id
  purpose                  = "PRIVATE"
  private_ip_google_access = true
}

resource "google_compute_router" "nat_router" {
  name    = "nat-router"
  region  = var.region
  network = google_compute_network.vpc_network.id
  project = var.project_id
}

resource "google_compute_router_nat" "nat" {
  name                               = "nat"
  router                             = google_compute_router.nat_router.name
  region                             = google_compute_router.nat_router.region
  source_subnetwork_ip_ranges_to_nat = "LIST_OF_SUBNETWORKS"
  subnetwork {
    name                    = google_compute_subnetwork.subnet_private.id
    source_ip_ranges_to_nat = ["ALL_IP_RANGES"]
  }
  nat_ip_allocate_option = "AUTO_ONLY"
  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

resource "google_compute_instance_template" "vm_template" {
  name_prefix  = "vm-template-"
  machine_type = "e2-micro"
  project      = var.project_id

  disk {
    source_image = "debian-cloud/debian-12"
    auto_delete  = true
    boot         = true
  }

  network_interface {
    network    = google_compute_network.vpc_network.id
    subnetwork = google_compute_subnetwork.subnet_private.id
  }

  tags = ["allow-lb-traffic", "allow-ssh"]

  metadata = {
    startup-script = <<-EOF
        #!/bin/bash
        apt-get update
        apt-get install -y apache2
        echo "<h1>Hello from Secure GCP Compute Instance</h1>" > /var/www/html/index.html
        systemctl restart apache2
    EOF
  }

  service_account {
    email  = google_service_account.vm_sa.email
    scopes = ["cloud-platform"]
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "google_compute_region_instance_group_manager" "mig" {
  name               = "vm-mig-private"
  project            = var.project_id
  region             = var.region
  base_instance_name = "vm"
  target_size        = 1

  /* 権限の付与完了を待ってから VM を起動させる */
  depends_on = [google_service_account_iam_member.deployer_sa_user]

  version {
    instance_template = google_compute_instance_template.vm_template.id
  }

  named_port {
    name = "http"
    port = 80
  }

  lifecycle {
    create_before_destroy = true
  }
}

# -----------------------------------------------------------------------------
# Firewall Rules
# -----------------------------------------------------------------------------
# 1. Allow only SSH (22) from a trusted IP range (not 0.0.0.0/0)
resource "google_compute_firewall" "allow_ssh" {
  name        = "allow-ssh-from-trusted-ip"
  project     = var.project_id
  network     = google_compute_network.vpc_network.id
  description = "Allow SSH only from trusted IP ranges"

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = var.trusted_ssh_source_ranges
  target_tags   = ["allow-ssh"]
}

# 2. Allow only HTTP (80) from Load Balancer (Google Health Check & LB IP ranges)
resource "google_compute_firewall" "allow_lb_to_vm" {
  name        = "allow-http-from-load-balancer"
  project     = var.project_id
  network     = google_compute_network.vpc_network.id
  description = "Allow HTTP traffic and health checks from Google Cloud Load Balancer"

  allow {
    protocol = "tcp"
    ports    = ["80"]
  }

  source_ranges = [
    "130.211.0.0/22",
    "35.191.0.0/16"
  ]
  target_tags = ["allow-lb-traffic"]
}

# -----------------------------------------------------------------------------
# Global HTTPS Load Balancer
# -----------------------------------------------------------------------------
# ヘルスチェック (ポート 80)
resource "google_compute_health_check" "http_health_check" {
  name               = "http-health-check"
  project            = var.project_id
  timeout_sec        = 5
  check_interval_sec = 5

  http_health_check {
    port = 80
  }
}

# バックエンドサービス (マネージドインスタンスグループを参照)
resource "google_compute_backend_service" "backend_service" {
  name                  = "vm-backend-service"
  project               = var.project_id
  protocol              = "HTTP"
  port_name             = "http"
  load_balancing_scheme = "EXTERNAL"
  timeout_sec           = 30
  health_checks         = [google_compute_health_check.http_health_check.id]

  backend {
    group = google_compute_region_instance_group_manager.mig.instance_group
  }
}

# URL マップ
resource "google_compute_url_map" "url_map" {
  name            = "lb-url-map"
  project         = var.project_id
  default_service = google_compute_backend_service.backend_service.id
}

# 自己署名 SSL 証明書 (HTTPS 443 終端用)
resource "tls_private_key" "lb_key" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_self_signed_cert" "lb_cert" {
  private_key_pem = tls_private_key.lb_key.private_key_pem

  subject {
    common_name  = "example.com"
    organization = "Secure GCP Infra"
  }

  validity_period_hours = 8760

  allowed_uses = [
    "key_encipherment",
    "digital_signature",
    "server_auth",
  ]
}

resource "google_compute_ssl_certificate" "lb_ssl_cert" {
  name        = "lb-ssl-cert"
  project     = var.project_id
  private_key = tls_private_key.lb_key.private_key_pem
  certificate = tls_self_signed_cert.lb_cert.cert_pem
}

# ターゲット HTTPS プロキシ
resource "google_compute_target_https_proxy" "https_proxy" {
  name             = "lb-https-proxy"
  project          = var.project_id
  url_map          = google_compute_url_map.url_map.id
  ssl_certificates = [google_compute_ssl_certificate.lb_ssl_cert.id]
}

# ロードバランサ用グローバル外部 IP アドレス
resource "google_compute_global_address" "lb_ip" {
  name    = "lb-global-ip"
  project = var.project_id
}

# グローバル転送ルール: インターネットからは HTTPS (443) のみ受け付ける
resource "google_compute_global_forwarding_rule" "https_forwarding_rule" {
  name                  = "lb-https-forwarding-rule"
  project               = var.project_id
  ip_protocol           = "TCP"
  load_balancing_scheme = "EXTERNAL"
  port_range            = "443"
  target                = google_compute_target_https_proxy.https_proxy.id
  ip_address            = google_compute_global_address.lb_ip.id
}

# -----------------------------------------------------------------------------
# Outputs
# -----------------------------------------------------------------------------
output "load_balancer_ip" {
  value       = google_compute_global_address.lb_ip.address
  description = "The public IP address of the Global HTTPS Load Balancer"
}