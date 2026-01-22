# ------------------------------------------------------------------------------
# AlloyDB Restore Configuration
# ------------------------------------------------------------------------------

data "external" "latest_alloydb_backup" {
  count = var.perform_dr_test && var.provision_alloydb ? 1 : 0

  program = ["bash", "${path.module}/scripts/get_latest_backup.sh"]

  query = {
    project       = var.project_id
    location      = var.region
    instance_name = "alloydb-cluster-source" # Discovery by Cluster ID
    vault_id      = "bv-${var.region}-01"
    vault_project = var.project_id
  }
}

# Restore AlloyDB Cluster
resource "google_alloydb_cluster" "restored_alloydb_cluster" {
  count    = var.perform_dr_test && var.provision_alloydb ? 1 : 0
  provider = google-beta.dr

  cluster_id = "alloydb-cluster${var.restore_suffix}"
  location   = var.region
  
  # Native Restore Argument
  restore_backup_source {
    backup_name = data.external.latest_alloydb_backup[0].result.full_backup_id
  }

  network_config {
    network = "projects/${var.host_project_id}/global/networks/${var.vpc_name}"
  }
  
  initial_user {
    user     = "alloydb-admin"
    password = "ChangeMe123!" 
  }

  depends_on = [
    time_sleep.wait_for_apis,
    google_service_networking_connection.dr_private_vpc_connection
  ]
}

# Restore AlloyDB Instance (Attaches to Restored Cluster)
resource "google_alloydb_instance" "restored_alloydb_instance" {
  count    = var.perform_dr_test && var.provision_alloydb ? 1 : 0
  provider = google-beta.dr

  cluster       = google_alloydb_cluster.restored_alloydb_cluster[0].name
  instance_id   = "alloydb-instance${var.restore_suffix}"
  instance_type = "PRIMARY"

  machine_config {
    cpu_count = 2
  }
}

# ------------------------------------------------------------------------------
# Filestore Restore Configuration
# ------------------------------------------------------------------------------

data "external" "latest_filestore_backup" {
  count = var.perform_dr_test && var.provision_filestore ? 1 : 0

  program = ["bash", "${path.module}/scripts/get_latest_backup.sh"]

  query = {
    project       = var.project_id
    location      = "${var.region}-a" # Filestore lives in a Zone
    instance_name = "filestore-source"
    vault_id      = "bv-${var.region}-01"
    vault_project = var.project_id
  }
}

resource "google_filestore_instance" "restored_filestore" {
  count    = var.perform_dr_test && var.provision_filestore ? 1 : 0
  provider = google-beta.dr

  name     = "filestore${var.restore_suffix}"
  location = "${var.region}-a" # Restoring to same zone in source region usually safest for Basic
  tier     = "BASIC_HDD"
  
  file_shares {
    capacity_gb   = 1024
    name          = "share1"
    source_backup = data.external.latest_filestore_backup[0].result.full_backup_id
  }

  networks {
    network = "projects/${var.host_project_id}/global/networks/${var.vpc_name}"
    modes   = ["MODE_IPV4"]
  }

  depends_on = [
    time_sleep.wait_for_apis
  ]
}
