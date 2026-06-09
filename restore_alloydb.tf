# ------------------------------------------------------------------------------
# Native AlloyDB Restore
# ------------------------------------------------------------------------------
# Uses the native google_alloydb_cluster resource with the
# restore_backupdr_backup_source block to trigger a restore.

data "google_client_openid_userinfo" "caller" {}

locals {
  caller_is_sa = endswith(data.google_client_openid_userinfo.caller.email, ".gserviceaccount.com")
  caller_member = "${local.caller_is_sa ? "serviceAccount" : "user"}:${data.google_client_openid_userinfo.caller.email}"
}

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

resource "google_project_iam_member" "vault_sa_dr_alloydb_operator" {
  count    = var.perform_dr_test && var.provision_alloydb ? 1 : 0
  provider = google
  project  = var.dr_project_id
  role     = "roles/backupdr.alloydbOperator"
  member   = "serviceAccount:${google_backup_dr_backup_vault.vault.service_account}"
}

resource "google_project_iam_member" "vault_sa_dr_sa_user" {
  count    = var.perform_dr_test && var.provision_alloydb ? 1 : 0
  provider = google
  project  = var.dr_project_id
  role     = "roles/iam.serviceAccountUser"
  member   = "serviceAccount:${google_backup_dr_backup_vault.vault.service_account}"
}

# Grant DR AlloyDB Service Agent permission to read backups from GCBDR Vault in Source Project
resource "google_project_iam_member" "dr_alloydb_sa_source_backupdr_permissions" {
  count    = var.perform_dr_test && var.provision_alloydb ? 1 : 0
  provider = google
  project  = var.project_id
  role     = "roles/backupdr.restoreUser"
  member   = "serviceAccount:${google_project_service_identity.dr_alloydb_sa.email}"

  depends_on = [time_sleep.wait_for_apis]
}

# Grant DR Backup DR Service Agent permission to read backups from GCBDR Vault in Source Project
resource "google_project_iam_member" "dr_backupdr_sa_source_backupdr_permissions" {
  count    = var.perform_dr_test && var.provision_alloydb ? 1 : 0
  provider = google
  project  = var.project_id
  role     = "roles/backupdr.restoreUser"
  member   = "serviceAccount:${google_project_service_identity.dr_backupdr_sa.email}"

  depends_on = [time_sleep.wait_for_apis]
}

# Grant the caller permissions in the source project to access the GCBDR backup vault
resource "google_project_iam_member" "caller_source_backupdr_permissions" {
  count    = var.perform_dr_test && var.provision_alloydb ? 1 : 0
  provider = google
  project  = var.project_id
  role     = "roles/backupdr.restoreUser"
  member   = local.caller_member

  depends_on = [time_sleep.wait_for_apis]
}

# Grant DR AlloyDB Service Agent permission to manage/restore from Source Project
resource "google_project_iam_member" "dr_alloydb_sa_source_alloydb_admin" {
  count    = var.perform_dr_test && var.provision_alloydb ? 1 : 0
  provider = google
  project  = var.project_id
  role     = "roles/alloydb.admin"
  member   = "serviceAccount:${google_project_service_identity.dr_alloydb_sa.email}"

  depends_on = [time_sleep.wait_for_apis]
}

# Grant the caller permissions in the source project to restore AlloyDB resources across projects
resource "google_project_iam_member" "caller_source_alloydb_admin" {
  count    = var.perform_dr_test && var.provision_alloydb ? 1 : 0
  provider = google
  project  = var.project_id
  role     = "roles/alloydb.admin"
  member   = local.caller_member

  depends_on = [time_sleep.wait_for_apis]
}

# Restore the AlloyDB Cluster from GCBDR via local gcloud CLI in target project
resource "terraform_data" "restored_alloydb_cluster" {
  count = var.perform_dr_test && var.provision_alloydb ? 1 : 0

  input = {
    cluster_id = "restored-alloydb-cluster${var.restore_suffix}"
    project    = var.dr_project_id
    region     = var.region
  }

  triggers_replace = [
    data.external.latest_alloydb_backup[0].result.full_backup_id
  ]

  provisioner "local-exec" {
    command = <<-EOT
      if [ "${data.external.latest_alloydb_backup[0].result.backup_id}" != "dummy" ]; then
        gcloud beta alloydb clusters restore ${self.output.cluster_id} \
          --project=${self.output.project} \
          --region=${self.output.region} \
          --network="projects/${var.host_project_id}/global/networks/${var.dr_vpc_name}" \
          --backupdr-backup=${data.external.latest_alloydb_backup[0].result.full_backup_id}
      else
        echo "[WARNING] Backup ID is dummy, skipping gcloud restore."
      fi
    EOT
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      gcloud beta alloydb clusters delete ${self.output.cluster_id} \
        --project=${self.output.project} \
        --region=${self.output.region} \
        --force \
        --quiet 2>/dev/null || true
    EOT
  }

  depends_on = [
    time_sleep.wait_for_apis,
    google_project_iam_member.vault_sa_dr_alloydb_permissions,
    google_project_iam_member.vault_sa_dr_alloydb_operator,
    google_project_iam_member.vault_sa_dr_sa_user,
    google_project_iam_member.dr_alloydb_sa_source_backupdr_permissions,
    google_project_iam_member.dr_alloydb_sa_source_alloydb_admin,
    google_project_iam_member.dr_backupdr_sa_source_backupdr_permissions,
    google_project_iam_member.caller_source_backupdr_permissions,
    google_project_iam_member.caller_source_alloydb_admin,
    google_service_networking_connection.dr_private_vpc_connection
  ]
}

# Provision a Primary Instance in the restored cluster so it is queryable
resource "google_alloydb_instance" "restored_alloydb_instance" {
  count    = var.perform_dr_test && var.provision_alloydb ? 1 : 0
  provider = google-beta.dr_source_region

  cluster       = "projects/${var.dr_project_id}/locations/${var.region}/clusters/restored-alloydb-cluster${var.restore_suffix}"
  instance_id   = "restored-alloydb-primary${var.restore_suffix}"
  instance_type = "PRIMARY"

  machine_config {
    cpu_count = 2
  }

  availability_type = "ZONAL"

  depends_on = [
    terraform_data.restored_alloydb_cluster
  ]
}
