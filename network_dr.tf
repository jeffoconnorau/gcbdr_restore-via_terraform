# ------------------------------------------------------------------------------
# Isolated DR Network Infrastructure
# ------------------------------------------------------------------------------
# Created only if var.create_isolated_dr_vpc is true.

resource "google_compute_network" "isolated_dr_vpc" {
  provider                = google-beta
  project                 = var.dr_project_id
  name                    = "isolated-dr-vpc"
  auto_create_subnetworks = false
  delete_default_routes_on_create = true # Ensure no access to 0.0.0.0/0
  count                   = var.create_isolated_dr_vpc ? 1 : 0
}

# ... (Subnet and Firewall resources remain)

# ------------------------------------------------------------------------------
# Cloud DNS Configuration (Isolated DR)
# ------------------------------------------------------------------------------

# DNS Policy to enable logging and ensure inbound forwarding if needed
resource "google_dns_policy" "dr_policy" {
  provider = google-beta
  project  = var.dr_project_id
  name     = "dr-isolated-policy"
  
  enable_inbound_forwarding = true
  enable_logging            = true

  networks {
    network_url = google_compute_network.isolated_dr_vpc[0].id
  }
  
  count = var.create_isolated_dr_vpc ? 1 : 0
  
  depends_on = [time_sleep.wait_for_apis]
}

# Private Zone for DR Verification
resource "google_dns_managed_zone" "dr_test_zone" {
  provider    = google-beta
  project     = var.dr_project_id
  name        = "dr-test-internal"
  dns_name    = "dr.test.internal."
  description = "Private zone for DR validation"
  visibility  = "private"

  private_visibility_config {
    networks {
      network_url = google_compute_network.isolated_dr_vpc[0].id
    }
  }

  count = var.create_isolated_dr_vpc ? 1 : 0
  
  depends_on = [time_sleep.wait_for_apis]
}

# Sample A Record for verification
resource "google_dns_record_set" "dr_test_record" {
  provider     = google-beta
  project      = var.dr_project_id
  name         = "verification.dr.test.internal."
  managed_zone = google_dns_managed_zone.dr_test_zone[0].name
  type         = "A"
  ttl          = 300
  rrdatas      = ["1.1.1.1"] # Dummy IP to verify resolution works
  
  count = var.create_isolated_dr_vpc ? 1 : 0
}

resource "google_compute_subnetwork" "isolated_dr_subnet" {
  provider                 = google-beta
  project                  = var.dr_project_id
  name                     = var.dr_isolated_subnet_name
  ip_cidr_range            = var.dr_isolated_vpc_cidr
  region                   = var.dr_region
  network                  = google_compute_network.isolated_dr_vpc[0].id
  private_ip_google_access = true # Enabled as requested
  count                    = var.create_isolated_dr_vpc ? 1 : 0
}

# Firewall Rule to allow internal communication within Isolated VPC
resource "google_compute_firewall" "allow_internal_isolated" {
  provider = google-beta
  project  = var.dr_project_id
  name     = "allow-internal-isolated"
  network  = google_compute_network.isolated_dr_vpc[0].name
  count    = var.create_isolated_dr_vpc ? 1 : 0

  allow {
    protocol = "tcp"
    ports    = ["0-65535"]
  }
  allow {
    protocol = "udp"
    ports    = ["0-65535"]
  }
  allow {
    protocol = "icmp"
  }

  source_ranges = [var.dr_isolated_vpc_cidr]
}

# Firewall Rule to allow SSH (for verification)
resource "google_compute_firewall" "allow_ssh_isolated" {
  provider = google-beta
  project  = var.dr_project_id
  name     = "allow-ssh-isolated"
  network  = google_compute_network.isolated_dr_vpc[0].name
  count    = var.create_isolated_dr_vpc ? 1 : 0

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = ["35.235.240.0/20"] # IAP Range
}
