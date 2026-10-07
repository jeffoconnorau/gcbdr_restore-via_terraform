# ------------------------------------------------------------------------------
# Shared VPC (optional, lab-owned)
# ------------------------------------------------------------------------------
# create_shared_vpc = true  -> build the Shared VPC in host_project_id:
#   * <vpc_name> (custom mode)
#   * <subnet_name>    in var.region    (workload VMs, in-place Rocky restore)
#   * <dr_subnet_name> in var.dr_region (non-isolated DR restores)
#   * IAP SSH + intra-VPC firewall rules, Private Google Access, no external IPs
#   * host project enabled for XPN; project_id / infra_prod / dr attached
# create_shared_vpc = false -> look up the existing network/subnet (data.tf).
# ------------------------------------------------------------------------------

locals {
  shared_vpc_service_projects = var.create_shared_vpc ? toset([
    for p in distinct([var.project_id, var.infra_prod_project_id, var.dr_project_id]) : p if p != var.host_project_id
  ]) : toset([])

  shared_vpc_network_id        = var.create_shared_vpc ? google_compute_network.shared_vpc[0].id : data.google_compute_network.shared_vpc[0].id
  shared_vpc_network_self_link = var.create_shared_vpc ? google_compute_network.shared_vpc[0].self_link : data.google_compute_network.shared_vpc[0].self_link
  source_subnet_self_link      = var.create_shared_vpc ? google_compute_subnetwork.shared_vpc_source[0].self_link : data.google_compute_subnetwork.subnet[0].self_link
}

resource "google_compute_network" "shared_vpc" {
  count                   = var.create_shared_vpc ? 1 : 0
  provider                = google
  project                 = var.host_project_id
  name                    = var.vpc_name
  auto_create_subnetworks = false
  routing_mode            = "GLOBAL"

  depends_on = [google_project_service.extra]
}

resource "google_compute_subnetwork" "shared_vpc_source" {
  count                    = var.create_shared_vpc ? 1 : 0
  provider                 = google
  project                  = var.host_project_id
  name                     = var.subnet_name
  region                   = var.region
  network                  = google_compute_network.shared_vpc[0].id
  ip_cidr_range            = var.subnet_cidr
  private_ip_google_access = true

  log_config {
    aggregation_interval = "INTERVAL_5_MIN"
    flow_sampling        = 0.5
    metadata             = "INCLUDE_ALL_METADATA"
  }
}

resource "google_compute_subnetwork" "shared_vpc_dr" {
  count                    = var.create_shared_vpc ? 1 : 0
  provider                 = google
  project                  = var.host_project_id
  name                     = var.dr_subnet_name
  region                   = var.dr_region
  network                  = google_compute_network.shared_vpc[0].id
  ip_cidr_range            = var.dr_subnet_cidr
  private_ip_google_access = true
}

resource "google_compute_firewall" "shared_vpc_allow_iap_ssh" {
  count     = var.create_shared_vpc ? 1 : 0
  provider  = google
  project   = var.host_project_id
  name      = "${var.vpc_name}-allow-iap-ssh"
  network   = google_compute_network.shared_vpc[0].name
  direction = "INGRESS"

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = ["35.235.240.0/20"] # IAP TCP forwarding
}

resource "google_compute_firewall" "shared_vpc_allow_internal" {
  count     = var.create_shared_vpc ? 1 : 0
  provider  = google
  project   = var.host_project_id
  name      = "${var.vpc_name}-allow-internal"
  network   = google_compute_network.shared_vpc[0].name
  direction = "INGRESS"

  allow {
    protocol = "tcp"
  }
  allow {
    protocol = "udp"
  }
  allow {
    protocol = "icmp"
  }

  source_ranges = [var.subnet_cidr, var.dr_subnet_cidr]
}

resource "google_compute_shared_vpc_host_project" "host" {
  count    = var.create_shared_vpc ? 1 : 0
  provider = google
  project  = var.host_project_id

  depends_on = [google_project_service.extra]
}

resource "google_compute_shared_vpc_service_project" "service" {
  for_each        = local.shared_vpc_service_projects
  provider        = google
  host_project    = google_compute_shared_vpc_host_project.host[0].project
  service_project = each.value

  depends_on = [
    google_project_service.compute,
    google_project_service.dr_compute,
    google_project_service.extra,
  ]
}
