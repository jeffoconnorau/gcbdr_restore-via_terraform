# ------------------------------------------------------------------------------
# Cloud SQL Restore (Workaround via gcloud)
# ------------------------------------------------------------------------------
# Native Terraform support for Cloud SQL restore is not available in provider 7.16.0.
# We use a null_resource to trigger the restore via gcloud CLI.

data "external" "latest_sql_backup" {
  count = var.perform_dr_test && var.provision_cloud_sql ? 1 : 0

  program = ["bash", "${path.module}/scripts/get_latest_backup.sh"]

  query = {
    project       = var.project_id
    location      = var.region
    instance_name = try(google_sql_database_instance.sql_pg[0].name, "sql-pg-unknown")
    vault_id      = "bv-${var.region}-01"
    vault_project = var.project_id
  }
}

resource "null_resource" "restore_sql_db" {
  count = var.perform_dr_test && var.provision_cloud_sql ? 1 : 0

  triggers = {
    # Trigger restore if the backup ID matches (ensures we restore if backup changes, or always? specific logic)
    # Using backup_id to trigger only when a new backup is selected
    backup_id = data.external.latest_sql_backup[0].result.full_backup_id
  }

  provisioner "local-exec" {
    command = <<EOT
      echo "Starting Cloud SQL Restore via gcloud class..."
      gcloud backup-dr restores create restore-sql-${random_id.restore_suffix.hex} \
        --project=${var.dr_project_id} \
        --location=${var.dr_region} \
        --backup="${data.external.latest_sql_backup[0].result.full_backup_id}" \
        --target-instance-id="sql-restored-${random_id.restore_suffix.hex}" \
        --network="projects/${var.host_project_id}/global/networks/${var.vpc_name}" \
        --quiet
    EOT
  }

  depends_on = [
    time_sleep.wait_for_apis
  ]
}
