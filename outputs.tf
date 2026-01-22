# ------------------------------------------------------------------------------
# Outputs
# ------------------------------------------------------------------------------

output "project_id" {
  description = "The Source Project ID."
  value       = var.project_id
}

output "backup_vault_id" {
  description = "The ID of the created Backup Vault."
  value       = google_backup_dr_backup_vault.vault.id
}

output "vm_instances" {
  description = "Map of created VM instances."
  value = {
    debian = one(google_compute_instance.vm_debian[*].name)
    ubuntu = one(google_compute_instance.vm_ubuntu[*].name)
    rocky  = one(google_compute_instance.vm_rocky[*].name)
  }
}

output "cloud_sql_instances" {
  description = "Map of created Cloud SQL instances."
  value = {
    postgresql = one(google_sql_database_instance.sql_pg[*].name)
    mysql      = one(google_sql_database_instance.sql_mysql[*].name)
  }
}

output "backup_plans" {
  description = "Map of created Backup Plans."
  value = {
    vms = one(google_backup_dr_backup_plan.bp_vms[*].name)
    sql = one(google_backup_dr_backup_plan.bp_sql[*].name)
  }
}
