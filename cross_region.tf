# ------------------------------------------------------------------------------
# Cross-Region Backups (GA June 2026)
# ------------------------------------------------------------------------------
# Protects a source-region VM (vm-xr in var.region) into a backup vault that
# lives in a DIFFERENT region (default: var.dr_region). During a DR drill the
# restore reads from the secondary-region vault, so recovery does not depend on
# the source region's control plane or storage being available.
#
#   var.region (e.g. asia-southeast1)          xr_region (e.g. asia-southeast2)
#   +---------------------------+  backup     +-------------------------------+
#   | vm-xr                     | ----------> | bv-xr-<xr_region>             |
#   | bp-vms-xr + BPA           |             | (backup vault only)           |
#   |   location = var.region   |             +---------------+---------------+
#   +---------------------------+                             | restore
#                                                             v
#                                             dr_project_id / <dr_region>-a
#
# Notes:
#   * The backup plan AND the association live in the workload's region; only
#     the plan's backup_vault points at the remote-region vault (the API rejects
#     a BPA whose region differs from its plan's region).
#   * Supported for Compute Engine instances/disks, Filestore and AlloyDB
#     (Cloud SQL uses multi-region vaults instead).
#   * CMEK for a cross-region vault must come from the vault's region.
#   * Inter-region data transfer charges apply.
# ------------------------------------------------------------------------------

locals {
  xr_enabled = var.enable_cross_region_backup
  xr_region  = var.cross_region_vault_region != "" ? var.cross_region_vault_region : var.dr_region
}

resource "google_backup_dr_backup_vault" "vault_xr" {
  count                                      = local.xr_enabled ? 1 : 0
  provider                                   = google
  project                                    = local.vault_project
  location                                   = local.xr_region
  backup_vault_id                            = "bv-xr-${local.xr_region}-${random_id.vault_suffix.hex}"
  description                                = "Cross-region vault protecting ${var.region} workloads from ${local.xr_region}."
  backup_minimum_enforced_retention_duration = "86400s" # 1 day
  access_restriction                         = var.vault_access_restriction

  depends_on = [time_sleep.wait_for_apis]
}

resource "time_sleep" "wait_for_vault_xr" {
  count           = local.xr_enabled ? 1 : 0
  depends_on      = [google_backup_dr_backup_vault.vault_xr]
  create_duration = "120s"
}

resource "google_backup_dr_backup_plan" "bp_vms_xr" {
  count          = local.xr_enabled ? 1 : 0
  provider       = google
  project        = local.vault_project
  location       = var.region # Plan lives with the workload; its vault is in xr_region
  backup_plan_id = "bp-vms-xr-${local.xr_region}"
  description    = "Cross-region plan: ${var.region} instances -> ${local.xr_region} vault."
  resource_type  = "compute.googleapis.com/Instance"
  backup_vault   = google_backup_dr_backup_vault.vault_xr[0].id

  backup_rules {
    rule_id               = "hourly-backup"
    backup_retention_days = 3

    standard_schedule {
      recurrence_type  = "HOURLY"
      hourly_frequency = var.cross_region_hourly_frequency
      time_zone        = "UTC"
      backup_window {
        start_hour_of_day = 0
        end_hour_of_day   = 24
      }
    }
  }

  dynamic "compute_instance_backup_plan_properties" {
    for_each = var.enable_guest_flush ? [1] : []
    content {
      guest_flush = true
    }
  }

  depends_on = [time_sleep.wait_for_vault_xr]
}

# Demo workload in the SOURCE region
resource "google_compute_instance" "vm_xr" {
  count        = local.xr_enabled ? 1 : 0
  name         = "vm-xr"
  machine_type = "e2-micro"
  zone         = "${var.region}-b"

  labels = {
    lab = "cross-region"
  }

  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-12"
    }
  }

  network_interface {
    subnetwork = local.source_subnet_self_link
  }

  shielded_instance_config {
    enable_secure_boot          = true
    enable_vtpm                 = true
    enable_integrity_monitoring = true
  }

  depends_on = [time_sleep.wait_for_apis]
}

resource "google_backup_dr_backup_plan_association" "bpa_vm_xr" {
  count                      = local.xr_enabled ? 1 : 0
  provider                   = google
  location                   = var.region # Workload region
  resource_type              = "compute.googleapis.com/Instance"
  resource                   = google_compute_instance.vm_xr[0].id
  backup_plan                = google_backup_dr_backup_plan.bp_vms_xr[0].id # Same region as the BPA
  backup_plan_association_id = "bpa-vm-xr"

  depends_on = [time_sleep.wait_for_resources]
}

# ------------------------------------------------------------------------------
# Cross-Region Restore (reads from the secondary-region vault)
# ------------------------------------------------------------------------------

data "external" "latest_backup_xr" {
  count = var.perform_dr_test && local.xr_enabled ? 1 : 0

  program = ["bash", "${path.module}/scripts/get_latest_backup.sh"]

  query = {
    project       = var.project_id
    location      = local.xr_region # Vault region, not workload region
    instance_name = "vm-xr"
    vault_id      = google_backup_dr_backup_vault.vault_xr[0].backup_vault_id
    vault_project = local.vault_project
  }
}

resource "google_project_iam_member" "vault_xr_sa_target_permissions" {
  count    = local.xr_enabled ? 1 : 0
  provider = google
  project  = var.dr_project_id
  role     = "roles/compute.instanceAdmin.v1"
  member   = "serviceAccount:${google_backup_dr_backup_vault.vault_xr[0].service_account}"
}

resource "google_project_iam_member" "vault_xr_sa_host_network_permissions" {
  count    = local.xr_enabled ? 1 : 0
  provider = google
  project  = var.host_project_id
  role     = "roles/compute.networkUser"
  member   = "serviceAccount:${google_backup_dr_backup_vault.vault_xr[0].service_account}"
}

resource "google_backup_dr_restore_workload" "restore_vm_xr" {
  count = (var.perform_dr_test && local.xr_enabled && try(one(data.external.latest_backup_xr).result.backup_id, "dummy") != "dummy") ? 1 : 0

  provider = google-beta.vault # Vault project (vault_project_id)
  location = local.xr_region

  backup_vault_id = data.external.latest_backup_xr[0].result.backup_vault_id
  data_source_id  = data.external.latest_backup_xr[0].result.data_source_id
  backup_id       = data.external.latest_backup_xr[0].result.backup_id

  compute_instance_target_environment {
    project = var.dr_project_id
    zone    = "${var.dr_region}-a" # Restore target is always the DR region
  }

  compute_instance_restore_properties {
    name         = "vm-xr${var.restore_suffix}"
    machine_type = "projects/${var.dr_project_id}/zones/${var.dr_region}-a/machineTypes/e2-micro"

    disks {
      boot        = true
      auto_delete = true
    }

    labels {
      key   = "dr"
      value = "test"
    }

    labels {
      key   = "restore-source"
      value = "cross-region-vault"
    }

    advanced_machine_features {
      enable_uefi_networking = false
    }

    network_interfaces {
      network    = var.create_isolated_dr_vpc ? google_compute_network.isolated_dr_vpc[0].id : "projects/${var.host_project_id}/global/networks/${var.dr_vpc_name}"
      subnetwork = var.create_isolated_dr_vpc ? google_compute_subnetwork.isolated_dr_subnet[0].id : "projects/${var.host_project_id}/regions/${var.dr_region}/subnetworks/${var.dr_subnet_name}"
    }

    shielded_instance_config {
      enable_secure_boot          = true
      enable_vtpm                 = true
      enable_integrity_monitoring = true
    }
  }

  depends_on = [
    google_project_iam_member.vault_xr_sa_target_permissions,
    google_project_iam_member.vault_xr_sa_host_network_permissions,
    time_sleep.wait_for_policy
  ]
}
