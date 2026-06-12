# ------------------------------------------------------------------------------
# GCBDR Multi-Phase Recovery Orchestration Checkpoints
# ------------------------------------------------------------------------------
# Implements strict deterministic sequential phasing across workloads:
#   Phase 1: Named critical workloads (AlloyDB Cluster & Instance)
#   Phase 2: Grouped by workload type (Cloud SQL & Filestore instances)
#   Phase 3: Deferred last workloads (Compute Engine VMs & Disks)

# Barrier 1: Phase 1 (Named Critical Workloads) Complete
resource "terraform_data" "phase_1_complete" {
  count = var.perform_dr_test ? 1 : 0

  depends_on = [
    terraform_data.restored_alloydb_cluster,
    google_alloydb_instance.restored_alloydb_instance
  ]
}

# Barrier 2: Phase 2 (Grouped Workload Types) Complete
resource "terraform_data" "phase_2_complete" {
  count = var.perform_dr_test ? 1 : 0

  depends_on = [
    terraform_data.phase_1_complete,
    google_sql_database_instance.restored_sql_pg,
    google_sql_database_instance.restored_sql_mysql,
    google_filestore_instance.restored_fs_share
  ]
}
