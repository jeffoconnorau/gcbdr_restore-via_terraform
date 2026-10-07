# ------------------------------------------------------------------------------
# Source / Production Environment
# ------------------------------------------------------------------------------

variable "project_id" {
  description = "The ID of the project in which to provision resources."
  type        = string
}

variable "region" {
  description = "The region to provision resources in."
  type        = string
}

variable "host_project_id" {
  description = "The ID of the shared VPC host project."
  type        = string
}

variable "vpc_name" {
  description = "The name of the shared VPC network."
  type        = string
}

variable "subnet_name" {
  description = "The name of the subnetwork to use for VMs and SQL."
  type        = string
}

# ------------------------------------------------------------------------------
# Private Services Access (PSA) Configuration
# ------------------------------------------------------------------------------

variable "create_psa" {
  description = "Whether to create the Private Services Access (PSA) connection in the host project."
  type        = bool
  default     = false
}

variable "provision_cloud_sql" {
  description = "Whether to provision Cloud SQL instances and their backup plans."
  type        = bool
  default     = false
}

variable "provision_compute_vms" {
  description = "Whether to provision Compute Engine VMs and their backup plans."
  type        = bool
  default     = true
}

variable "provision_compute_pd" {
  description = "Whether to provision Compute Engine persistent data disks and their backup plans."
  type        = bool
  default     = true
}

variable "psa_range_name" {
  description = "The name of the reserved IP range for PSA."
  type        = string
  default     = "google-managed-services-range"
}

variable "psa_range_prefix" {
  description = "The CIDR prefix for the PSA reserved range (e.g., 10.100.0.0/16)."
  type        = string
}

# ------------------------------------------------------------------------------
# DR / Target Environment
# ------------------------------------------------------------------------------

variable "dr_project_id" {
  description = "The ID of the DR/Target project."
  type        = string
}

variable "dr_region" {
  description = "The region for DR/Target resources."
  type        = string
}

variable "dr_vpc_name" {
  description = "The name of the DR/Target VPC network."
  type        = string
}

variable "dr_subnet_name" {
  description = "The name of the DR/Target subnetwork."
  type        = string
}

variable "restore_backup_id" {
  description = "The specific Backup ID (Recovery Point) to restore. If empty, the latest backup for 'vm-debian' will be used."
  type        = string
  default     = ""
}

variable "restore_suffix" {
  description = "Optional suffix to append to restored resources (e.g., '-dr'). If empty, uses source name."
  type        = string
  default     = ""
}

variable "create_isolated_dr_vpc" {
  description = "If true, creates a new Isolated VPC in the DR project and restores VMs there. If false, restores to the Shared VPC."
  type        = bool
  default     = false
}

variable "dr_isolated_vpc_cidr" {
  description = "The CIDR range for the Isolated DR Subnet. Should match production if testing IP retention."
  type        = string
}

variable "dr_isolated_subnet_name" {
  description = "Name of the subnet to create in the Isolated DR VPC."
  type        = string
  default     = "isolated-dr-subnet"
}

variable "disk_type" {
  description = "The type of persistent disk to use for data disks (e.g., pd-standard, pd-balanced, pd-ssd)."
  type        = string
  default     = "pd-standard"
}

variable "perform_dr_test" {
  description = "If true, performs the restore of VMs and Disks to the DR project."
  type        = bool
  default     = true
}


variable "gcbdr_project_id" {
  description = "The ID of the project to host the CMEK Backup Vault."
  type        = string
}

variable "infra_prod_project_id" {
  description = "The ID of the whitelisted project for CMEK-protected VMs."
  type        = string
}

variable "dr_psa_range_cidr" {
  description = "The CIDR range for Private Services Access in the Isolated DR VPC."
  type        = string
  default     = "10.240.0.0/16"
}

variable "provision_filestore" {
  description = "Whether to provision Filestore instances and their backup plans."
  type        = bool
  default     = false
}

variable "provision_alloydb" {
  description = "Whether to provision AlloyDB clusters and their backup plans."
  type        = bool
  default     = false
}

variable "parallelism" {
  description = "The number of concurrent operations for Terraform. Used by the wrapper script to run restores in parallel."
  type        = number
  default     = 30
}

variable "enforce_dr_dependencies" {
  description = "If true, enforces sequential restoration dependencies (AlloyDB -> Cloud SQL/Filestore -> VMs). If false, restores everything concurrently."
  type        = bool
  default     = false
}


# ------------------------------------------------------------------------------
# Restore Security Posture
# ------------------------------------------------------------------------------

variable "override_shielded_vm_org_policy" {
  description = <<-EOT
    If true, relaxes constraints/compute.requireShieldedVm on the DR project before restores (legacy behaviour).
    Backup and DR restores support Shielded VMs natively since April 2026, so this is no longer required and
    defaults to false to keep the DR project's security posture intact. Only enable if a restore still fails
    with "Error 412: Constraint constraints/compute.requireShieldedVm violated".
  EOT
  type        = bool
  default     = false
}

# ------------------------------------------------------------------------------
# Backup Vault Hardening
# ------------------------------------------------------------------------------

variable "vault_access_restriction" {
  description = "Access restriction applied to all backup vaults. One of WITHIN_PROJECT, WITHIN_ORGANIZATION, UNRESTRICTED, WITHIN_ORG_BUT_UNRESTRICTED_FOR_BA."
  type        = string
  default     = "WITHIN_ORGANIZATION"

  validation {
    condition     = contains(["WITHIN_PROJECT", "WITHIN_ORGANIZATION", "UNRESTRICTED", "WITHIN_ORG_BUT_UNRESTRICTED_FOR_BA"], var.vault_access_restriction)
    error_message = "vault_access_restriction must be one of WITHIN_PROJECT, WITHIN_ORGANIZATION, UNRESTRICTED, WITHIN_ORG_BUT_UNRESTRICTED_FOR_BA."
  }
}

# ------------------------------------------------------------------------------
# Backup Plan Enhancements
# ------------------------------------------------------------------------------

variable "enable_guest_flush" {
  description = "If true, enables application-consistent (guest flush / VSS) backups on Compute Engine instance backup plans (bp_vms, auto-protection and cross-region plans)."
  type        = bool
  default     = false
}

variable "max_custom_on_demand_retention_days" {
  description = "Optional cap (days) for on-demand backups taken with a custom retention on the Cloud SQL and AlloyDB backup plans. Null leaves the field unset."
  type        = number
  default     = null
}

variable "sql_log_retention_days" {
  description = "Optional number of days to retain Cloud SQL transaction logs in the vault (enables PITR from the vault). Must be >= the vault's minimum enforced log retention. Null leaves the field unset."
  type        = number
  default     = null
}

# ------------------------------------------------------------------------------
# Auto-Protection Policies (Preview)
# ------------------------------------------------------------------------------
# Terraform provider support for auto-protection is not yet available, so the
# policy and its bindings are managed with `gcloud beta backup-dr` through
# terraform_data + local-exec. See auto_protection.tf.

variable "enable_auto_protection" {
  description = "If true, provisions label-driven auto-protection: dedicated backup plans, an auto-protection policy, project bindings and labelled demo workloads."
  type        = bool
  default     = false
}

variable "auto_protection_policy_id" {
  description = "ID of the auto-protection policy (created in project_id / region)."
  type        = string
  default     = "ap-policy-gold"
}

variable "auto_protection_label_key" {
  description = "Label key matched by the auto-protection policy. All policies applied to a given workload project must share the same label key."
  type        = string
  default     = "backup-tier"
}

variable "auto_protection_label_value" {
  description = "Label value matched by the auto-protection policy."
  type        = string
  default     = "gold"
}

variable "auto_protection_scope_projects" {
  description = "Workload projects bound to the auto-protection policy. Defaults to [project_id] when empty. For projects other than project_id the vault service agent is granted computeEngineOperator and diskOperator."
  type        = list(string)
  default     = []
}

variable "auto_protection_demo_vm_count" {
  description = "Number of labelled demo VMs (vm-ap-N) to create so the policy has something to match. Set to 0 to only label your own resources."
  type        = number
  default     = 2

  validation {
    condition     = var.auto_protection_demo_vm_count >= 0 && var.auto_protection_demo_vm_count <= 5
    error_message = "auto_protection_demo_vm_count must be between 0 and 5 for a lab environment."
  }
}

variable "auto_protection_negative_test" {
  description = "If true, also creates vm-ap-unmatched carrying the same label key with a non-matching value. It must NOT be protected; scripts/verify_auto_protection.sh asserts this."
  type        = bool
  default     = true
}

variable "auto_protection_negative_label_value" {
  description = "Non-matching label value applied to the negative-test VM."
  type        = string
  default     = "bronze"
}

variable "restore_auto_protected_vms" {
  description = "If true (and perform_dr_test is true), auto-protected demo VMs are included in the DR restore drill once they have backups."
  type        = bool
  default     = true
}

# ------------------------------------------------------------------------------
# Cross-Region Backups (GA June 2026)
# ------------------------------------------------------------------------------

variable "enable_cross_region_backup" {
  description = "If true, creates a backup vault + plan in a secondary region and protects a demo VM (vm-xr) from the source region into it."
  type        = bool
  default     = false
}

variable "cross_region_vault_region" {
  description = "Region for the cross-region backup vault. Defaults to dr_region when empty, so the restore reads from a vault that survives a source-region outage."
  type        = string
  default     = ""
}

variable "cross_region_hourly_frequency" {
  description = "Hourly backup frequency for the cross-region backup plan."
  type        = number
  default     = 4
}

# ------------------------------------------------------------------------------
# Multi-Project Layout (central backup project, central KMS, lab-owned Shared VPC)
# ------------------------------------------------------------------------------

variable "vault_project_id" {
  description = "Project hosting the standard / auto-protection / cross-region backup vaults and plans. Empty = project_id (legacy single-project layout). Set to a dedicated backup project (usually = gcbdr_project_id) to protect project_id workloads cross-project."
  type        = string
  default     = ""
}

variable "kms_project_id" {
  description = "Central Cloud KMS project for ALL lab key rings (compute CMEK, vault CMEK, infra DR key). Empty = keep each key ring in the project it encrypts (legacy layout)."
  type        = string
  default     = ""
}

variable "create_shared_vpc" {
  description = "If true, Terraform creates the Shared VPC (vpc_name) in host_project_id with subnet_name in region and dr_subnet_name in dr_region, enables it as an XPN host and attaches the service projects. If false, an existing Shared VPC is looked up."
  type        = bool
  default     = false
}

variable "subnet_cidr" {
  description = "CIDR for subnet_name (source region) when create_shared_vpc = true."
  type        = string
  default     = "10.70.0.0/24"
}

variable "dr_subnet_cidr" {
  description = "CIDR for dr_subnet_name (dr_region) when create_shared_vpc = true."
  type        = string
  default     = "10.70.16.0/24"
}

variable "enable_project_services" {
  description = "If true, Terraform also enables the required APIs in gcbdr / vault / infra_prod / host / kms projects (project_id and dr_project_id are always managed)."
  type        = bool
  default     = true
}

variable "cmek_vault_suffix" {
  description = "Optional suffix for the CMEK vault name (default: random vault suffix). Set a new value when rebuilding the lab after a destroy: the KMS key is new, but the old CMEK vault still holds enforced-retention backups and cannot be deleted or re-keyed."
  type        = string
  default     = ""

  validation {
    condition     = can(regex("^[a-z0-9-]{0,12}$", var.cmek_vault_suffix))
    error_message = "cmek_vault_suffix must be 0-12 chars of [a-z0-9-]."
  }
}

variable "auto_protection_name_suffix" {
  description = "Optional suffix (e.g. \"-r2\") appended to auto-protection policy and bp-autoprotect-* plan IDs. Use when rebuilding the lab while the previous run's bindings are still DELETION_INITIATED (the unbind can take hours)."
  type        = string
  default     = ""

  validation {
    condition     = can(regex("^(-[a-z0-9]{1,8})?$", var.auto_protection_name_suffix))
    error_message = "auto_protection_name_suffix must be empty or '-' followed by 1-8 chars of [a-z0-9]."
  }
}
