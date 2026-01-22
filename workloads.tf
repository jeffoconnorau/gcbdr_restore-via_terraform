# ------------------------------------------------------------------------------
# AlloyDB Workload (Source Project)
# ------------------------------------------------------------------------------

resource "google_alloydb_cluster" "source_alloydb_cluster" {
  count    = var.provision_alloydb ? 1 : 0
  provider = google-beta
  
  cluster_id = "alloydb-cluster-source"
  location   = var.region
  project    = var.project_id

  network_config {
    network = data.google_compute_network.shared_vpc.id
  }

  initial_user {
    user     = "alloydb-admin"
    password = "ChangeMe123!" # In a real scenario, use Secret Manager
  }

  depends_on = [time_sleep.wait_for_apis]
}

resource "google_alloydb_instance" "source_alloydb_instance" {
  count    = var.provision_alloydb ? 1 : 0
  provider = google-beta

  cluster       = google_alloydb_cluster.source_alloydb_cluster[0].name
  instance_id   = "alloydb-instance-source"
  instance_type = "PRIMARY"

  # Minimum size for AlloyDB: 2 vCPU, 16 GB RAM
  machine_config {
    cpu_count = 2
  }

  depends_on = [google_alloydb_cluster.source_alloydb_cluster]
}

# ------------------------------------------------------------------------------
# Filestore Workload (Source Project)
# ------------------------------------------------------------------------------

resource "google_filestore_instance" "source_filestore" {
  count    = var.provision_filestore ? 1 : 0
  provider = google-beta

  name     = "filestore-source"
  location = "${var.region}-a" # Filestore (Basic) is Zonal
  tier     = "BASIC_HDD"
  project  = var.project_id

  file_shares {
    capacity_gb = 1024 # Minimum 1TB for Basic HDD
    name        = "share1"
  }

  networks {
    network = data.google_compute_network.shared_vpc.name
    modes   = ["MODE_IPV4"]
  }

  depends_on = [time_sleep.wait_for_apis]
}
