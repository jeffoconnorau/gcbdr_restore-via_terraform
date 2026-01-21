# ------------------------------------------------------------------------------
# Dynamic Restore Configuration
# ------------------------------------------------------------------------------

locals {
  # Map of VMs to restore -> Vault Name (Resource Name)
  vms_to_restore = {
    "vm-debian" = google_backup_dr_backup_vault.vault.backup_vault_id
    "vm-ubuntu" = google_backup_dr_backup_vault.vault.backup_vault_id
    # vm-rocky is handled separately for CMEK/Infra Prod restore
  }
}

# 1. Fetch Latest Backup ID (Dynamic) for EACH VM (Standard)
data "external" "latest_backup" {
  for_each = var.perform_dr_test ? local.vms_to_restore : {}

  program = ["bash", "${path.module}/scripts/get_latest_backup.sh"]

  query = {
    project       = var.project_id
    location      = var.region
    instance_name = each.key
    vault_id      = each.value
    vault_project = var.project_id
  }
}

# 2. Grant Permissions for Cross-Project Restore
# The Backup Vault Service Agent needs permissions in the Target Project
resource "google_project_iam_member" "vault_sa_target_permissions" {
  provider = google-beta
  project  = var.dr_project_id
  role     = "roles/compute.instanceAdmin.v1"
  member   = "serviceAccount:${google_backup_dr_backup_vault.vault.service_account}"
}

# 3. Execute Restore using Native Beta Resource for EACH VM (Standard)
resource "google_backup_dr_restore_workload" "restore_vms" {
  for_each = data.external.latest_backup

  provider = google-beta
  location = var.region # The location of the Backup Vault (Source Region)
  
  # Resource arguments (derived from external data source)
  backup_vault_id = each.value.result.backup_vault_id
  data_source_id  = each.value.result.data_source_id
  backup_id       = each.value.result.backup_id
  
  name = "restore-${each.key}-job-${random_id.restore_suffix.hex}" 

  compute_instance_target_environment {
    project = var.dr_project_id
    zone    = "${var.dr_region}-a" # Restoring to zone-a in the DR region
  }

  compute_instance_restore_properties {
    # Use original name plus optional suffix
    name = "${each.key}${var.restore_suffix}"
    
    # Target Machine Type (Requires full URL)
    machine_type = "projects/${var.dr_project_id}/zones/${var.dr_region}-a/machineTypes/e2-micro"
    
    labels {
      key   = "dr"
      value = "test"
    }

    # Target Network Interface (defines Target Project via subnetwork)
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
    google_project_iam_member.vault_sa_target_permissions,
    google_project_iam_member.vault_sa_host_network_permissions,
    time_sleep.wait_for_policy
  ]
  
  lifecycle {
    ignore_changes = [name] # Ignore name changes if we use random suffix
  }
}

# Grant Vault SA permission to use Shared VPC Subnets in Host Project
resource "google_project_iam_member" "vault_sa_host_network_permissions" {
  provider = google-beta
  project  = var.host_project_id
  role     = "roles/compute.networkUser"
  member   = "serviceAccount:${google_backup_dr_backup_vault.vault.service_account}"
}

# Grant CMEK Vault SA permission to use Shared VPC Subnets in Host Project (for Rocky Restore)
resource "google_project_iam_member" "vault_cmek_sa_host_network_permissions" {
  provider = google-beta
  project  = var.host_project_id
  role     = "roles/compute.networkUser"
  member   = "serviceAccount:${google_backup_dr_backup_vault.vault_cmek.service_account}"
}

# ------------------------------------------------------------------------------
# Organization Policy config: Disable Shielded VM Requirement for Restore
# ------------------------------------------------------------------------------
resource "google_project_organization_policy" "disable_shielded_vm_check" {
  provider   = google-beta
  project    = var.dr_project_id
  constraint = "constraints/compute.requireShieldedVm"

  boolean_policy {
    enforced = false
  }
}

# Wait for Org Policy change to propagate
resource "time_sleep" "wait_for_policy" {
  create_duration = "60s"
  depends_on      = [google_project_organization_policy.disable_shielded_vm_check]
}

resource "random_id" "restore_suffix" {
  byte_length = 4
}

# ------------------------------------------------------------------------------
# Workaround: Apply Labels Post-Restore
# The native resource's `labels` block might not propagate correctly in Beta.
# ------------------------------------------------------------------------------
resource "null_resource" "apply_labels" {
  for_each = var.perform_dr_test ? local.vms_to_restore : {}

  triggers = {
    # Force run on every apply to ensure labels are patched, as Provider often drops them
    always_run = timestamp()
  }

  provisioner "local-exec" {
    command = <<EOT
      gcloud compute instances add-labels "${each.key}${var.restore_suffix}" \
        --project=${var.dr_project_id} \
        --zone=${var.dr_region}-a \
        --labels=dr=test
    EOT
  }

  depends_on = [google_backup_dr_restore_workload.restore_vms]
}

# ------------------------------------------------------------------------------
# Disk Restore Configuration
# ------------------------------------------------------------------------------

# 4. Fetch Latest Disk Backup
data "external" "latest_disk_backup" {
  count = var.perform_dr_test ? 1 : 0

  program = ["bash", "${path.module}/scripts/get_latest_backup.sh"]

  query = {
    project       = var.project_id
    location      = var.region
    instance_name = "vm-debian-data-disk" # Name of the disk resource
    vault_id      = google_backup_dr_backup_vault.vault.backup_vault_id
    vault_project = var.project_id
  }
}

# 5. Restore Disk
# Note: Native resource usually supports restoring instances (compute.googleapis.com/Instance)
# We need to check if it supports Disk restore (compute.googleapis.com/Disk).
# Based on API docs, it does.
resource "google_backup_dr_restore_workload" "restore_disk" {
  count = var.perform_dr_test ? 1 : 0

  provider = google-beta
  location = var.region
  
  backup_vault_id = data.external.latest_disk_backup[0].result.backup_vault_id
  data_source_id  = data.external.latest_disk_backup[0].result.data_source_id
  backup_id       = data.external.latest_disk_backup[0].result.backup_id
  
  name = "restore-disk-${random_id.restore_suffix.hex}"

  disk_target_environment {
    project = var.dr_project_id
    zone    = "${var.dr_region}-a"
  }

  disk_restore_properties {
    name    = "vm-debian-data-disk${var.restore_suffix}"
    size_gb = 10
    type    = "projects/${var.dr_project_id}/zones/${var.dr_region}-a/diskTypes/${var.disk_type}"
  }
  
  lifecycle {
    ignore_changes = [name] 
  }
}

# 6. Attach Restored Disk to Restored VM
# We only do this for vm-debian as that's where the data disk belongs
resource "google_compute_attached_disk" "attach_restored_disk" {
  count = var.perform_dr_test ? 1 : 0

  disk     = google_backup_dr_restore_workload.restore_disk[0].target_resource[0].gcp_resource[0].gcp_resourcename
  instance = google_backup_dr_restore_workload.restore_vms["vm-debian"].target_resource[0].gcp_resource[0].gcp_resourcename
  
  # Ensure attachment happens in the DR project/zone
  project  = var.dr_project_id
  zone     = "${var.dr_region}-a"

  depends_on = [
    google_backup_dr_restore_workload.restore_vms,
    google_backup_dr_restore_workload.restore_disk
  ]
}

# ------------------------------------------------------------------------------
# Specialized Restore for Rocky VM (Infra Prod Target)
# ------------------------------------------------------------------------------

# Grant Permissions for Restore to Infra Prod
# The Backup Vault Service Agent needs permissions in the Infra Prod Project to restore
resource "google_project_iam_member" "vault_sa_infra_prod_permissions" {
  provider = google-beta.infra_prod
  project  = var.infra_prod_project_id
  role     = "roles/compute.instanceAdmin.v1"
  member   = "serviceAccount:${google_backup_dr_backup_vault.vault_cmek.service_account}"
}

# Fetch Latest Backup for Rocky VM
data "external" "latest_backup_rocky" {
  count = var.perform_dr_test ? 1 : 0

  program = ["bash", "${path.module}/scripts/get_latest_backup.sh"]

  query = {
    project       = var.infra_prod_project_id # Source Project for Rocky is now Infra Prod
    location      = var.region
    instance_name = "vm-rocky"
    vault_id      = google_backup_dr_backup_vault.vault_cmek.backup_vault_id
    vault_project = var.gcbdr_project_id
  }
}

# Restore Rocky VM to Infra Prod
resource "google_backup_dr_restore_workload" "restore_vm_rocky" {
  count = var.perform_dr_test ? 1 : 0

  provider = google-beta.gcbdr
  location = var.region
  
  backup_vault_id = data.external.latest_backup_rocky[0].result.backup_vault_id
  data_source_id  = data.external.latest_backup_rocky[0].result.data_source_id
  backup_id       = data.external.latest_backup_rocky[0].result.backup_id
  
  name = "restore-vm-rocky-job-${random_id.restore_suffix.hex}" 

  compute_instance_target_environment {
    project = var.infra_prod_project_id
    zone    = "${var.region}-c" # Reverting to Source Region (asia-southeast1)
  }

  compute_instance_restore_properties {
    name = "vm-rocky${var.restore_suffix}"
    
    # Target Machine Type (Source Region)
    machine_type = "projects/${var.infra_prod_project_id}/zones/${var.region}-c/machineTypes/e2-micro"
    
    labels {
      key   = "dr"
      value = "test"
    }

    advanced_machine_features {
      enable_uefi_networking = false
    }

    # Use Shared VPC with requested Singapore Subnet
    network_interfaces {
      network    = "projects/${var.host_project_id}/global/networks/${var.vpc_name}"
      subnetwork = "projects/${var.host_project_id}/regions/${var.region}/subnetworks/vpc-sub-sg-25"
    }

    shielded_instance_config {
      enable_secure_boot          = true
      enable_vtpm                 = true
      enable_integrity_monitoring = true
    }
  }

  depends_on = [
    google_project_iam_member.vault_sa_infra_prod_permissions,
    time_sleep.wait_for_policy
  ]
  
  lifecycle {
    ignore_changes = [name]
  }
}

# ------------------------------------------------------------------------------
# Encrypted Rocky Disk Restore Configuration
# ------------------------------------------------------------------------------

# 7. Fetch Latest Rocky Disk Backup
data "external" "latest_rocky_disk_backup" {
  count = var.perform_dr_test ? 1 : 0

  program = ["bash", "${path.module}/scripts/get_latest_backup.sh"]

  query = {
    project       = var.infra_prod_project_id # Source is now Infra Prod
    location      = var.region
    instance_name = "vm-rocky-data-disk"
    vault_id      = google_backup_dr_backup_vault.vault_cmek.backup_vault_id
    vault_project = var.gcbdr_project_id
  }
}

# 8. Restore Rocky Disk
resource "google_backup_dr_restore_workload" "restore_rocky_disk" {
  count = var.perform_dr_test ? 1 : 0

  provider = google-beta.gcbdr
  location = var.region

  backup_vault_id = data.external.latest_rocky_disk_backup[0].result.backup_vault_id
  data_source_id  = data.external.latest_rocky_disk_backup[0].result.data_source_id
  backup_id       = data.external.latest_rocky_disk_backup[0].result.backup_id

  name = "restore-rocky-disk-${random_id.restore_suffix.hex}"

  disk_target_environment {
    project = var.infra_prod_project_id # Target Infra Prod
    zone    = "${var.region}-c" # Source Region
  }

  disk_restore_properties {
    name    = "vm-rocky-data-disk${var.restore_suffix}"
    size_gb = 10
    type    = "projects/${var.infra_prod_project_id}/zones/${var.region}-c/diskTypes/${var.disk_type}"
    
    # Enforce CMEK using Source Key (In-Place Restore)
    disk_encryption_key {
       kms_key_name = google_kms_crypto_key.compute_key_infra.id
    }
  }

  depends_on = [
    time_sleep.wait_for_kms_iam_infra # Ensure IAM is ready
  ]

   lifecycle {
    ignore_changes = [name]
  }
}

# 9. Attach Restored Rocky Disk to Restored VM
resource "google_compute_attached_disk" "attach_restored_rocky_disk" {
  count = var.perform_dr_test ? 1 : 0
  
  provider = google-beta.infra_prod 

  disk     = google_backup_dr_restore_workload.restore_rocky_disk[0].target_resource[0].gcp_resource[0].gcp_resourcename
  instance = google_backup_dr_restore_workload.restore_vm_rocky[0].target_resource[0].gcp_resource[0].gcp_resourcename

  # Ensure attachment happens in the Target project/zone
  project  = var.infra_prod_project_id
  zone     = "${var.region}-c"

  depends_on = [
    google_backup_dr_restore_workload.restore_vm_rocky,
    google_backup_dr_restore_workload.restore_rocky_disk
  ]
}

# Workaround: Force-apply labels using gcloud since provider propagation is unreliable
resource "null_resource" "tag_restored_vm" {
  count = var.perform_dr_test ? 1 : 0
  
  triggers = {
    # Force run on every apply to ensure labels are patched
    always_run = timestamp()
  }

  provisioner "local-exec" {
    command = <<EOT
      gcloud compute instances add-labels vm-rocky${var.restore_suffix} \
        --project=${var.infra_prod_project_id} \
        --zone=${var.region}-c \
        --labels=dr=test
    EOT
  }

  depends_on = [google_backup_dr_restore_workload.restore_vm_rocky]
}
