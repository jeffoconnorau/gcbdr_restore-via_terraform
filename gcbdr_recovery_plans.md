# Google Cloud Backup and DR: Recovery Plans via Terraform

This guide provides a comprehensive framework, architectural patterns, and tested syntax examples for protecting and restoring Google Cloud resources using Google Cloud Backup and DR (GCBDR) and Terraform.

---

## 1. Architectural Blueprint & Lab Environment

The lab environment consists of two primary stages:
1.  **Backup & Protect**: Deploying the production workloads, configuring GCBDR Backup Vaults, defining Backup Plans, and establishing Backup Plan Associations.
2.  **Recovery & Restore**: Executing a Disaster Recovery (DR) plan by restoring these workloads from GCBDR backups into a target DR environment (e.g. an isolated VPC network).

### Resource Types Mapping

When creating Backup Plans (`google_backup_dr_backup_plan`) and Associations (`google_backup_dr_backup_plan_association`), use the correct resource types:

| Workload Type | GCBDR Resource Type (`resource_type`) | Restore Resource / Mechanism |
| :--- | :--- | :--- |
| **Compute Engine (VM)** | `compute.googleapis.com/Instance` | `google_backup_dr_restore_workload` |
| **Persistent Disk** | `compute.googleapis.com/Disk` | `google_backup_dr_restore_workload` |
| **Cloud SQL (Postgres / MySQL)** | `sqladmin.googleapis.com/Instance` | `google_sql_database_instance` via `backupdr_backup` |
| **Filestore** | `file.googleapis.com/Instance` | `google_filestore_instance` via `file_shares.source_backupdr_backup` |
| **AlloyDB** | `alloydb.googleapis.com/Cluster` | `google_alloydb_cluster` via `restore_backupdr_backup_source` |

---

## 2. Lab Environment: Workload Protection (Terraform Syntax)

The following configurations define how to provision and protect each workload in the Source project.

### 2.1. Compute Engine VMs and Disks
Standard VMs and disks are backed up using regional backup vaults.

```hcl
# Backup Plan for VMs
resource "google_backup_dr_backup_plan" "bp_vms" {
  location       = var.region
  backup_plan_id = "bp-vms-daily"
  resource_type  = "compute.googleapis.com/Instance"
  backup_vault   = google_backup_dr_backup_vault.vault.id

  backup_rules {
    rule_id              = "daily-backup"
    backup_retention_days = 3
    standard_schedule {
      recurrence_type = "DAILY"
      backup_window {
        start_hour_of_day = 12
        end_hour_of_day   = 24
      }
      time_zone = "UTC"
    }
  }
}

# Association
resource "google_backup_dr_backup_plan_association" "bpa_vm_debian" {
  location      = var.region
  resource_type = "compute.googleapis.com/Instance"
  resource      = google_compute_instance.vm_debian.id
  backup_plan   = google_backup_dr_backup_plan.bp_vms.id
  backup_plan_association_id = "bpa-vm-debian"
}
```

### 2.2. Cloud SQL
Cloud SQL instances are connected to Private Services Access (PSA) and backed up via standard GCBDR plans.

```hcl
# Backup Plan
resource "google_backup_dr_backup_plan" "bp_sql" {
  location       = var.region
  backup_plan_id = "bp-sql-daily"
  resource_type  = "sqladmin.googleapis.com/Instance"
  backup_vault   = google_backup_dr_backup_vault.vault.id

  backup_rules {
    rule_id              = "daily-backup"
    backup_retention_days = 3
    standard_schedule {
      recurrence_type = "DAILY"
      backup_window {
        start_hour_of_day = 13
        end_hour_of_day   = 24
      }
      time_zone = "UTC"
    }
  }
}

# Association
resource "google_backup_dr_backup_plan_association" "bpa_sql_pg" {
  location      = var.region
  resource_type = "sqladmin.googleapis.com/Instance"
  resource      = "projects/${var.project_id}/instances/${google_sql_database_instance.sql_pg.name}"
  backup_plan   = google_backup_dr_backup_plan.bp_sql.id
  backup_plan_association_id = "bpa-sql-pg"
}
```

### 2.3. Filestore
Filestore instances must be `ZONAL` or `ENTERPRISE` tier to be supported by GCBDR.

```hcl
# Backup Plan
resource "google_backup_dr_backup_plan" "bp_filestore" {
  location       = var.region
  backup_plan_id = "bp-filestore-daily"
  resource_type  = "file.googleapis.com/Instance"
  backup_vault   = google_backup_dr_backup_vault.vault.id

  backup_rules {
    rule_id              = "daily-backup"
    backup_retention_days = 3
    standard_schedule {
      recurrence_type = "DAILY"
      backup_window {
        start_hour_of_day = 12
        end_hour_of_day   = 24
      }
      time_zone = "UTC"
    }
  }
}

# Association
resource "google_backup_dr_backup_plan_association" "bpa_filestore" {
  location      = var.region
  resource_type = "file.googleapis.com/Instance"
  resource      = google_filestore_instance.fs_share.id
  backup_plan   = google_backup_dr_backup_plan.bp_filestore.id
  backup_plan_association_id = "bpa-filestore"
}
```

### 2.4. AlloyDB
AlloyDB clusters are protected at the cluster level.

```hcl
# Backup Plan
resource "google_backup_dr_backup_plan" "bp_alloydb" {
  location       = var.region
  backup_plan_id = "bp-alloydb-daily"
  resource_type  = "alloydb.googleapis.com/Cluster"
  backup_vault   = google_backup_dr_backup_vault.vault.id

  backup_rules {
    rule_id              = "daily-backup"
    backup_retention_days = 3
    standard_schedule {
      recurrence_type = "DAILY"
      backup_window {
        start_hour_of_day = 12
        end_hour_of_day   = 24
      }
      time_zone = "UTC"
    }
  }
}

# Association
resource "google_backup_dr_backup_plan_association" "bpa_alloydb" {
  location      = var.region
  resource_type = "alloydb.googleapis.com/Cluster"
  resource      = google_alloydb_cluster.alloydb_cluster.id
  backup_plan   = google_backup_dr_backup_plan.bp_alloydb.id
  backup_plan_association_id = "bpa-alloydb"
}
```

---

## 3. Restore Framework & Dynamic Backup Discovery

During a restore, Terraform requires the specific Backup ID to be passed to the restore property. To avoid hardcoding, we use a shell script bridge (`get_latest_backup.sh`) exposed as a Terraform `external` data source to discover the latest backup dynamically.

```hcl
data "external" "latest_backup" {
  program = ["bash", "${path.module}/scripts/get_latest_backup.sh"]

  query = {
    project       = var.project_id
    location      = var.region
    instance_name = "your-instance-name"
    vault_id      = google_backup_dr_backup_vault.vault.backup_vault_id
    vault_project = var.project_id
  }
}
```

---

## 4. Workload Restore: Terraform Syntax Examples

The following patterns detail how to restore each protected workload type during a DR execution.

### 4.1. Compute Engine VM Restore

Restored using `google_backup_dr_restore_workload` resource.

```hcl
resource "google_backup_dr_restore_workload" "restore_vm" {
  provider = google-beta
  location = var.region # Location of the Backup Vault

  # Decomposed ID segments fetched dynamically
  backup_vault_id = data.external.latest_backup.result.backup_vault_id
  data_source_id  = data.external.latest_backup.result.data_source_id
  backup_id       = data.external.latest_backup.result.backup_id

  compute_instance_target_environment {
    project = var.dr_project_id
    zone    = "${var.dr_region}-a"
  }

  compute_instance_restore_properties {
    name         = "vm-debian-restored"
    machine_type = "projects/${var.dr_project_id}/zones/${var.dr_region}-a/machineTypes/e2-micro"

    network_interfaces {
      network    = "projects/${var.dr_project_id}/global/networks/dr-vpc"
      subnetwork = "projects/${var.dr_project_id}/regions/${var.dr_region}/subnetworks/dr-subnet"
    }

    shielded_instance_config {
      enable_secure_boot          = true
      enable_vtpm                 = true
      enable_integrity_monitoring = true
    }
  }
}
```

### 4.2. Persistent Disk Restore

Restored using `google_backup_dr_restore_workload` and attached to the restored VM.

```hcl
resource "google_backup_dr_restore_workload" "restore_disk" {
  provider        = google-beta
  location        = var.region
  backup_vault_id = data.external.latest_disk_backup.result.backup_vault_id
  data_source_id  = data.external.latest_disk_backup.result.data_source_id
  backup_id       = data.external.latest_disk_backup.result.backup_id

  disk_target_environment {
    project = var.dr_project_id
    zone    = "${var.dr_region}-a"
  }

  disk_restore_properties {
    name    = "vm-debian-data-disk-restored"
    size_gb = 10
    type    = "projects/${var.dr_project_id}/zones/${var.dr_region}-a/diskTypes/pd-standard"
  }
}

# Attachment Resource
resource "google_compute_attached_disk" "attach_restored_disk" {
  project  = var.dr_project_id
  zone     = "${var.dr_region}-a"
  disk     = google_backup_dr_restore_workload.restore_disk.target_resource[0].gcp_resource[0].gcp_resourcename
  instance = google_backup_dr_restore_workload.restore_vm.target_resource[0].gcp_resource[0].gcp_resourcename
}
```

### 4.3. Cloud SQL Restore

Restored using standard `google_sql_database_instance` with the `backupdr_backup` parameter.

```hcl
resource "google_sql_database_instance" "restored_sql_pg" {
  provider         = google.dr
  name             = "restored-sql-pg"
  region           = var.dr_region
  database_version = "POSTGRES_15"

  # Native GCBDR Restore Argument
  backupdr_backup = data.external.latest_sql_backup.result.full_backup_id

  settings {
    tier              = "db-custom-2-3840" # Upgraded for faster recovery
    availability_type = "ZONAL"

    ip_configuration {
      ipv4_enabled    = false
      private_network = "projects/${var.dr_project_id}/global/networks/dr-vpc"
    }
  }
  deletion_protection = false
}
```

### 4.4. Filestore Restore

Restored using standard `google_filestore_instance` with the `source_backupdr_backup` parameter within the `file_shares` block.

```hcl
resource "google_filestore_instance" "restored_fs_share" {
  provider = google-beta.dr
  name     = "restored-fs-share"
  location = "${var.dr_region}-a"
  tier     = "ZONAL"

  file_shares {
    capacity_gb = 1024 # Must match source capacity (1 TiB min for Zonal)
    name        = "vol1"
    
    # Native GCBDR Restore Argument
    source_backupdr_backup = data.external.latest_filestore_backup.result.full_backup_id
  }

  networks {
    network      = "projects/${var.dr_project_id}/global/networks/dr-vpc"
    modes        = ["MODE_IPV4"]
    connect_mode = "PRIVATE_SERVICE_ACCESS"
  }
  
  deletion_protection = false
}
```

### 4.5. AlloyDB Restore

Restored using `terraform_data` with a `local-exec` provisioner executing `gcloud beta alloydb clusters restore`, as declarative HCL support is not yet available. A queryable primary instance must then be provisioned inside the restored cluster.

```hcl
# Restore cluster storage volume via local gcloud CLI
resource "terraform_data" "restored_alloydb_cluster" {
  triggers_replace = [
    data.external.latest_alloydb_backup[0].result.full_backup_id
  ]

  provisioner "local-exec" {
    command = <<-EOT
      gcloud beta alloydb clusters restore restored-alloydb-cluster \
        --project=$${var.dr_project_id} \
        --region=$${var.dr_region} \
        --backupdr-backup=$${data.external.latest_alloydb_backup[0].result.full_backup_id}
    EOT
  }
}

# Provision primary queryable instance inside the restored cluster
resource "google_alloydb_instance" "restored_alloydb_instance" {
  provider      = google-beta.dr
  cluster       = "projects/$${var.dr_project_id}/locations/$${var.dr_region}/clusters/restored-alloydb-cluster"
  instance_id   = "restored-alloydb-primary"
  instance_type = "PRIMARY"

  machine_config {
    cpu_count = 2
  }

  availability_type = "ZONAL"

  depends_on = [
    terraform_data.restored_alloydb_cluster
  ]
}
```

---

## 5. Security and IAM Configuration

Ensure the GCBDR Service Agent has appropriate permissions in the target/DR project to perform these operations:

| Workload Type | Required Service Agent Role in DR Project |
| :--- | :--- |
| **Compute Engine & Disks** | `roles/compute.instanceAdmin.v1` |
| **Cloud SQL** | `roles/cloudsql.admin` |
| **Filestore** | `roles/file.editor` |
| **AlloyDB** | `roles/alloydb.admin` |

Example IAM declaration:
```hcl
# For AlloyDB
resource "google_project_iam_member" "vault_sa_dr_alloydb_permissions" {
  project  = var.dr_project_id
  role     = "roles/alloydb.admin"
  member   = "serviceAccount:${google_backup_dr_backup_vault.vault.service_account}"
}

resource "google_project_iam_member" "vault_sa_dr_alloydb_operator" {
  project  = var.dr_project_id
  role     = "roles/backupdr.alloydbOperator"
  member   = "serviceAccount:${google_backup_dr_backup_vault.vault.service_account}"
}

resource "google_project_iam_member" "vault_sa_dr_sa_user" {
  project  = var.dr_project_id
  role     = "roles/iam.serviceAccountUser"
  member   = "serviceAccount:${google_backup_dr_backup_vault.vault.service_account}"
}

# Grant DR AlloyDB Service Agent permission to read backups from GCBDR Vault in Source Project
resource "google_project_iam_member" "dr_alloydb_sa_source_backupdr_permissions" {
  project  = var.project_id
  role     = "roles/backupdr.restoreUser"
  member   = "serviceAccount:service-${data.google_project.dr_project.number}@gcp-sa-alloydb.iam.gserviceaccount.com"
}
```
