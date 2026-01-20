terraform {
  required_version = ">= 1.5.0"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0" // Using latest 6.x for modern features
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = "7.16.0"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.9"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
}

provider "google" {
  project = var.project_id
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
  alias   = "gcbdr"
  project = var.gcbdr_project_id
  region  = var.region
}

provider "google-beta" {
  alias   = "infra_prod"
  project = var.infra_prod_project_id
  region  = var.region
}
