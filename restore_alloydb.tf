# ------------------------------------------------------------------------------
# Native AlloyDB Restore
# ------------------------------------------------------------------------------
# Uses the native google_alloydb_cluster resource with the
# restore_backupdr_backup_source block to trigger a restore.

data "external" "latest_alloydb_backup" {
  count = var.perform_dr_test && var.provision_alloydb ? 1 : 0

  program = ["bash", "${path.module}/scripts/get_latest_backup.sh"]

  query = {
    project       = var.project_id
    location      = var.region
    instance_name = try(google_alloydb_cluster.alloydb_cluster[0].cluster_id, "alloydb-cluster-unknown")
    vault_id      = google_backup_dr_backup_vault.vault.backup_vault_id
    vault_project = var.project_id
  }
}

# Grant GCBDR Service Agent permission to manage AlloyDB in the DR Project
resource "google_project_iam_member" "vault_sa_dr_alloydb_permissions" {
  count    = var.perform_dr_test && var.provision_alloydb ? 1 : 0
  provider = google
  project  = var.dr_project_id
  role     = "roles/alloydb.admin"
  member   = "serviceAccount:${google_backup_dr_backup_vault.vault.service_account}"
}

# Restore the AlloyDB Cluster from GCBDR
resource "google_alloydb_cluster" "restored_alloydb_cluster" {
  count      = var.perform_dr_test && var.provision_alloydb ? 1 : 0
  provider   = google-beta.dr

  cluster_id = "restored-alloydb-cluster${var.restore_suffix}"
  location   = var.dr_region

  network_config {
    network = var.create_isolated_dr_vpc ? google_compute_network.isolated_dr_vpc[0].id : "projects/${var.host_project_id}/global/networks/${var.dr_vpc_name}"
  }

  # Native GCBDR Restore Block
  restore_backupdr_backup_source {
    backupdr_backup = data.external.latest_alloydb_backup[0].result.full_backup_id
  }

  deletion_protection = false

  depends_on = [
    time_sleep.wait_for_apis,
    google_project_iam_member.vault_sa_dr_alloydb_permissions,
    google_service_networking_connection.dr_private_vpc_connection
  ]
}

# Provision a Primary Instance in the restored cluster so it is queryable
resource "google_alloydb_instance" "restored_alloydb_instance" {
  count         = var.perform_dr_test && var.provision_alloydb ? 1 : 0
  provider      = google-beta.dr

  cluster       = google_alloydb_cluster.restored_alloydb_cluster[0].id
  instance_id   = "restored-alloydb-primary${var.restore_suffix}"
  instance_type = "PRIMARY"

  machine_config {
    cpu_count = 2
  }

  availability_type = "ZONAL"

  depends_on = [
    google_alloydb_cluster.restored_alloydb_cluster
  ]
}
