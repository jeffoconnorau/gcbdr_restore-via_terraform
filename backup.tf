# ------------------------------------------------------------------------------
# Backup Vault
# ------------------------------------------------------------------------------

resource "google_backup_dr_backup_vault" "vault" {
  provider                            = google-beta
  location                            = var.region
  backup_vault_id                     = "bv-${var.region}-01"
  backup_minimum_enforced_retention_duration = "86400s" # 1 day

  depends_on = [time_sleep.wait_for_apis]
}

resource "google_backup_dr_backup_vault" "vault_cmek" {
  provider                            = google-beta.gcbdr
  project                             = var.gcbdr_project_id
  location                            = var.region
  backup_vault_id                     = "bv-cmek-${var.region}-remote-01"
  backup_minimum_enforced_retention_duration = "86400s" # 1 day

  encryption_config {
    kms_key_name = google_kms_crypto_key.vault_key_gcbdr.id
  }

  depends_on = [
    time_sleep.wait_for_kms_iam_gcbdr
  ]
}

# Wait for Remote Backup Vault
resource "time_sleep" "wait_for_vault_cmek" {
  depends_on = [google_backup_dr_backup_vault.vault_cmek]
  create_duration = "120s"
}

# Wait for Standard Vault (Source Project)
resource "time_sleep" "wait_for_vault" {
  depends_on = [google_backup_dr_backup_vault.vault]
  create_duration = "120s"
}

# ------------------------------------------------------------------------------
# Backup Plan for VMs
# ------------------------------------------------------------------------------

resource "google_backup_dr_backup_plan" "bp_vms" {
  provider       = google-beta
  location       = var.region
  backup_plan_id = "bp-vms-daily-3d-retention"
  resource_type  = "compute.googleapis.com/Instance"
  backup_vault   = google_backup_dr_backup_vault.vault.id

  # Explicit dependency on the wait timer to ensure Vault is ready
  depends_on = [time_sleep.wait_for_vault]

  backup_rules {
    rule_id              = "daily-backup"
    backup_retention_days = 3

    standard_schedule {
      recurrence_type   = "DAILY"
      backup_window {
        start_hour_of_day = 12
        end_hour_of_day   = 24
      }
      time_zone = "UTC"
    }
  }
}

# ------------------------------------------------------------------------------
# Backup Plan for CMEK Rocky VM (Remote Project)
# ------------------------------------------------------------------------------

resource "google_backup_dr_backup_plan" "bp_rocky_cmek" {
  provider       = google-beta.gcbdr
  project        = var.gcbdr_project_id
  location       = var.region
  backup_plan_id = "bp-rocky-cmek-daily-3d-remote"
  resource_type  = "compute.googleapis.com/Instance"
  backup_vault   = google_backup_dr_backup_vault.vault_cmek.id

  depends_on = [time_sleep.wait_for_vault_cmek]

  backup_rules {
    rule_id              = "daily-backup"
    backup_retention_days = 3

    standard_schedule {
      recurrence_type   = "DAILY"
      backup_window {
        start_hour_of_day = 12
        end_hour_of_day   = 24
      }
      time_zone = "UTC"
    }
  }
}

resource "google_backup_dr_backup_plan" "bp_rocky_disk_cmek" {
  provider       = google-beta.gcbdr
  project        = var.gcbdr_project_id
  location       = var.region
  backup_plan_id = "bp-rocky-disk-cmek-daily-3d-remote"
  resource_type  = "compute.googleapis.com/Disk"
  backup_vault   = google_backup_dr_backup_vault.vault_cmek.id

  depends_on = [time_sleep.wait_for_vault_cmek]

  backup_rules {
    rule_id              = "daily-backup"
    backup_retention_days = 3

    standard_schedule {
      recurrence_type   = "DAILY"
      backup_window {
        start_hour_of_day = 12
        end_hour_of_day   = 24
      }
      time_zone = "UTC"
    }
  }
}

# ------------------------------------------------------------------------------
# Backup Plan for Cloud SQL
# ------------------------------------------------------------------------------

resource "google_backup_dr_backup_plan" "bp_sql" {
  count          = var.provision_cloud_sql ? 1 : 0
  provider       = google-beta
  location       = var.region
  backup_plan_id = "bp-sql-daily-3d-retention"
  resource_type  = "sqladmin.googleapis.com/Instance"
  backup_vault   = google_backup_dr_backup_vault.vault.id

  # Explicit dependency on the wait timer
  depends_on = [time_sleep.wait_for_vault]

  backup_rules {
    rule_id              = "daily-backup"
    backup_retention_days = 3

    standard_schedule {
      recurrence_type   = "DAILY"
      backup_window {
        start_hour_of_day = 13
        end_hour_of_day   = 24
      }
      time_zone = "UTC"
    }
  }
}

# ------------------------------------------------------------------------------
# Wait for Resources (VMs/SQL) to be fully online
# ------------------------------------------------------------------------------
# Should depend on the resources in main.tf. Since we can't easily reference all of them in one block 
# without outputting them or being verbose, we will create a dependency chain in the association.
# Actually, let's create a time_sleep that depends on ALL resources we care about.

resource "time_sleep" "wait_for_resources" {
  create_duration = "60s"

  depends_on = [
    # VMs
    google_compute_instance.vm_debian,
    google_compute_instance.vm_ubuntu,
    google_compute_instance.vm_rocky,
    # SQL
    google_sql_database_instance.sql_pg,
    google_sql_database_instance.sql_mysql,
    # New Workloads
    google_alloydb_cluster.source_alloydb_cluster,
    google_alloydb_instance.source_alloydb_instance,
    google_filestore_instance.source_filestore
  ]
}

# ------------------------------------------------------------------------------
# Backup Plan Associations (VMs)
# ------------------------------------------------------------------------------

resource "google_backup_dr_backup_plan_association" "bpa_vm_debian" {
  provider      = google-beta
  location      = var.region
  resource_type = "compute.googleapis.com/Instance"
  resource      = google_compute_instance.vm_debian.id
  backup_plan   = google_backup_dr_backup_plan.bp_vms.id
  backup_plan_association_id = "bpa-vm-debian"

  depends_on = [time_sleep.wait_for_resources]
}

resource "google_backup_dr_backup_plan_association" "bpa_vm_ubuntu" {
  provider      = google-beta
  location      = var.region
  resource_type = "compute.googleapis.com/Instance"
  resource      = google_compute_instance.vm_ubuntu.id
  backup_plan   = google_backup_dr_backup_plan.bp_vms.id
  backup_plan_association_id = "bpa-vm-ubuntu"

  depends_on = [time_sleep.wait_for_resources]
}

resource "google_backup_dr_backup_plan_association" "bpa_vm_rocky" {
  provider      = google-beta.infra_prod
  location      = var.region
  resource_type = "compute.googleapis.com/Instance"
  resource      = google_compute_instance.vm_rocky.id
  backup_plan   = google_backup_dr_backup_plan.bp_rocky_cmek.id
  backup_plan_association_id = "bpa-vm-rocky-cmek"

  depends_on = [time_sleep.wait_for_vault_cmek]
}

resource "google_backup_dr_backup_plan_association" "bpa_disk_rocky" {
  provider      = google-beta.infra_prod
  location      = var.region
  resource_type = "compute.googleapis.com/Disk"
  resource      = google_compute_disk.rocky_data_disk.id
    # Note: Disk Plan is separate
  backup_plan   = google_backup_dr_backup_plan.bp_rocky_disk_cmek.id
  backup_plan_association_id = "bpa-disk-rocky-cmek"

  depends_on = [
    time_sleep.wait_for_vault_cmek,
    google_compute_attached_disk.attach_rocky_data
  ]
}



# ------------------------------------------------------------------------------
# Backup Plan Associations (Cloud SQL)
# ------------------------------------------------------------------------------

resource "google_backup_dr_backup_plan_association" "bpa_sql_pg" {
  count         = var.provision_cloud_sql ? 1 : 0
  provider      = google-beta
  location      = var.region
  resource_type = "sqladmin.googleapis.com/Instance"
  resource      = "projects/${var.project_id}/instances/${google_sql_database_instance.sql_pg[0].name}"
  backup_plan   = google_backup_dr_backup_plan.bp_sql[0].id
  backup_plan_association_id = "bpa-sql-pg"

  depends_on = [time_sleep.wait_for_resources]
}

resource "google_backup_dr_backup_plan_association" "bpa_sql_mysql" {
  count         = var.provision_cloud_sql ? 1 : 0
  provider      = google-beta
  location      = var.region
  resource_type = "sqladmin.googleapis.com/Instance"
  resource      = "projects/${var.project_id}/instances/${google_sql_database_instance.sql_mysql[0].name}"
  backup_plan   = google_backup_dr_backup_plan.bp_sql[0].id
  backup_plan_association_id = "bpa-sql-mysql"

  depends_on = [time_sleep.wait_for_resources]
}

# ------------------------------------------------------------------------------
# Backup Plan for Disks
# ------------------------------------------------------------------------------

resource "google_backup_dr_backup_plan" "bp_disk" {
  provider       = google-beta
  location       = var.region
  backup_plan_id = "bp-disk-daily-3d-retention"
  resource_type  = "compute.googleapis.com/Disk"
  backup_vault   = google_backup_dr_backup_vault.vault.id

  depends_on = [time_sleep.wait_for_vault]

  backup_rules {
    rule_id              = "daily-backup"
    backup_retention_days = 3

    standard_schedule {
      recurrence_type   = "DAILY"
      backup_window {
        start_hour_of_day = 12
        end_hour_of_day   = 24
      }
      time_zone = "UTC"
    }
  }
}

# ------------------------------------------------------------------------------
# Backup Plan Associations (Disks)
# ------------------------------------------------------------------------------

resource "google_backup_dr_backup_plan_association" "bpa_disk_debian" {
  provider      = google-beta
  location      = var.region
  resource_type = "compute.googleapis.com/Disk"
  resource      = google_compute_disk.debian_data_disk.id
  backup_plan   = google_backup_dr_backup_plan.bp_disk.id
  backup_plan_association_id = "bpa-disk-debian"

  depends_on = [
    time_sleep.wait_for_resources,
    google_compute_attached_disk.attach_min_debian
  ]
}

# ------------------------------------------------------------------------------
# Backup Plan for AlloyDB
# ------------------------------------------------------------------------------

resource "google_backup_dr_backup_plan" "bp_alloydb" {
  count          = var.provision_alloydb ? 1 : 0
  provider       = google-beta
  location       = var.region
  backup_plan_id = "bp-alloydb-daily-3d-retention"
  resource_type  = "alloydb.googleapis.com/Cluster"
  backup_vault   = google_backup_dr_backup_vault.vault.id

  depends_on = [time_sleep.wait_for_vault]

  backup_rules {
    rule_id              = "daily-backup"
    backup_retention_days = 3

    standard_schedule {
      recurrence_type   = "DAILY"
      backup_window {
        start_hour_of_day = 14
        end_hour_of_day   = 24
      }
      time_zone = "UTC"
    }
  }
}

resource "google_backup_dr_backup_plan_association" "bpa_alloydb" {
  count         = var.provision_alloydb ? 1 : 0
  provider      = google-beta
  location      = var.region
  resource_type = "alloydb.googleapis.com/Cluster"
  resource      = google_alloydb_cluster.source_alloydb_cluster[0].id
  backup_plan   = google_backup_dr_backup_plan.bp_alloydb[0].id
  backup_plan_association_id = "bpa-alloydb-cluster"

  depends_on = [time_sleep.wait_for_resources]
}

# ------------------------------------------------------------------------------
# Backup Plan for Filestore
# ------------------------------------------------------------------------------

resource "google_backup_dr_backup_plan" "bp_filestore" {
  count          = var.provision_filestore ? 1 : 0
  provider       = google-beta
  location       = var.region
  backup_plan_id = "bp-filestore-daily-3d-retention"
  resource_type  = "file.googleapis.com/Instance"
  backup_vault   = google_backup_dr_backup_vault.vault.id

  depends_on = [time_sleep.wait_for_vault]

  backup_rules {
    rule_id              = "daily-backup"
    backup_retention_days = 3

    standard_schedule {
      recurrence_type   = "DAILY"
      backup_window {
        start_hour_of_day = 15
        end_hour_of_day   = 24
      }
      time_zone = "UTC"
    }
  }
}

resource "google_backup_dr_backup_plan_association" "bpa_filestore" {
  count         = var.provision_filestore ? 1 : 0
  provider      = google-beta
  location      = "${var.region}-a" # Filestore Association must match instance location (Zonal)
  resource_type = "file.googleapis.com/Instance"
  resource      = google_filestore_instance.source_filestore[0].id
  backup_plan   = google_backup_dr_backup_plan.bp_filestore[0].id
  backup_plan_association_id = "bpa-filestore"

  depends_on = [time_sleep.wait_for_resources]
}
