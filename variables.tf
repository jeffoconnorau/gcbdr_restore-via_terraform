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

variable "provision_vms" {
  description = "Whether to provision Compute Engine VMs and Disks."
  type        = bool
  default     = true
}

variable "provision_cloud_sql" {
  description = "Whether to provision Cloud SQL instances."
  type        = bool
  default     = true
}

variable "provision_alloydb" {
  description = "Whether to provision AlloyDB Cluster and Instance."
  type        = bool
  default     = false
}

variable "provision_filestore" {
  description = "Whether to provision Filestore Instance."
  type        = bool
  default     = false
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
