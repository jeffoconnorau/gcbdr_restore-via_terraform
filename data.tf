# Existing Shared VPC lookups (skipped when create_shared_vpc = true; see network_shared_vpc.tf)
data "google_compute_network" "shared_vpc" {
  count   = var.create_shared_vpc ? 0 : 1
  name    = var.vpc_name
  project = var.host_project_id
}

data "google_compute_subnetwork" "subnet" {
  count   = var.create_shared_vpc ? 0 : 1
  name    = var.subnet_name
  project = var.host_project_id
  region  = var.region
}

data "google_project" "dr_project" {
  project_id = var.dr_project_id
}
