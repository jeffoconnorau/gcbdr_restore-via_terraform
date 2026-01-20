# ------------------------------------------------------------------------------
# Cloud KMS Resources for GCBDR Project (for Backup Vault Encryption)
# ------------------------------------------------------------------------------

# 1. Key Ring in GCBDR Project
resource "google_kms_key_ring" "key_ring_gcbdr" {
  provider = google-beta.gcbdr
  name     = "kr-backup-vaults"
  location = var.region
  project  = var.gcbdr_project_id
}

# Random suffix for GCBDR Key
resource "random_id" "kms_suffix_gcbdr" {
  byte_length = 4
  keepers = {
    key_ring = google_kms_key_ring.key_ring_gcbdr.name
  }
}

# 2. Crypto Key in GCBDR Project
resource "google_kms_crypto_key" "vault_key_gcbdr" {
  provider = google-beta.gcbdr
  name     = "k-vault-${random_id.kms_suffix_gcbdr.hex}"
  key_ring = google_kms_key_ring.key_ring_gcbdr.id
  purpose  = "ENCRYPT_DECRYPT"

  version_template {
    algorithm        = "GOOGLE_SYMMETRIC_ENCRYPTION"
    protection_level = "SOFTWARE"
  }

  lifecycle {
    prevent_destroy = false
  }
}

# 3. IAM Permissions for GCBDR Service Agent

# Fetch Backup DR Service Agent for the GCBDR Project
resource "google_project_service_identity" "backupdr_sa_gcbdr" {
  provider = google-beta.gcbdr
  project  = var.gcbdr_project_id
  service  = "backupdr.googleapis.com"
}

# Grant Encrypter/Decrypter to the GCBDR Backup DR Service Agent on the GCBDR Key
resource "google_kms_crypto_key_iam_member" "backupdr_sa_encrypter_gcbdr" {
  provider      = google-beta.gcbdr
  crypto_key_id = google_kms_crypto_key.vault_key_gcbdr.id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:${google_project_service_identity.backupdr_sa_gcbdr.email}"
}

# 4. Wait for IAM Propagation
resource "time_sleep" "wait_for_kms_iam_gcbdr" {
  create_duration = "120s"

  depends_on = [
    google_kms_crypto_key_iam_member.backupdr_sa_encrypter_gcbdr,
    google_kms_crypto_key_iam_member.backupdr_sa_encrypter_source
  ]
}

# Grant Encrypter/Decrypter to the SOURCE Project's Service Agent on the DESTINATION Key
# This ensures the Source Service Agent can wrap/encrypt data into the Remote Vault
resource "google_kms_crypto_key_iam_member" "backupdr_sa_encrypter_source" {
  provider      = google-beta.gcbdr
  crypto_key_id = google_kms_crypto_key.vault_key_gcbdr.id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:${google_project_service_identity.backupdr_sa.email}"
}
