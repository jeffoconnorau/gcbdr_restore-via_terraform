# ------------------------------------------------------------------------------
# Compute Engine Instances (VMs)
# ------------------------------------------------------------------------------

resource "google_compute_instance" "vm_debian" {
  count        = var.provision_compute_vms ? 1 : 0
  name         = "vm-debian"
  machine_type = "e2-micro"
  zone         = "${var.region}-a"

  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-11"
    }
  }

  network_interface {
    subnetwork = data.google_compute_subnetwork.subnet.self_link
    # No public IP
  }

  shielded_instance_config {
    enable_secure_boot = true
  }

  lifecycle {
    ignore_changes = [attached_disk]
  }

  depends_on = [time_sleep.wait_for_apis]
}

resource "google_compute_disk" "debian_data_disk" {
  count = var.provision_compute_pd ? 1 : 0
  name  = "vm-debian-data-disk"
  type  = var.disk_type
  zone  = "${var.region}-a"
  size  = 10

  depends_on = [time_sleep.wait_for_apis]
}

resource "google_compute_attached_disk" "attach_min_debian" {
  count    = (var.provision_compute_vms && var.provision_compute_pd) ? 1 : 0
  disk     = google_compute_disk.debian_data_disk[0].id
  instance = google_compute_instance.vm_debian[0].id
}

resource "google_compute_instance" "vm_ubuntu" {
  count        = var.provision_compute_vms ? 1 : 0
  name         = "vm-ubuntu"
  machine_type = "e2-micro"
  zone         = "${var.region}-b"

  boot_disk {
    initialize_params {
      image = "ubuntu-os-cloud/ubuntu-2204-lts"
    }
  }

  network_interface {
    subnetwork = data.google_compute_subnetwork.subnet.self_link
  }

  shielded_instance_config {
    enable_secure_boot = true
  }

  depends_on = [time_sleep.wait_for_apis]
}

resource "google_compute_disk" "ubuntu_data_disk" {
  count = var.provision_compute_pd ? 1 : 0
  name  = "vm-ubuntu-data-disk"
  type  = var.disk_type
  zone  = "${var.region}-b"
  size  = 10

  depends_on = [time_sleep.wait_for_apis]
}

resource "google_compute_attached_disk" "attach_ubuntu_data" {
  count    = (var.provision_compute_vms && var.provision_compute_pd) ? 1 : 0
  disk     = google_compute_disk.ubuntu_data_disk[0].id
  instance = google_compute_instance.vm_ubuntu[0].id
}

resource "google_compute_instance" "vm_rocky" {
  count        = var.provision_compute_vms ? 1 : 0
  provider     = google.infra_prod
  name         = "vm-rocky"
  machine_type = "e2-micro"
  zone         = "${var.region}-c"

  boot_disk {
    initialize_params {
      image = "rocky-linux-cloud/rocky-linux-8"
    }
    kms_key_self_link = google_kms_crypto_key.compute_key_infra.id
  }

  network_interface {
    subnetwork = data.google_compute_subnetwork.subnet.self_link
  }

  shielded_instance_config {
    enable_secure_boot = true
  }

  depends_on = [
    time_sleep.wait_for_apis,
    time_sleep.wait_for_kms_iam_infra
  ]
}

# ------------------------------------------------------------------------------
# Encrypted Data Disk for Rocky (Infra Prod)
# ------------------------------------------------------------------------------

resource "google_compute_disk" "rocky_data_disk" {
  count    = var.provision_compute_pd ? 1 : 0
  provider = google.infra_prod
  name     = "vm-rocky-data-disk"
  type     = var.disk_type
  zone     = "${var.region}-c"
  size     = 10

  disk_encryption_key {
    kms_key_self_link = google_kms_crypto_key.compute_key_infra.id
  }

  depends_on = [
    time_sleep.wait_for_apis,
    time_sleep.wait_for_kms_iam_infra
  ]
}

resource "google_compute_attached_disk" "attach_rocky_data" {
  count    = (var.provision_compute_vms && var.provision_compute_pd) ? 1 : 0
  provider = google.infra_prod
  disk     = google_compute_disk.rocky_data_disk[0].id
  instance = google_compute_instance.vm_rocky[0].id
}

# ------------------------------------------------------------------------------
# Cloud SQL Instances
# ------------------------------------------------------------------------------

resource "google_sql_database_instance" "sql_pg" {
  count            = var.provision_cloud_sql ? 1 : 0
  name             = "sql-pg-${random_id.db_suffix.hex}"
  database_version = "POSTGRES_15"
  region           = var.region

  settings {
    tier = "db-custom-2-3840"
    ip_configuration {
      ipv4_enabled    = false
      private_network = data.google_compute_network.shared_vpc.self_link
    }
  }
  deletion_protection = false # For lab/testing environment

  depends_on = [time_sleep.wait_for_apis]
}

resource "google_sql_database_instance" "sql_mysql" {
  count            = var.provision_cloud_sql ? 1 : 0
  name             = "sql-mysql-${random_id.db_suffix.hex}"
  database_version = "MYSQL_8_0"
  region           = var.region

  settings {
    tier = "db-custom-2-3840"
    ip_configuration {
      ipv4_enabled    = false
      private_network = data.google_compute_network.shared_vpc.self_link
    }
  }
  deletion_protection = false # For lab/testing environment

  depends_on = [time_sleep.wait_for_apis]
}

resource "random_id" "db_suffix" {
  byte_length = 4
  depends_on  = [time_sleep.wait_for_apis]
}

# ------------------------------------------------------------------------------
# Filestore Instance (Zonal Tier required for GCBDR)
# ------------------------------------------------------------------------------

resource "google_filestore_instance" "fs_share" {
  count    = var.provision_filestore ? 1 : 0
  name     = "fs-share-${random_id.db_suffix.hex}"
  location = "${var.region}-a"
  tier     = "ZONAL"

  file_shares {
    capacity_gb = 1024 # 1 TiB is the minimum size for Zonal tier
    name        = "vol1"
  }

  networks {
    network      = data.google_compute_network.shared_vpc.id
    modes        = ["MODE_IPV4"]
    connect_mode = "PRIVATE_SERVICE_ACCESS"
  }

  depends_on = [
    time_sleep.wait_for_apis,
    google_service_networking_connection.private_vpc_connection
  ]
}

# ------------------------------------------------------------------------------
# AlloyDB Cluster & Primary Instance
# ------------------------------------------------------------------------------

resource "google_alloydb_cluster" "alloydb_cluster" {
  count      = var.provision_alloydb ? 1 : 0
  cluster_id = "alloydb-cluster-${random_id.db_suffix.hex}"
  location   = var.region

  network_config {
    network = data.google_compute_network.shared_vpc.id
  }

  # For testing/lab environment, disable deletion protection
  deletion_protection = false

  depends_on = [
    time_sleep.wait_for_apis,
    google_service_networking_connection.private_vpc_connection
  ]
}

resource "google_alloydb_instance" "alloydb_instance" {
  count         = var.provision_alloydb ? 1 : 0
  cluster       = google_alloydb_cluster.alloydb_cluster[0].id
  instance_id   = "alloydb-primary-${random_id.db_suffix.hex}"
  instance_type = "PRIMARY"

  machine_config {
    cpu_count = 2 # Minimum for AlloyDB primary instance
  }

  # For testing/lab environment, disable deletion protection
  availability_type = "ZONAL"

  depends_on = [
    time_sleep.wait_for_apis
  ]
}
