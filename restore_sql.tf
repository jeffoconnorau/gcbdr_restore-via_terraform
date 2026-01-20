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

resource "google_sql_database_instance" "restored_sql_pg" {
  count            = var.perform_dr_test && var.provision_cloud_sql ? 1 : 0
  provider         = google-beta.dr
  name             = "restored-sql-pg-${random_id.restore_suffix.hex}"
  region           = var.dr_region
  database_version = "POSTGRES_15" # Must match source or be compatible

  # Native GCBDR Restore Argument
  backupdr_backup = data.external.latest_sql_backup[0].result.full_backup_id

  settings {
    tier = "db-f1-micro"
    ip_configuration {
      ipv4_enabled    = false
      private_network = var.create_isolated_dr_vpc ? google_compute_network.isolated_dr_vpc[0].id : "projects/${var.host_project_id}/global/networks/${var.vpc_name}"
    }
  }

  deletion_protection = false

  depends_on = [
    time_sleep.wait_for_apis
  ]
}
