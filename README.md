# Backup DR Beta Test - Terraform Project

This Terraform project provisions a test environment for Google Cloud Backup and DR (Beta) features, specifically focusing on cross-project and cross-region restore capabilities.

## Project Structure

The project follows standard Terraform modular practices, separating concerns into distinct files:

- **`main.tf`**: Core compute and database resources (VMs, Cloud SQL).
- **`backup.tf`**: Backup infrastructure (Vaults, Plans, Associations) with reliability wait timers.
- **`restore.tf`**: Template for testing cross-project/region restores.
- **`apis.tf`**: API enablement and dependency management.
- **`data.tf`**: Data sources for networking (Shared VPC).
- **`psa.tf`**: Optional Private Services Access (PSA) configuration for Cloud SQL connectivity.
- **`variables.tf`**: Configurable variables for Source and DR environments.
- **`versions.tf`**: Provider versions (including `google-beta` and `time`).
- **`outputs.tf`**: Key resource outputs.

## Prerequisites

- **Source Project**: `argo-svc-dev-3` (default)
- **Host Project**: `argo-host-shared-vpc`
- **Shared VPC**: `vpc-jeffoconnor` (with subnetwork `vpc-sub-sg-24`)
- **Terraform**: >= 1.5.0

## Usage

### 1. Initialize

```bash
terraform init
```

### 2. Configure Variables (Optional)

You can override defaults using a `terraform.tfvars` file or command-line flags.

**Key Variables:**
- `create_psa`: Set to `true` if you need to create the Private Services Access connection.
- `dr_project_id`: Target project for restore (default: `argo-svc-dev-4`).
- `dr_region`: Target region for restore (default: `asia-southeast2`).

### 3. Apply

```bash
terraform apply
```

*Note: The apply process includes explicit wait timers (approx. 2-3 minutes total) to ensure Backup Vaults and APIs are fully ready before creating dependent resources. The `time_sleep` resource for APIs is configured with `triggers` to automatically reset the timer if any new API is enabled, ensuring robust propagation.*

## DR Testing Lifecycle

This project is designed to simulate a full Disaster Recovery cycle: **Backup -> Restore -> Verify -> Cleanup**.

### 1. Enable & Run Restore
The restore logic is active by default but requires a valid backup to exist.

**Standard Restore (Shared VPC):**
Restores VMs to the DR Project (`argo-svc-dev-4`) but connects them to the **Source Shared VPC** (Host Project).
```bash
terraform apply
```

**Isolated Restore (Disconnected DR Test):**
Restores VMs to the DR Project inside a **new, isolated VPC**. This simulates a complete site isolation.
```bash
terraform apply -var="create_isolated_dr_vpc=true"
```

### 4. Perform DR Test (Restore)
This project implements a **Split-Brain Restore Strategy**:
- **Standard VMs (`vm-debian`)**: Restored to the **DR Project** (`argo-svc-dev-4`) in the Isolated DR VPC.
- **CMEK VM (`vm-rocky`)**: Restored to the **Source Project** (`argo-svc-infra-prod`) to maintain CMEK encryption compatibility (In-Place Restore).

To run the restore test:
```bash
terraform apply \
  -var="perform_dr_test=true" \
  -var="provision_cloud_sql=false" \
  -var="create_isolated_dr_vpc=true" \
  -var="restore_suffix=-dr"
```
*Note: The `vm-rocky` restore includes a label patcher to ensure `dr=test` tags are applied.*

#### Advanced: Customized DR Test
For a comprehensive DR test that mimics the user's complex scenario (skipping Cloud SQL, using isolated network, and custom suffixes), use:

```bash
terraform apply \
  -var="perform_dr_test=true" \
  -var="provision_cloud_sql=false" \
  -var="create_isolated_dr_vpc=true" \
  -var="restore_suffix=-dr"
```

**Variable Breakdown:**
*   `perform_dr_test=true`: **Enable Restore**. Triggers the restore of VMs and Disks.
*   `provision_cloud_sql=false`: **Skip SQL**. Saves time and resources by not deploying/restoring Cloud SQL instances.
*   `create_isolated_dr_vpc=true`: **Isolated Network**. Restores workloads into a new, air-gapped VPC (no internet access) instead of the Shared VPC.
*   `restore_suffix=-dr`: **Custom Naming**. Appends `-dr` to the restored resources (e.g., `vm-debian` -> `vm-debian-dr`) to distinguish them from production or avoid conflicts.

*The restore process will:*
1.  Automatically find the latest backup for each VM (`vm-debian`, `vm-ubuntu`, `vm-rocky`).
2.  Restore them to `asia-southeast2` (DR Region).
3.  **Attach the restored Data Disk** to `vm-debian` (or `vm-debian-dr`).
4.  Apply `dr:test` labels.



### 2. Verify Restored Workloads
Once `terraform apply` completes, verify the resources in the DR project:

```bash
# Check instances in DR project
gcloud compute instances list --project=argo-svc-dev-4

# Check Isolated VPC (if enabled)
gcloud compute networks list --project=argo-svc-dev-4
```

### 3. Cleanup (Tear Down DR Only)
To complete the test cycle, destroy **only** the restored workloads while keeping your Source Environment and Backups intact.

**Standard Cleanup:**
```bash
terraform destroy -target=google_backup_dr_restore_workload.restore_vms
```

**Isolated Cleanup (Include Network):**
If you ran the Isolated Restore, you must also destroy the isolated network resources:
```bash
terraform destroy \
  -target=google_backup_dr_restore_workload.restore_vms \
  -target=google_compute_network.isolated_dr_vpc \
  -target=google_compute_subnetwork.isolated_dr_subnet
```

## Network Security & Cloud DNS
When performing an **Isolated Restore** (`create_isolated_dr_vpc=true`), the environment is hardened for true isolation:

1.  **No Default Route**: The Isolated VPC has **no route to 0.0.0.0/0** (Internet/WAN), preventing any egress traffic.
2.  **Cloud DNS Enabled**:
    *   **Logging**: DNS query logging is enabled for auditability.
    *   **Private Zone**: A private zone `dr.test.internal` is created to verify internal name resolution.
    *   **Records**: A test record `verification.dr.test.internal` (points to `1.1.1.1`) is included to confirm DNS functionality.

## Troubleshooting & Security Architecture

### Shielded VM Organization Policy (`constraints/compute.requireShieldedVm`)

You may encounter the following error during restore, even if your Source VM is fully Shielded:
> `Error 412: Constraint constraints/compute.requireShieldedVm violated`

#### The Cause: "Source" vs. "Result"
The Organization Policy acts as an admission controller that validates the **Source Image** of the resource being created.
1.  **Strict Source Check**: The policy prohibits creating an instance from a disk/image that isn't strictly stamped with Shielded Guest OS features.
2.  **Backup Metadata**: Backup DR beta backups may naturally lack this specific metadata tag on the recovery point, causing the policy to flag the "Source" (the backup) as non-compliant, regardless of the VM's actual state at backup time.

#### The Solution: "Override + Enforce"
We implemented an architectural pattern to bridge this gap without compromising security:
1.  **Temporary Override**: We explicitly disable (override) the `constraints/compute.requireShieldedVm` policy on the **DR Target Project** using `google_project_organization_policy`.
2.  **Strict Enforcement**: We explicitly configure the **Restore Job** (`google_backup_dr_restore_workload`) to enable Secure Boot, vTPM, and Integrity Monitoring (`shielded_instance_config`).

**Result**: The admission controller allows the "non-compliant source" (the backup) to pass, but the Terraform configuration ensures the **resulting VM** is fully Shielded and secure.

### Cloud SQL Restore
> [!NOTE]
> As of provider version `7.16.0`, the `google_backup_dr_restore_workload` resource **only supports Compute Engine Instances and Disks**. Native Cloud SQL restore is not yet available in Terraform headers. You must perform Cloud SQL restores via the Google Cloud Console or `gcloud` CLI.
