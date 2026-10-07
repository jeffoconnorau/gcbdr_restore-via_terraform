# ------------------------------------------------------------------------------
# Auto-Protection Policies (Preview)
# ------------------------------------------------------------------------------
# Label-driven protection: any Compute Engine instance or disk in a bound
# workload project, in var.region, carrying
#   <auto_protection_label_key> = <auto_protection_label_value>
# is automatically associated with the backup plans below.
#
# Docs: https://docs.cloud.google.com/backup-disaster-recovery/docs/protect/automate-protection
#
# Preview limitations (Sept 2026):
#   * Compute Engine instances and disks only.
#   * Every policy applied to one workload project must use the SAME label key.
#   * One region per policy.
#   * ONE backup plan (resource type) per policy -> this lab creates two policies,
#     <policy_id>-vms (Instance) and <policy_id>-disks (Disk), sharing the label.
#   * No Terraform provider resource yet -> managed via `gcloud beta backup-dr`
#     from terraform_data + local-exec (create/update on apply, delete on destroy).
#   * Matching + association typically takes up to 2h (worst case 8h).
# ------------------------------------------------------------------------------

locals {
  ap_enabled = var.enable_auto_protection

  # Appended to policy + plan IDs so a rebuilt lab does not wait on (or collide
  # with) policies/plans from a previous run that are still unwinding.
  ap_suffix = var.auto_protection_name_suffix

  ap_scope_projects = length(var.auto_protection_scope_projects) > 0 ? var.auto_protection_scope_projects : [var.project_id]

  # Scopes outside the vault project need the vault service agent to hold
  # operator roles there (granted in iam_cross_project.tf).
  ap_cross_project_scopes = local.ap_enabled ? toset([for p in local.ap_scope_projects : p if p != local.vault_project]) : toset([])

  ap_match_labels = {
    (var.auto_protection_label_key) = var.auto_protection_label_value
  }

  ap_demo_vm_names = local.ap_enabled ? [for i in range(var.auto_protection_demo_vm_count) : "vm-ap-${i + 1}"] : []

  # One policy per resource type (API: "Only one BackupPlanDetail is allowed").
  ap_policies = local.ap_enabled ? {
    vms = {
      policy_id     = "${var.auto_protection_policy_id}-vms${local.ap_suffix}"
      resource_type = "compute.googleapis.com/Instance"
      plan          = google_backup_dr_backup_plan.bp_autoprotect_vms[0].id
    }
    disks = {
      policy_id     = "${var.auto_protection_policy_id}-disks${local.ap_suffix}"
      resource_type = "compute.googleapis.com/Disk"
      plan          = google_backup_dr_backup_plan.bp_autoprotect_disks[0].id
    }
  } : {}

  ap_bindings = {
    for pair in setproduct(keys(local.ap_policies), local.ap_scope_projects) :
    "${pair[0]}/${pair[1]}" => { policy = pair[0], scope_project = pair[1] }
  }
}

# ------------------------------------------------------------------------------
# Backup Plans targeted by the policy (one per supported resource type)
# ------------------------------------------------------------------------------

resource "google_backup_dr_backup_plan" "bp_autoprotect_vms" {
  count          = local.ap_enabled ? 1 : 0
  provider       = google
  project        = local.vault_project
  location       = var.region
  backup_plan_id = "bp-autoprotect-vms${local.ap_suffix}"
  description    = "Assigned automatically by auto-protection policy ${var.auto_protection_policy_id} (${var.auto_protection_label_key}=${var.auto_protection_label_value})."
  resource_type  = "compute.googleapis.com/Instance"
  backup_vault   = google_backup_dr_backup_vault.vault.id

  backup_rules {
    rule_id               = "hourly-backup"
    backup_retention_days = 3

    standard_schedule {
      recurrence_type  = "HOURLY"
      hourly_frequency = 1
      time_zone        = "UTC"
      backup_window {
        start_hour_of_day = 0
        end_hour_of_day   = 24
      }
    }
  }

  dynamic "compute_instance_backup_plan_properties" {
    for_each = var.enable_guest_flush ? [1] : []
    content {
      guest_flush = true
    }
  }

  depends_on = [time_sleep.wait_for_vault]
}

resource "google_backup_dr_backup_plan" "bp_autoprotect_disks" {
  count          = local.ap_enabled ? 1 : 0
  provider       = google
  project        = local.vault_project
  location       = var.region
  backup_plan_id = "bp-autoprotect-disks${local.ap_suffix}"
  description    = "Assigned automatically by auto-protection policy ${var.auto_protection_policy_id} (${var.auto_protection_label_key}=${var.auto_protection_label_value})."
  resource_type  = "compute.googleapis.com/Disk"
  backup_vault   = google_backup_dr_backup_vault.vault.id

  backup_rules {
    rule_id               = "hourly-backup"
    backup_retention_days = 3

    standard_schedule {
      recurrence_type  = "HOURLY"
      hourly_frequency = 1
      time_zone        = "UTC"
      backup_window {
        start_hour_of_day = 0
        end_hour_of_day   = 24
      }
    }
  }

  depends_on = [time_sleep.wait_for_vault]
}

# ------------------------------------------------------------------------------
# Auto-Protection Policy (gcloud beta)
# ------------------------------------------------------------------------------

resource "terraform_data" "auto_protection_policy" {
  for_each = local.ap_policies

  input = {
    project       = local.vault_project
    location      = var.region
    policy_id     = each.value.policy_id
    label_key     = var.auto_protection_label_key
    label_value   = var.auto_protection_label_value
    resource_type = each.value.resource_type
    plan          = each.value.plan
    description   = "Lab auto-protection (${each.key}): ${var.auto_protection_label_key}=${var.auto_protection_label_value} -> ${basename(each.value.plan)}"
    # Used only by the destroy provisioner (which may only reference self).
    scope_projects = join(",", local.ap_scope_projects)
    destroy_script = abspath("${path.module}/scripts/ap_destroy.sh")
  }

  # Any change to the policy spec re-runs the create/update provisioner.
  triggers_replace = [
    each.value.policy_id,
    var.auto_protection_label_key,
    var.auto_protection_label_value,
    each.value.plan,
  ]

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      if ! gcloud beta backup-dr auto-protection-policies --help >/dev/null 2>&1; then
        echo "[ERROR] 'gcloud beta backup-dr auto-protection-policies' not available. Run: gcloud components install beta && gcloud components update" >&2
        exit 1
      fi

      COMMON=(--project="${self.output.project}" --location="${self.output.location}")
      SPEC=(
        --criteria="key=${self.output.label_key},values=${self.output.label_value}"
        --backup-plan-details="resource-type=${self.output.resource_type},backup-plan=${self.output.plan}"
        --description="${self.output.description}"
      )

      if gcloud beta backup-dr auto-protection-policies describe "${self.output.policy_id}" "$${COMMON[@]}" >/dev/null 2>&1; then
        echo "[INFO] Auto-protection policy ${self.output.policy_id} exists - updating in place."
        gcloud beta backup-dr auto-protection-policies update "${self.output.policy_id}" "$${COMMON[@]}" "$${SPEC[@]}" --no-async
      else
        echo "[INFO] Creating auto-protection policy ${self.output.policy_id}."
        gcloud beta backup-dr auto-protection-policies create "${self.output.policy_id}" "$${COMMON[@]}" "$${SPEC[@]}" --no-async
      fi
    EOT
  }

  # Runs after all bindings are gone (bindings depend on the policy). Retries
  # through POLICY_IN_USE_BY_BINDING, then waits until no policy-managed BPA
  # references the plan, so the backup plan delete that follows succeeds.
  provisioner "local-exec" {
    when        = destroy
    interpreter = ["bash", "-c"]
    command     = "bash '${self.output.destroy_script}' policy '${self.output.project}' '${self.output.location}' '${self.output.policy_id}' '${basename(self.output.plan)}' '${self.output.scope_projects}'"
  }
}

# ------------------------------------------------------------------------------
# Policy Bindings (one per workload project in scope)
# ------------------------------------------------------------------------------

resource "terraform_data" "auto_protection_binding" {
  for_each = local.ap_bindings

  input = {
    project    = local.vault_project
    location   = var.region
    policy_id  = local.ap_policies[each.value.policy].policy_id
    binding_id = substr("bind-${each.value.scope_project}", 0, 63)
    scope      = "projects/${each.value.scope_project}"
    # Destroy provisioners may only reference self, so carry the path here.
    destroy_script = abspath("${path.module}/scripts/ap_destroy.sh")
  }

  triggers_replace = [
    terraform_data.auto_protection_policy[each.value.policy].id,
    each.value.scope_project,
  ]

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      COMMON=(--auto-protection-policy="${self.output.policy_id}" --project="${self.output.project}" --location="${self.output.location}")
      # A binding still unwinding from a previous destroy must finish before re-create.
      for i in $(seq 1 240); do
        STATE=$(gcloud beta backup-dr auto-protection-bindings describe "${self.output.binding_id}" "$${COMMON[@]}" --format='value(state)' 2>/dev/null || true)
        [[ "$STATE" == "DELETION_INITIATED" ]] || break
        echo "[INFO] Binding ${self.output.binding_id} is DELETION_INITIATED from a previous destroy - waiting 60s ($i/240)."
        sleep 60
      done
      if [[ -n "$STATE" && "$STATE" != "DELETION_INITIATED" ]]; then
        echo "[INFO] Binding ${self.output.binding_id} -> ${self.output.scope} already exists ($STATE)."
      else
        echo "[INFO] Binding policy ${self.output.policy_id} to ${self.output.scope}."
        gcloud beta backup-dr auto-protection-bindings create "${self.output.binding_id}" "$${COMMON[@]}" \
          --scope="${self.output.scope}" --no-async
      fi
    EOT
  }

  # Unbinding is async (DELETION_INITIATED while the service unwinds the
  # policy-managed BPAs); block until the binding is really gone.
  provisioner "local-exec" {
    when        = destroy
    interpreter = ["bash", "-c"]
    command     = "bash '${self.output.destroy_script}' binding '${self.output.project}' '${self.output.location}' '${self.output.policy_id}' '${self.output.binding_id}'"
  }

  depends_on = [
    google_project_iam_member.vault_sa_workload_compute_operator,
    google_project_iam_member.vault_sa_workload_disk_operator,
  ]
}

# ------------------------------------------------------------------------------
# Demo Workloads
# ------------------------------------------------------------------------------
# NOTE: there are intentionally NO google_backup_dr_backup_plan_association
# resources for these - protection must come from the policy alone.

# Positive matches: vm-ap-1..N carry the matching label.
resource "google_compute_instance" "vm_autoprotect" {
  for_each     = toset(local.ap_demo_vm_names)
  name         = each.value
  machine_type = "e2-micro"
  zone         = "${var.region}-a"

  labels = merge(local.ap_match_labels, { lab = "auto-protection" })

  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-12"
    }
  }

  network_interface {
    subnetwork = local.source_subnet_self_link
  }

  shielded_instance_config {
    enable_secure_boot          = true
    enable_vtpm                 = true
    enable_integrity_monitoring = true
  }

  lifecycle {
    ignore_changes = [attached_disk]
  }

  depends_on = [time_sleep.wait_for_apis]
}

# Positive match (disk plan): labelled data disk attached to vm-ap-1.
resource "google_compute_disk" "disk_autoprotect" {
  count  = local.ap_enabled && var.auto_protection_demo_vm_count > 0 ? 1 : 0
  name   = "vm-ap-1-data-disk"
  type   = var.disk_type
  zone   = "${var.region}-a"
  size   = 10
  labels = merge(local.ap_match_labels, { lab = "auto-protection" })

  depends_on = [time_sleep.wait_for_apis]
}

resource "google_compute_attached_disk" "attach_disk_autoprotect" {
  count    = local.ap_enabled && var.auto_protection_demo_vm_count > 0 ? 1 : 0
  disk     = google_compute_disk.disk_autoprotect[0].id
  instance = google_compute_instance.vm_autoprotect["vm-ap-1"].id
}

# Negative test: same label key, non-matching value -> must stay unprotected.
resource "google_compute_instance" "vm_autoprotect_negative" {
  count        = local.ap_enabled && var.auto_protection_negative_test ? 1 : 0
  name         = "vm-ap-unmatched"
  machine_type = "e2-micro"
  zone         = "${var.region}-a"

  labels = {
    (var.auto_protection_label_key) = var.auto_protection_negative_label_value
    lab                             = "auto-protection"
  }

  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-12"
    }
  }

  network_interface {
    subnetwork = local.source_subnet_self_link
  }

  shielded_instance_config {
    enable_secure_boot          = true
    enable_vtpm                 = true
    enable_integrity_monitoring = true
  }

  depends_on = [time_sleep.wait_for_apis]
}
