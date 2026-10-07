terraform {
  required_version = ">= 1.5.0"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 7.22"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = ">= 7.22.0"
    }

    time = {
      source  = "hashicorp/time"
      version = "~> 0.9"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
    external = {
      source  = "hashicorp/external"
      version = "~> 2.3"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

provider "google" {
  alias   = "dr"
  project = var.dr_project_id
  region  = var.dr_region
}

provider "google" {
  alias   = "gcbdr"
  project = var.gcbdr_project_id
  region  = var.region
}

provider "google" {
  alias   = "infra_prod"
  project = var.infra_prod_project_id
  region  = var.region
}

provider "google-beta" {
  project = var.project_id
  region  = var.region
}

provider "google-beta" {
  alias   = "dr"
  project = var.dr_project_id
  region  = var.dr_region
}

provider "google-beta" {
  alias   = "dr_source_region"
  project = var.dr_project_id
  region  = var.region
}

provider "google-beta" {
  alias   = "gcbdr"
  project = var.gcbdr_project_id
  region  = var.region
}

provider "google-beta" {
  alias   = "infra_prod"
  project = var.infra_prod_project_id
  region  = var.region
}

# Backup project (vault_project_id, falls back to project_id). Required because
# google_backup_dr_restore_workload has no `project` argument - it inherits the
# provider's project, which must be the project that owns the backup vault.
provider "google" {
  alias   = "vault"
  project = var.vault_project_id != "" ? var.vault_project_id : var.project_id
  region  = var.region
}

provider "google-beta" {
  alias   = "vault"
  project = var.vault_project_id != "" ? var.vault_project_id : var.project_id
  region  = var.region
}
