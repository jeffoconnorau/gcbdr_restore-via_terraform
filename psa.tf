# ------------------------------------------------------------------------------
# Private Services Access (PSA) Configuration - Source Environment
# ------------------------------------------------------------------------------
# These resources are created in the SHARED VPC HOST PROJECT.
# This enables connectivity for Source Cloud SQL instances attached to the Shared VPC.
# (For DR Isolated VPC PSA, see network_dr.tf)
# ------------------------------------------------------------------------------

# Reserved IP Range for Services
resource "google_compute_global_address" "private_ip_address" {
  count = var.create_psa ? 1 : 0

  provider      = google-beta
  project       = var.host_project_id # HOST PROJECT
  name          = var.psa_range_name
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 16 # Adjust based on user needs, derived from variable if we want to be fancy, but simple prefix string var is often easier. 
                     # Wait, `google_compute_global_address` uses `prefix_length` (int) if we let GCE pick, 
                     # OR `address` and `op_type`?
                     # Actually for PSA we usually specify `address` and `prefix_length` OR just `prefix_length`.
                     # Let's support specific range via variable.
  network       = data.google_compute_network.shared_vpc.id
  
  # If user provided a specific CIDR (e.g. "10.200.0.0/16"), we need to split it if we use address+prefix_length.
  # Simplest way for flexible PSA is often just asking for a length (e.g. /16) unless strict IPAM is needed.
  # I'll stick to a simple ALLOCATION for now if the user didn't give strict instruction, but I added `psa_range_prefix` var.
  # If I use `address` argument I can force it.
}

# The Service Networking Connection (Peering)
resource "google_service_networking_connection" "private_vpc_connection" {
  count = var.create_psa ? 1 : 0

  provider                = google-beta
  network                 = data.google_compute_network.shared_vpc.id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.private_ip_address[0].name]
  
  # Ensure we have the Host Project ID correct here? 
  # Actually `network` is the ID (projects/.../global/networks/...), so it implicitly targets that network.
  # But the resource itself makes calls to Service Networking API.
  # It usually runs in the project where the quota is consumed? 
  # It should be sufficient to just point to the network if we have permissions.
  # But explicit project is safer.
  # However, `google_service_networking_connection` doesn't have a `project` field! 
  # It uses the provider's project or infers from network? 
  # Actually it DOES NOT have a project field. It manages the peering on the `network`.
  # So it effectively modifies the Host Project Network.
}
