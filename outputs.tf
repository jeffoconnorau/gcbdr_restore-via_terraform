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

output "backup_vault_cmek_id" {
  description = "The ID of the CMEK Backup Vault in the GCBDR project."
  value       = google_backup_dr_backup_vault.vault_cmek.id
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
    vms              = one(google_backup_dr_backup_plan.bp_vms[*].name)
    rocky_cmek       = one(google_backup_dr_backup_plan.bp_rocky_cmek[*].name)
    disk             = one(google_backup_dr_backup_plan.bp_disk[*].name)
    rocky_disk_cmek  = one(google_backup_dr_backup_plan.bp_rocky_disk_cmek[*].name)
    sql              = one(google_backup_dr_backup_plan.bp_sql[*].name)
    filestore        = one(google_backup_dr_backup_plan.bp_filestore[*].name)
    alloydb          = one(google_backup_dr_backup_plan.bp_alloydb[*].name)
    autoprotect_vms  = one(google_backup_dr_backup_plan.bp_autoprotect_vms[*].name)
    autoprotect_disk = one(google_backup_dr_backup_plan.bp_autoprotect_disks[*].name)
    cross_region_vms = one(google_backup_dr_backup_plan.bp_vms_xr[*].name)
  }
}

output "auto_protection" {
  description = "Auto-protection policy details (null when disabled)."
  value = var.enable_auto_protection ? {
    policies        = [for p in local.ap_policies : "projects/${local.vault_project}/locations/${var.region}/autoProtectionPolicies/${p.policy_id}"]
    criteria        = "${var.auto_protection_label_key}=${var.auto_protection_label_value}"
    scope_projects  = local.ap_scope_projects
    expected_match  = concat(local.ap_demo_vm_names, google_compute_disk.disk_autoprotect[*].name)
    expected_ignore = google_compute_instance.vm_autoprotect_negative[*].name
    verify_command  = "./scripts/verify_auto_protection.sh"
  } : null
}

output "cross_region_backup" {
  description = "Cross-region backup details (null when disabled)."
  value = var.enable_cross_region_backup ? {
    vault         = google_backup_dr_backup_vault.vault_xr[0].id
    vault_region  = local.xr_region
    source_region = var.region
    protected_vm  = google_compute_instance.vm_xr[0].name
  } : null
}

# Machine-readable context consumed by the helper scripts and the DR report.
output "lab_context" {
  description = "Project/region context for scripts/*.sh and scripts/generate_report.py."
  value = {
    project_id                  = var.project_id
    dr_project_id               = var.dr_project_id
    gcbdr_project_id            = var.gcbdr_project_id
    infra_prod_project_id       = var.infra_prod_project_id
    vault_project_id            = local.vault_project
    host_project_id             = var.host_project_id
    kms_project_id              = var.kms_project_id != "" ? var.kms_project_id : null
    region                      = var.region
    dr_region                   = var.dr_region
    cross_region_vault_region   = var.enable_cross_region_backup ? local.xr_region : null
    auto_protection_enabled     = var.enable_auto_protection
    auto_protection_policy_id   = var.auto_protection_policy_id
    auto_protection_policy_ids  = [for p in local.ap_policies : p.policy_id]
    auto_protection_label_key   = var.auto_protection_label_key
    auto_protection_label_value = var.auto_protection_label_value
    auto_protection_scope       = local.ap_scope_projects
    auto_protection_positive    = concat(local.ap_demo_vm_names, google_compute_disk.disk_autoprotect[*].name)
    auto_protection_negative    = google_compute_instance.vm_autoprotect_negative[*].name
  }
}

output "recommended_parallelism" {
  description = "The parallelism level used for DR restores."
  value       = var.parallelism
}
