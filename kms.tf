# ------------------------------------------------------------------------------
# Cloud KMS Resources for CMEK
# ------------------------------------------------------------------------------

# 1. Key Ring
resource "google_kms_key_ring" "key_ring" {
  name     = "kr-regional"
  location = var.region
  project  = var.project_id

  depends_on = [time_sleep.wait_for_apis]
}

# Random suffix to avoid KMS Key name collisions (Keys are soft-deleted)
resource "random_id" "kms_suffix" {
  byte_length = 4
  keepers = {
    # Regenerate only if the KeyRing changes, or force rotation if needed
    key_ring = google_kms_key_ring.key_ring.name
  }
}

# 2. Crypto Key
resource "google_kms_crypto_key" "compute_key" {
  name     = "k-compute-${random_id.kms_suffix.hex}"
  key_ring = google_kms_key_ring.key_ring.id
  purpose  = "ENCRYPT_DECRYPT"

  version_template {
    algorithm        = "GOOGLE_SYMMETRIC_ENCRYPTION"
    protection_level = "SOFTWARE"
  }

  lifecycle {
    prevent_destroy = false # For lab/testing purposes only
  }
}

# 3. IAM Permissions for Service Agents

# Fetch/Create Compute Engine Service Agent
resource "google_project_service_identity" "compute_sa" {
  provider = google-beta
  project  = var.project_id
  service  = "compute.googleapis.com"
}

data "google_project" "project" {}

# Grant Encrypter/Decrypter to Compute Engine Service Agent
resource "google_kms_crypto_key_iam_member" "compute_sa_encrypter" {
  crypto_key_id = google_kms_crypto_key.compute_key.id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  # Construct email manually to avoid 'null' error during plan if resource is creating
  member        = "serviceAccount:service-${data.google_project.project.number}@compute-system.iam.gserviceaccount.com"
}

# Fetch/Create Backup DR Service Agent (System Managed)
resource "google_project_service_identity" "backupdr_sa" {
  provider = google-beta
  project  = var.project_id
  service  = "backupdr.googleapis.com"
}

# Grant Encrypter/Decrypter to Backup DR Service Agent
resource "google_kms_crypto_key_iam_member" "backupdr_sa_encrypter" {
  crypto_key_id = google_kms_crypto_key.compute_key.id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:${google_project_service_identity.backupdr_sa.email}"
}

# Grant Encrypter/Decrypter to the REMOTE (GCBDR Project) Service Agent
# This is required for Cross-Project Backups so the Remote Service can read/snapshot the Source Disk
resource "google_kms_crypto_key_iam_member" "backupdr_sa_encrypter_remote" {
  crypto_key_id = google_kms_crypto_key.compute_key.id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:${google_project_service_identity.backupdr_sa_gcbdr.email}"
}

# 4. Wait for IAM Propagation
# KMS permissions (especially for Service Agents) take time to propagate.
resource "time_sleep" "wait_for_kms_iam" {
  create_duration = "120s"

  depends_on = [
    google_kms_crypto_key_iam_member.compute_sa_encrypter,
    google_kms_crypto_key_iam_member.backupdr_sa_encrypter,
    google_kms_crypto_key_iam_member.backupdr_sa_encrypter_remote
  ]
}
