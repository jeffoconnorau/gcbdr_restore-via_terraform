# ------------------------------------------------------------------------------
# Project Layout
# ------------------------------------------------------------------------------
# Legacy (all optional vars empty):
#   project_id        workloads + standard vault/plans + KMS
#   gcbdr_project_id  CMEK vault for the Rocky VM
#   infra_prod        Rocky VM + its CMEK keys
#   host_project_id   existing Shared VPC (looked up)
#   dr_project_id     restore target / isolated DR VPC
#
# Centralised (recommended for new labs):
#   vault_project_id  = backup project  -> every vault, plan and auto-protection policy
#   kms_project_id    = KMS project     -> every key ring
#   create_shared_vpc = true            -> Shared VPC created in host_project_id
#
#   +-----------------+  BPA / auto-protection  +----------------------------+
#   | project_id      | ----------------------> | vault_project_id           |
#   | (workload VMs)  |   vault SA holds         | bv-*, bp-*, ap-policy-gold |
#   +--------+--------+   computeEngineOperator  +-------------+--------------+
#            | subnet_name                                     | restore
#   +--------v--------+                          +-------------v--------------+
#   | host_project_id |                          | dr_project_id              |
#   | Shared VPC      |                          | isolated-dr-vpc            |
#   +-----------------+                          +----------------------------+
#            kms_project_id: kr-* key rings (CMEK for disks + vault)
# ------------------------------------------------------------------------------

locals {
  vault_project   = var.vault_project_id != "" ? var.vault_project_id : var.project_id
  vault_is_remote = local.vault_project != var.project_id

  kms_project_source = var.kms_project_id != "" ? var.kms_project_id : var.project_id
  kms_project_gcbdr  = var.kms_project_id != "" ? var.kms_project_id : var.gcbdr_project_id
  kms_project_infra  = var.kms_project_id != "" ? var.kms_project_id : var.infra_prod_project_id

  # Only the Private Services Access peering for the DR VPC is needed by the
  # managed-database restores. Skipping it avoids constraints/compute.restrictVpcPeering
  # failures in locked-down orgs when only Compute Engine is tested.
  dr_psa_needed = var.create_isolated_dr_vpc && (var.provision_cloud_sql || var.provision_filestore || var.provision_alloydb)

  # APIs for the "other" projects (project_id / dr_project_id are handled in apis.tf).
  extra_project_services = var.enable_project_services ? {
    for pair in distinct(flatten([
      [for s in ["backupdr.googleapis.com", "compute.googleapis.com"] : "${var.gcbdr_project_id}|${s}"],
      [for s in ["backupdr.googleapis.com", "compute.googleapis.com"] : "${local.vault_project}|${s}"],
      [for s in ["compute.googleapis.com", "backupdr.googleapis.com", "cloudkms.googleapis.com"] : "${var.infra_prod_project_id}|${s}"],
      [for s in concat(["compute.googleapis.com", "dns.googleapis.com"], var.create_psa ? ["servicenetworking.googleapis.com"] : []) : "${var.host_project_id}|${s}"],
      var.kms_project_id != "" ? ["${var.kms_project_id}|cloudkms.googleapis.com"] : [],
      ])) : pair => {
      project = split("|", pair)[0]
      service = split("|", pair)[1]
    } if !contains([var.project_id, var.dr_project_id], split("|", pair)[0])
  } : {}
}

resource "google_project_service" "extra" {
  for_each           = local.extra_project_services
  provider           = google
  project            = each.value.project
  service            = each.value.service
  disable_on_destroy = false
}
