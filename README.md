# Backup DR Beta Test - Terraform Project

This Terraform project provisions a test environment for Google Cloud Backup and DR (Beta) features, specifically focusing on **Cross-Project CMEK Backups** and **Split-Brain Restore Strategies**.

## Project Structure

The project follows standard Terraform modular practices:

- **`main.tf`**: Core compute and database resources (VMs, Cloud SQL).
- **`backup.tf`**: Backup infrastructure (Vaults, Plans, Associations).
- **`restore.tf`**: Dedicated configuration for testing restore operations.
- **`apis.tf`**: API enablement and dependency management.
- **`kms_infra_prod.tf`**: CMEK Key infrastructure for the encrypted source project.
- **`kms_gcbdr.tf`**: KMS configuration for the Backup Vault project.
- **`network_dr.tf`**: Isolated VPC configuration for DR testing.
- **`scripts/`**: Helper scripts for finding backup recovery points across projects.

## Prerequisites

- **Terraform**: >= 1.5.0
- **Google Cloud SDK**: You must have `gcloud` installed and authenticated (`gcloud auth login`).
  > **Note**: The restore scripts use your local `gcloud` credentials to dynamically discover backups. ensure your session is active.
- **Google Cloud Projects**: You will need source, target (DR), and backup vault projects.

> [!IMPORTANT]
> **CMEK Support Requirement**: Support for Customer-Managed Encryption Keys (CMEK) with Backup and DR is currently a **Restricted GA / Allowlist-only** feature. 
> To test this capability, you must have your project explicitly allowlisted. Please contact your **Google Cloud Account Team** to request access before attempting to provision CMEK-protected backups.

## Configuration

This project avoids hardcoding environment-specific values. 

1.  **Copy the example variables file:**
    ```bash
    cp terraform.tfvars.example terraform.tfvars
    ```
2.  **Edit `terraform.tfvars`** with your specific project IDs, regions, and network names.
    *   `project_id`: Source Project ID
    *   `dr_project_id`: Target/DR Project ID
    *   `gcbdr_project_id`: Backup Vault Project ID
    *   `infra_prod_project_id`: CMEK Source Project ID

## Core Concepts

### Cross-Project CMEK Strategy
To support CMEK-encrypted backups, we implement a **Cross-Project Vault Architecture**:
1.  **Source**: CMEK-encrypted VMs reside in the CMEK Source Project (`infra_prod_project_id`).
2.  **Vault**: Backups are stored in a separate project (`gcbdr_project_id`) using a CMEK-enabled Backup Vault.
3.  **Key Management**: Both projects utilize specific Service Agents with bidirectional IAM permissions to allow encryption/decryption across project boundaries.

### Split-Brain Restore Strategy
During a Disaster Recovery (DR) Test, we employ a "Split-Brain" approach to handle different workload requirements:

1.  **Standard Workloads**:
    - Restored to **DR Project** (`dr_project_id`).
    - Can target Shared VPC or Isolated VPC.
2.  **CMEK Encrypted Workloads**:
    - Restored to **Source Project** (`infra_prod_project_id`) in the **Source Region** (In-Place Restore).
    - **Reason**: Cloud Key Management Service (KMS) keys are regional. To verify the restore without complex re-keying or cross-region key creation, we restore strictly to the source location using the original Source Key.

## Usage

### 1. Initialize
```bash
terraform init
```

### 2. Provision Resources (Backup Phase)
Apply the base configuration to create VMs, enable APIs, and configure Backup Plans.
```bash
terraform apply
```
*Note: Includes wait timers (approx. 2-3 mins) for API enablement and IAM propagation.*

### 3. Perform DR Test (Restore Phase)
To trigger the restore process, use the specific DR variables. This will find the latest backups and restore them according to the Split-Brain strategy.

```bash
terraform apply \
  -var="perform_dr_test=true" \
  -var="provision_cloud_sql=false" \
  -var="create_isolated_dr_vpc=true" \
  -var="restore_suffix=-dr"
```

### 4. Verification
After the apply completes:

**Standard VMs (DR Project):**
```bash
gcloud compute instances list --project=<your-dr-project-id>
```

**CMEK VM (Source Project):**
```bash
gcloud compute instances list --project=<your-cmek-source-project-id> --filter="labels.dr=test"
```

### 5. If `terraform destroy` fails on Backup Plans due to "Association exists":
1.  Manually delete the Association in GCP Console or via gcloud.
2.  If that fails or you want to skip it, remove the resources from state:
    ```bash
    terraform state rm google_backup_dr_backup_plan.bp_vms
    terraform state rm google_backup_dr_backup_plan_association.bpa_vm_debian
    ```
    Then run destroy again.

### 6. Cleanup (Destroy Tests Only)
To remove only the restored resources (leaving backups intact):

```bash
# Destroy Restored Workloads
terraform destroy \
  -target=google_backup_dr_restore_workload.restore_vms \
  -target=google_backup_dr_restore_workload.restore_vm_rocky \
  -target=google_backup_dr_restore_workload.restore_rocky_disk \
  -target=google_compute_attached_disk.attach_restored_rocky_disk \
  -target=null_resource.tag_restored_vm

# If Isolated VPC was created, destroy it too
terraform destroy \
  -target=google_compute_network.isolated_dr_vpc \
  -target=google_compute_subnetwork.isolated_dr_subnet
```

> [!WARNING]
> **Full Destroy Caveats**: If you run `terraform destroy` on the entire project, you may encounter errors:
> 1.  **Backup Vaults**: Cannot be destroyed if they contain backups (`NON_EMPTY_BACKUP_VAULT_DELETION`). You must manually delete the backups from the GCBDR Console first or accept that Vaults persist.
> 2.  **Backup Plans**: May fail if Associations are not largely deleted first (`BACKUP_PLAN_ASSOCIATIONS_EXIST`). Re-running destroy usually fixes this.
> 3.  **Service Networking**: May fail to release the IP range if Cloud SQL instances were just deleted (`Error code 9`). This typically resolves itself after a few minutes.

## Known Limitations

### Cloud SQL Restore Implementation
> [!NOTE]
> Unlike Compute Engine restores which use the `google_backup_dr_restore_workload` resource, Cloud SQL restores use the standard **`google_sql_database_instance`** resource (Cloud SQL Module).
>
> The restore is triggered by passing the GCBDR Backup ID to the `backupdr_backup` argument within the `google_sql_database_instance` block. This approach is fully supported and confirmed working.



### Shielded VM Policy Violation
If you see `Error 412: Constraint constraints/compute.requireShieldedVm violated`, it is because the Backup recovery point lacks specific Shielded VM metadata.
*   **Solution**: This project automatically disables the policy on the DR project via `google_project_organization_policy` and then strictly enforces Shielded features on the restored VM within the `restore_workload` block. This "Override + Enforce" pattern ensures security compliance.
