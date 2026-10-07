# Offline plan/apply tests using mock providers.
# Run: PATH="$PWD/tests/stub:$PATH" terraform test
# The gcloud stub prevents the auto-protection local-exec provisioners from calling real APIs.

mock_provider "google" {}
mock_provider "google" { alias = "dr" }
mock_provider "google" { alias = "gcbdr" }
mock_provider "google" { alias = "infra_prod" }
mock_provider "google" { alias = "vault" }
mock_provider "google-beta" {}
mock_provider "google-beta" { alias = "dr" }
mock_provider "google-beta" { alias = "dr_source_region" }
mock_provider "google-beta" { alias = "gcbdr" }
mock_provider "google-beta" { alias = "infra_prod" }
mock_provider "google-beta" { alias = "vault" }
mock_provider "external" {
  mock_data "external" {
    defaults = {
      result = { backup_id = "b1", backup_vault_id = "v1", data_source_id = "d1", location = "asia-southeast2", full_backup_id = "projects/p/locations/l/backupVaults/v1/dataSources/d1/backups/b1" }
    }
  }
}
mock_provider "time" {}
mock_provider "random" {}

variables {
  project_id             = "src"
  region                 = "asia-southeast1"
  host_project_id        = "host"
  vpc_name               = "vpc"
  subnet_name            = "sub"
  psa_range_prefix       = "10.200.0.0/16"
  dr_project_id          = "dr"
  dr_region              = "asia-southeast2"
  dr_vpc_name            = "vpc"
  dr_subnet_name         = "drsub"
  dr_isolated_vpc_cidr   = "10.70.24.0/24"
  gcbdr_project_id       = "gcbdr"
  infra_prod_project_id  = "infra"
  create_isolated_dr_vpc = true
}

run "defaults_unchanged" {
  command = plan
  variables { perform_dr_test = false }
  assert {
    condition     = length(terraform_data.auto_protection_policy) == 0 && length(google_backup_dr_backup_vault.vault_xr) == 0
    error_message = "new features must be opt-in"
  }
  assert {
    condition     = length(google_project_organization_policy.disable_shielded_vm_check) == 0
    error_message = "shielded override should default off"
  }
  assert {
    condition     = length(google_compute_network.shared_vpc) == 0 && length(data.google_compute_subnetwork.subnet) == 1
    error_message = "legacy layout must look up the existing Shared VPC"
  }
  assert {
    condition     = length(google_service_networking_connection.dr_private_vpc_connection) == 0
    error_message = "DR PSA must only be created for managed-database restores"
  }
  assert {
    condition     = google_backup_dr_backup_vault.vault.project == "src" && google_kms_key_ring.key_ring_gcbdr.project == "gcbdr"
    error_message = "legacy layout keeps vault in project_id and keys in their own projects"
  }
}

run "base_apply" {
  command = apply
  variables {
    perform_dr_test                     = false
    enable_auto_protection              = true
    enable_cross_region_backup          = true
    enable_guest_flush                  = true
    auto_protection_scope_projects      = ["src", "other"]
    max_custom_on_demand_retention_days = 30
  }
  assert {
    condition     = length(google_compute_instance.vm_autoprotect) == 2 && length(google_compute_instance.vm_autoprotect_negative) == 1
    error_message = "demo VMs"
  }
  assert {
    condition     = length(terraform_data.auto_protection_policy) == 2 && length(terraform_data.auto_protection_binding) == 4 && length(google_project_iam_member.vault_sa_workload_compute_operator) == 1
    error_message = "bindings / cross-project IAM"
  }
  assert {
    condition     = google_compute_instance.vm_autoprotect["vm-ap-1"].labels["backup-tier"] == "gold" && google_compute_instance.vm_autoprotect_negative[0].labels["backup-tier"] == "bronze"
    error_message = "labels"
  }
  assert {
    condition     = google_backup_dr_backup_vault.vault_xr[0].location == "asia-southeast2" && google_backup_dr_backup_plan.bp_vms_xr[0].location == "asia-southeast1" && google_backup_dr_backup_plan_association.bpa_vm_xr[0].location == "asia-southeast1"
    error_message = "cross-region locations"
  }
  assert {
    condition     = length(google_backup_dr_backup_plan.bp_vms[0].compute_instance_backup_plan_properties) == 1
    error_message = "guest flush"
  }
  assert {
    condition     = output.lab_context.auto_protection_positive == ["vm-ap-1", "vm-ap-2", "vm-ap-1-data-disk"]
    error_message = "lab_context output"
  }
}

run "dr_plan" {
  command = plan
  variables {
    perform_dr_test                = true
    enable_auto_protection         = true
    enable_cross_region_backup     = true
    enable_guest_flush             = true
    auto_protection_scope_projects = ["src", "other"]
  }
  assert {
    condition     = contains(keys(google_backup_dr_restore_workload.restore_vms), "vm-ap-1") && length(google_backup_dr_restore_workload.restore_vm_xr) == 1
    error_message = "restores"
  }
  assert {
    condition     = google_backup_dr_restore_workload.restore_vm_xr[0].location == "asia-southeast2"
    error_message = "xr restore reads from secondary-region vault"
  }
  assert {
    condition     = toset(keys(terraform_data.restored_vm_disk_autodelete)) == toset(["vm-debian", "vm-ubuntu", "vm-ap-1", "vm-ap-2", "vm-rocky", "vm-xr"])
    error_message = "every restored instance gets data-disk auto-delete"
  }
}

# 4-project centralised layout: backup project, KMS project, Terraform-built Shared VPC.
run "centralised_layout" {
  command = apply
  variables {
    perform_dr_test            = false
    project_id                 = "work"
    infra_prod_project_id      = "work"
    gcbdr_project_id           = "backup"
    vault_project_id           = "backup"
    kms_project_id             = "kms"
    host_project_id            = "host"
    create_shared_vpc          = true
    enable_auto_protection     = true
    enable_cross_region_backup = true
  }
  assert {
    condition = alltrue([
      google_backup_dr_backup_vault.vault.project == "backup",
      google_backup_dr_backup_vault.vault_xr[0].project == "backup",
      google_backup_dr_backup_plan.bp_vms[0].project == "backup",
      google_backup_dr_backup_plan.bp_autoprotect_vms[0].project == "backup",
      terraform_data.auto_protection_policy["vms"].output.project == "backup",
    ])
    error_message = "all vaults / plans / policy must live in the backup project"
  }
  assert {
    condition     = google_backup_dr_backup_plan_association.bpa_vm_debian[0].project != "backup"
    error_message = "BPAs stay with the workload"
  }
  assert {
    condition     = keys(google_project_iam_member.vault_sa_workload_compute_operator) == ["work"] && length(google_project_iam_member.vault_xr_sa_workload_compute_operator) == 1
    error_message = "vault service agents need operator roles on the workload project"
  }
  assert {
    condition = alltrue([
      google_kms_key_ring.key_ring.project == "kms",
      google_kms_key_ring.key_ring_gcbdr.project == "kms",
      google_kms_key_ring.key_ring_infra.project == "kms",
      google_kms_key_ring.key_ring_infra_dr.project == "kms",
    ])
    error_message = "all key rings in the KMS project"
  }
  assert {
    condition     = length(google_compute_network.shared_vpc) == 1 && length(data.google_compute_network.shared_vpc) == 0 && toset(keys(google_compute_shared_vpc_service_project.service)) == toset(["work", "dr"])
    error_message = "Shared VPC built in host with work + dr attached"
  }
  assert {
    condition     = contains(keys(google_project_service.extra), "kms|cloudkms.googleapis.com") && contains(keys(google_project_service.extra), "backup|backupdr.googleapis.com") && !contains(keys(google_project_service.extra), "work|compute.googleapis.com")
    error_message = "extra project APIs"
  }
  assert {
    condition     = output.lab_context.vault_project_id == "backup"
    error_message = "lab_context exposes vault project"
  }
}
