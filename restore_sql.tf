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
  # Clean Naming: Use source name + suffix (e.g. sql-pg-dr)
  # Note: Cloud SQL names cannot be reused for ~1 week after deletion.
  # If collisions occur, consider adding a short random suffix.
  name             = "restored-sql-pg${var.restore_suffix}" 
  region           = var.region # Same-Region Restore to avoid Cross-Region limitations
  database_version = "POSTGRES_15"

  # Native GCBDR Restore Argument
  backupdr_backup = data.external.latest_sql_backup[0].result.full_backup_id

  settings {
    tier = "db-custom-2-3840" # Upgraded for faster restore (f1-micro is too slow for restores)
    ip_configuration {
      ipv4_enabled    = false
      # For Same-Region Restore, we use the Shared VPC (Host Project) where the Vault has access
      private_network = "projects/${var.host_project_id}/global/networks/${var.vpc_name}"
    }
  }

  deletion_protection = false

  depends_on = [
    time_sleep.wait_for_apis,
    google_service_networking_connection.dr_private_vpc_connection # Ensure PSA peering is established
  ]
}

# ------------------------------------------------------------------------------
# MySQL Restore Configuration
# ------------------------------------------------------------------------------

data "external" "latest_mysql_backup" {
  count = var.perform_dr_test && var.provision_cloud_sql ? 1 : 0

  program = ["bash", "${path.module}/scripts/get_latest_backup.sh"]

  query = {
    project       = var.project_id
    location      = var.region
    instance_name = try(google_sql_database_instance.sql_mysql[0].name, "sql-mysql-unknown")
    vault_id      = "bv-${var.region}-01"
    vault_project = var.project_id
  }
}

resource "google_sql_database_instance" "restored_sql_mysql" {
  count            = var.perform_dr_test && var.provision_cloud_sql ? 1 : 0
  provider         = google-beta.dr
  
  # Clean Naming: Use source name + suffix
  name             = "restored-sql-mysql${var.restore_suffix}"
  region           = var.region # Same-Region Restore
  database_version = "MYSQL_8_0"

  # Native GCBDR Restore Argument
  backupdr_backup = data.external.latest_mysql_backup[0].result.full_backup_id

  settings {
    tier = "db-custom-2-3840" # Upgraded for faster restore (f1-micro is too slow for restores)
    ip_configuration {
      ipv4_enabled    = false
      # For Same-Region Restore, we use the Shared VPC (Host Project) where the Vault has access
      private_network = "projects/${var.host_project_id}/global/networks/${var.vpc_name}"
    }
  }

  deletion_protection = false

  depends_on = [
    time_sleep.wait_for_apis,
    google_service_networking_connection.dr_private_vpc_connection 
  ]
}
