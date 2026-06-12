# ------------------------------------------------------------------------------
# Native Filestore Restore
# ------------------------------------------------------------------------------
# Uses the native google_filestore_instance resource with the
# source_backupdr_backup argument in file_shares to trigger a restore.

data "external" "latest_filestore_backup" {
  count = var.perform_dr_test && var.provision_filestore ? 1 : 0

  program = ["bash", "${path.module}/scripts/get_latest_backup.sh"]

  query = {
    project       = var.project_id
    location      = var.region
    instance_name = try(google_filestore_instance.fs_share[0].name, "fs-share-unknown")
    vault_id      = google_backup_dr_backup_vault.vault.backup_vault_id
    vault_project = var.project_id
  }
}

# Grant GCBDR Service Agent permission to create/manage Filestore in the DR Project
resource "google_project_iam_member" "vault_sa_dr_filestore_permissions" {
  count    = var.perform_dr_test && var.provision_filestore ? 1 : 0
  provider = google
  project  = var.dr_project_id
  role     = "roles/file.editor"
  member   = "serviceAccount:${google_backup_dr_backup_vault.vault.service_account}"
}

resource "google_filestore_instance" "restored_fs_share" {
  count    = (var.perform_dr_test && var.provision_filestore && try(one(data.external.latest_filestore_backup).result.backup_id, "dummy") != "dummy") ? 1 : 0
  provider = google-beta.dr

  name     = "restored-fs-share${var.restore_suffix}"
  location = "${var.dr_region}-a"
  tier     = "ZONAL"

  file_shares {
    capacity_gb = 1024 # Must match source capacity (1 TiB min for Zonal)
    name        = "vol1"

    # Native GCBDR Restore Argument
    source_backupdr_backup = data.external.latest_filestore_backup[0].result.full_backup_id
  }

  networks {
    network      = var.create_isolated_dr_vpc ? google_compute_network.isolated_dr_vpc[0].id : "projects/${var.host_project_id}/global/networks/${var.dr_vpc_name}"
    modes        = ["MODE_IPV4"]
    connect_mode = "PRIVATE_SERVICE_ACCESS"
  }

  depends_on = [
    time_sleep.wait_for_apis,
    google_project_iam_member.vault_sa_dr_filestore_permissions,
    google_service_networking_connection.dr_private_vpc_connection,
    terraform_data.phase_1_complete
  ]
}
