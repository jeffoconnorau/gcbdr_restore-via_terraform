# ------------------------------------------------------------------------------
# Enable Required APIs
# ------------------------------------------------------------------------------

resource "google_project_service" "backupdr" {
  provider = google-beta
  project  = var.project_id
  service  = "backupdr.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "compute" {
  provider = google-beta
  project  = var.project_id
  service  = "compute.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "servicenetworking" {
  provider = google-beta
  project  = var.project_id
  service  = "servicenetworking.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "sqladmin" {
  provider = google-beta
  project  = var.project_id
  service  = "sqladmin.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "dns" {
  provider           = google-beta
  project            = var.project_id
  service            = "dns.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "dr_dns" {
  provider           = google-beta
  project            = var.dr_project_id
  service            = "dns.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "kms" {
  provider           = google-beta
  project            = var.project_id
  service            = "cloudkms.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "dr_kms" {
  provider           = google-beta
  project            = var.dr_project_id
  service            = "cloudkms.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "dr_servicenetworking" {
  provider           = google-beta
  project            = var.dr_project_id
  service            = "servicenetworking.googleapis.com"
  disable_on_destroy = false
}

# ------------------------------------------------------------------------------
# Wait for APIs to be enabled
# ------------------------------------------------------------------------------

resource "time_sleep" "wait_for_apis" {
  create_duration = "180s"

  depends_on = [
    google_project_service.backupdr,
    google_project_service.compute,
    google_project_service.servicenetworking,
    google_project_service.sqladmin,
    google_project_service.dns,
    google_project_service.dr_dns,
    google_project_service.kms,
    google_project_service.dr_kms,
    google_project_service.dr_servicenetworking
  ]

  triggers = {
    backupdr_id          = google_project_service.backupdr.id
    compute_id           = google_project_service.compute.id
    servicenetworking_id = google_project_service.servicenetworking.id
    sqladmin_id          = google_project_service.sqladmin.id
    dns_id               = google_project_service.dns.id
    dr_dns_id            = google_project_service.dr_dns.id
    kms_id               = google_project_service.kms.id
    dr_kms_id            = google_project_service.dr_kms.id
  }
}

# ------------------------------------------------------------------------------
# Organization Policies (Source Project)
# ------------------------------------------------------------------------------

resource "google_project_organization_policy" "storage_policy_source" {
  provider   = google-beta
  project    = var.project_id
  constraint = "constraints/compute.storageResourceUseRestrictions"
  
  list_policy {
    allow {
      all = true
    }
  }
}
