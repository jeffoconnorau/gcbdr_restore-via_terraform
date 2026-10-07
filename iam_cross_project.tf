# ------------------------------------------------------------------------------
# Cross-Project Backup IAM
# ------------------------------------------------------------------------------
# When a backup vault lives in a different project from the workloads it
# protects, the vault's service agent needs operator roles on the WORKLOAD
# project to snapshot instances/disks:
#   roles/backupdr.computeEngineOperator  (instances)
#   roles/backupdr.diskOperator           (standalone disks)
# In the legacy single-project layout (vault_project_id = "") nothing is created.
# ------------------------------------------------------------------------------

locals {
  # Standard vault (bp-vms / bp-disk / bp-autoprotect-*) -> workload projects
  vault_sa_workload_projects = toset(distinct(concat(
    local.vault_is_remote ? [var.project_id] : [],
    tolist(local.ap_cross_project_scopes),
  )))

  # Cross-region vault (bp-vms-xr) -> project_id
  vault_xr_sa_workload_projects = local.xr_enabled && local.vault_is_remote ? toset([var.project_id]) : toset([])
}

resource "google_project_iam_member" "vault_sa_workload_compute_operator" {
  for_each = local.vault_sa_workload_projects
  provider = google
  project  = each.value
  role     = "roles/backupdr.computeEngineOperator"
  member   = "serviceAccount:${google_backup_dr_backup_vault.vault.service_account}"
}

resource "google_project_iam_member" "vault_sa_workload_disk_operator" {
  for_each = local.vault_sa_workload_projects
  provider = google
  project  = each.value
  role     = "roles/backupdr.diskOperator"
  member   = "serviceAccount:${google_backup_dr_backup_vault.vault.service_account}"
}

resource "google_project_iam_member" "vault_xr_sa_workload_compute_operator" {
  for_each = local.vault_xr_sa_workload_projects
  provider = google
  project  = each.value
  role     = "roles/backupdr.computeEngineOperator"
  member   = "serviceAccount:${google_backup_dr_backup_vault.vault_xr[0].service_account}"
}

# IAM is eventually consistent; give the grants time before BPAs are created.
resource "time_sleep" "wait_for_cross_project_iam" {
  create_duration = length(local.vault_sa_workload_projects) + length(local.vault_xr_sa_workload_projects) > 0 ? "60s" : "1s"

  depends_on = [
    google_project_iam_member.vault_sa_workload_compute_operator,
    google_project_iam_member.vault_sa_workload_disk_operator,
    google_project_iam_member.vault_xr_sa_workload_compute_operator,
    google_project_iam_member.vault_cmek_sa_disk_operator,
  ]
}
