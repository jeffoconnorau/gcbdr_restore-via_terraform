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

- **Source Project (Standard)**: `argo-svc-dev-3`
- **Source Project (CMEK)**: `argo-svc-infra-prod`
- **DR Project**: `argo-svc-dev-4`
- **Backup Vault Project**: `argo-svc-gcbdr`
- **Host Project**: `argo-host-shared-vpc`

## Core Concepts

### Cross-Project CMEK Strategy
To support CMEK-encrypted backups, we implement a **Cross-Project Vault Architecture**:
1.  **Source**: CMEK-encrypted VMs reside in `argo-svc-infra-prod`.
2.  **Vault**: Backups are stored in `argo-svc-gcbdr` (a separate project) using a CMEK-enabled Backup Vault.
3.  **Key Management**: Both projects utilize specific Service Agents with bidirectional IAM permissions to allow encryption/decryption across project boundaries.

### Split-Brain Restore Strategy
During a Disaster Recovery (DR) Test, we employ a "Split-Brain" approach to handle different workload requirements:

1.  **Standard Workloads (`vm-debian`, `vm-ubuntu`)**:
    - Restored to **DR Project** (`argo-svc-dev-4`).
    - Can target Shared VPC or Isolated VPC.
2.  **CMEK Encrypted Workloads (`vm-rocky`)**:
    - Restored to **Source Project** (`argo-svc-infra-prod`) in the **Source Region** (In-Place Restore).
    - **Reason**: Cloud Key Management Service (KMS) keys are regional. To verify the restore without complex re-keying or cross-region key creation, we restore strictly to the source location (`asia-southeast1`) using the original Source Key.

5.  **Label Patching**:
    - Due to current provider limitations in propagating labels, a `null_resource` "patcher" automatically applies `dr=test` tags to restored instances immediately after creation.

## Connectivity

- **Private Service Connect (PSC)**: The project optionally provisions Private Service Access for Cloud SQL.
- **Shared VPC**: Leverages a robust Hub-and-Spoke model via `argo-host-shared-vpc`.
- **Isolated DR Network**: Supports creating a completely air-gapped VPC for destructive testing.

## usage

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

**Variable Breakdown:**
*   `perform_dr_test=true`: **Active Restore**. Enables the `restore.tf` logic.
*   `provision_cloud_sql=false`: **Skip SQL**. speeds up the test by ignoring database layers.
*   `create_isolated_dr_vpc=true`: **Isolated Network**. Creates a quarantined VPC for standard VM restores.
*   `restore_suffix=-dr`: **Naming**. Appends `-dr` to resource names to avoid collisions.

### 4. Verification
After the apply completes:

**Standard VMs (DR Project):**
```bash
gcloud compute instances list --project=argo-svc-dev-4
```

**CMEK VM (Source Project):**
```bash
gcloud compute instances list --project=argo-svc-infra-prod --filter="labels.dr=test"
```

### 5. Cleanup (Destroy Tests Only)
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

## Troubleshooting

### Shielded VM Policy Violation
If you see `Error 412: Constraint constraints/compute.requireShieldedVm violated`, it is because the Backup recovery point lacks specific Shielded VM metadata.
*   **Solution**: This project automatically disables the policy on the DR project via `google_project_organization_policy` and then strictly enforces Shielded features on the restored VM within the `restore_workload` block. This "Override + Enforce" pattern ensures security compliance.
