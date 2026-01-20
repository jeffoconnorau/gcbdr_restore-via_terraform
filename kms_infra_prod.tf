# ------------------------------------------------------------------------------
# Cloud KMS Resources for Infra Prod Project (for VM Disk Encryption)
# ------------------------------------------------------------------------------

# 1. Key Ring in Infra Prod
resource "google_kms_key_ring" "key_ring_infra" {
  provider = google-beta.infra_prod
  name     = "kr-rocky-vm"
  location = var.region
  project  = var.infra_prod_project_id
}

# Random suffix for Key
resource "random_id" "kms_suffix_infra" {
  byte_length = 4
  keepers = {
    key_ring = google_kms_key_ring.key_ring_infra.name
  }
}

# 2. Crypto Key in Infra Prod
resource "google_kms_crypto_key" "compute_key_infra" {
  provider = google-beta.infra_prod
  name     = "k-rocky-${random_id.kms_suffix_infra.hex}"
  key_ring = google_kms_key_ring.key_ring_infra.id
  purpose  = "ENCRYPT_DECRYPT"

  version_template {
    algorithm        = "GOOGLE_SYMMETRIC_ENCRYPTION"
    protection_level = "SOFTWARE"
  }

  lifecycle {
    prevent_destroy = false
  }
}

# 3. IAM Permissions

# ------------------------------------------------------------------------------
# DR Region KMS Resources (asia-southeast2)
# ------------------------------------------------------------------------------

# 1. DR Key Ring
resource "google_kms_key_ring" "key_ring_infra_dr" {
  provider = google-beta.infra_prod
  name     = "kr-rocky-vm-dr"
  location = var.dr_region
  project  = var.infra_prod_project_id
}

# 2. DR Crypto Key
resource "google_kms_crypto_key" "compute_key_infra_dr" {
  provider = google-beta.infra_prod
  name     = "k-rocky-dr-${random_id.kms_suffix_infra.hex}"
  key_ring = google_kms_key_ring.key_ring_infra_dr.id
  purpose  = "ENCRYPT_DECRYPT"

  version_template {
    algorithm        = "GOOGLE_SYMMETRIC_ENCRYPTION"
    protection_level = "SOFTWARE"
  }

  lifecycle {
    prevent_destroy = false
  }
}

# Fetch Project Info for Number
data "google_project" "infra_prod_project" {
  provider = google-beta.infra_prod
}

# Fetch Compute Service Agent for Infra Prod Project
resource "google_project_service_identity" "compute_sa_infra" {
  provider = google-beta.infra_prod
  project  = var.infra_prod_project_id
  service  = "compute.googleapis.com"
}

# Grant Encrypter/Decrypter to Infra Prod Compute Service Agent (for Disk Encryption)
resource "google_kms_crypto_key_iam_member" "compute_sa_encrypter_infra" {
  provider      = google-beta.infra_prod
  crypto_key_id = google_kms_crypto_key.compute_key_infra.id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  # Construct email manually to avoid 'null' error during plan/apply
  member        = "serviceAccount:service-${data.google_project.infra_prod_project.number}@compute-system.iam.gserviceaccount.com"
}

# Grant Encrypter/Decrypter to the GCBDR Service Agent (Remote) so it can BACKUP this CMEK disk
resource "google_kms_crypto_key_iam_member" "backupdr_sa_encrypter_infra_cross" {
  provider      = google-beta.infra_prod
  crypto_key_id = google_kms_crypto_key.compute_key_infra.id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:${google_project_service_identity.backupdr_sa_gcbdr.email}"
}

# Grant Compute Operator to the Vault Service Account (Remote)
# This is required for the Vault Service Agent to access/snapshot VMs in this project
resource "google_project_iam_member" "vault_sa_compute_operator" {
  provider = google-beta.infra_prod
  project  = var.infra_prod_project_id
  role     = "roles/backupdr.computeEngineOperator"
  member   = "serviceAccount:${google_backup_dr_backup_vault.vault_cmek.service_account}"
}

# 4. Wait for IAM Propagation
resource "time_sleep" "wait_for_kms_iam_infra" {
  create_duration = "120s"

  depends_on = [
    google_kms_crypto_key_iam_member.compute_sa_encrypter_infra,
    google_kms_crypto_key_iam_member.backupdr_sa_encrypter_infra_cross,
    google_kms_crypto_key_iam_member.compute_sa_encrypter_infra_dr,
    google_kms_crypto_key_iam_member.backupdr_sa_encrypter_infra_dr_cross
  ]
}

# Grant Encrypter/Decrypter to Infra Prod Compute Service Agent for DR Key
resource "google_kms_crypto_key_iam_member" "compute_sa_encrypter_infra_dr" {
  provider      = google-beta.infra_prod
  crypto_key_id = google_kms_crypto_key.compute_key_infra_dr.id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  # Use same Compute SA
  member        = "serviceAccount:service-${data.google_project.infra_prod_project.number}@compute-system.iam.gserviceaccount.com"
}

# Grant Encrypter/Decrypter to the GCBDR Service Agent (Remote) for DR Key
resource "google_kms_crypto_key_iam_member" "backupdr_sa_encrypter_infra_dr_cross" {
  provider      = google-beta.infra_prod
  crypto_key_id = google_kms_crypto_key.compute_key_infra_dr.id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:${google_project_service_identity.backupdr_sa_gcbdr.email}"
}
