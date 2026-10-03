variable "gcp_credentials" {
    type = string
    sensitive = true
    description = "GCP credential in JSON format"
}

variable "project_id"{
    type = string
    description = "GCP project ID"
}

variable "region"{
    type = string
    description = "GCP region"
}

provider "google" {
    project = var.project_id
    region = var.region
    credentials = var.gcp_credentials
}


resource "google_service_account" "vm_sa"{
    account_id = "tf-lb-sa"
    display_name = "Service account for load balancer demos"
}

resource "google_project_iam_member" "project" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = google_service_account.vm_sa.member
}

resource "google_compute_network" "vpc_network" {
  project                                   = var.project_id
  name                                      = "vpc-network"
  auto_create_subnetworks                   = false
  /* network_firewall_policy_enforcement_order = "BEFORE_CLASSIC_FIREWALLa" */
}


resource "google_compute_subnetwork" "subnet_public" {
  name        = "public-subnet"
  ip_cidr_range = "10.0.1.0/24"
  region      = var.region
  network     = google_compute_network.vpc_network.id
  project     = var.project_id
}

resource "google_compute_subnetwork" "subnet_private" {
  name        = "private-subnet"
  ip_cidr_range = "10.0.2.0/24"
  region      = var.region
  network     = google_compute_network.vpc_network.id
  project     = var.project_id
  purpose          = "PRIVATE"
  private_ip_google_access = true
  
}

resource "google_compute_instance_template" "vm_template" {
  name         = "vm-template"
  machine_type = "e2-micro"
  project      = var.project_id

  disk {
    source_image = "debian-cloud/debian-11"
    auto_delete  = true
    boot         = true
  }

  network_interface {
    network    = google_compute_network.vpc_network.id
    subnetwork = google_compute_subnetwork.subnet_public.id
    access_config {}
  }

  metadata = {
    startup-script = <<-EOF
        #!/bin/bash
        apt-get update
        apt-get install -y apache2
        echo "<h1>Hello, World!</h1>" > /var/www/html/index.html
    EOF
  }

  service_account {
    email  = google_service_account.vm_sa.email
    scopes = ["cloud-platform"]
  }
}