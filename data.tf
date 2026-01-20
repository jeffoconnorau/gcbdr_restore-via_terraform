data "google_compute_network" "shared_vpc" {
  name    = var.vpc_name
  project = var.host_project_id
}

data "google_compute_subnetwork" "subnet" {
  name    = var.subnet_name
  project = var.host_project_id
  region  = var.region
}
