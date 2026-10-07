#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# bootstrap_projects.sh
# ------------------------------------------------------------------------------
# Prepares brand-new projects for the lab BEFORE the first `terraform apply`:
#   * enables the APIs each project role needs (Terraform also manages them,
#     but enabling up front avoids first-apply propagation races)
#   * creates the Backup and DR service agent in the backup/vault project(s)
#   * prints the effective org policies that commonly break this lab
#
# Reads project IDs from terraform.tfvars (simple key = "value" lines) unless
# overridden by env vars of the same name in UPPER CASE.
#
# Usage: ./scripts/bootstrap_projects.sh [-n]    # -n = dry run
# ------------------------------------------------------------------------------
set -euo pipefail
cd "$(dirname "$0")/.."

DRY_RUN=0
[[ "${1:-}" == "-n" ]] && DRY_RUN=1

tfvar() {
  local key="$1" env_key
  env_key=$(tr '[:lower:]' '[:upper:]' <<<"$key")
  if [[ -n "${!env_key:-}" ]]; then echo "${!env_key}"; return; fi
  [[ -f terraform.tfvars ]] || return 0
  sed -nE "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*\"([^\"]*)\".*/\1/p" terraform.tfvars | head -1
}
tfbool() { [[ "$(sed -nE "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*(true|false).*/\1/p" terraform.tfvars 2>/dev/null | head -1)" == "true" ]]; }

PROJECT_ID=$(tfvar project_id)
DR_PROJECT_ID=$(tfvar dr_project_id)
GCBDR_PROJECT_ID=$(tfvar gcbdr_project_id)
INFRA_PROD_PROJECT_ID=$(tfvar infra_prod_project_id)
HOST_PROJECT_ID=$(tfvar host_project_id)
VAULT_PROJECT_ID=$(tfvar vault_project_id); VAULT_PROJECT_ID=${VAULT_PROJECT_ID:-$PROJECT_ID}
KMS_PROJECT_ID=$(tfvar kms_project_id)

for v in PROJECT_ID DR_PROJECT_ID GCBDR_PROJECT_ID INFRA_PROD_PROJECT_ID HOST_PROJECT_ID; do
  [[ -n "${!v}" ]] || { echo "[ERROR] $v not set (terraform.tfvars or env)." >&2; exit 1; }
done

BASE=(serviceusage.googleapis.com cloudresourcemanager.googleapis.com iam.googleapis.com orgpolicy.googleapis.com)
DB=()
tfbool provision_cloud_sql && DB+=(sqladmin.googleapis.com)
tfbool provision_filestore && DB+=(file.googleapis.com)
tfbool provision_alloydb   && DB+=(alloydb.googleapis.com)
NET=(); { tfbool create_psa || (( ${#DB[@]} > 0 )); } && NET+=(servicenetworking.googleapis.com)

declare -A APIS
add() { local p="$1"; shift; APIS[$p]="${APIS[$p]:-} $*"; }
add "$PROJECT_ID"            "${BASE[@]}" compute.googleapis.com backupdr.googleapis.com cloudkms.googleapis.com dns.googleapis.com "${DB[@]}" "${NET[@]}"
add "$INFRA_PROD_PROJECT_ID" "${BASE[@]}" compute.googleapis.com backupdr.googleapis.com cloudkms.googleapis.com
add "$GCBDR_PROJECT_ID"      "${BASE[@]}" compute.googleapis.com backupdr.googleapis.com cloudkms.googleapis.com
add "$VAULT_PROJECT_ID"      "${BASE[@]}" compute.googleapis.com backupdr.googleapis.com
add "$DR_PROJECT_ID"         "${BASE[@]}" compute.googleapis.com backupdr.googleapis.com cloudkms.googleapis.com dns.googleapis.com "${DB[@]}" "${NET[@]}"
add "$HOST_PROJECT_ID"       "${BASE[@]}" compute.googleapis.com dns.googleapis.com "${NET[@]}"
[[ -n "$KMS_PROJECT_ID" ]] && add "$KMS_PROJECT_ID" "${BASE[@]}" cloudkms.googleapis.com

run() { echo "+ $*"; (( DRY_RUN )) || "$@"; }

echo "== Enabling APIs =="
for p in "${!APIS[@]}"; do
  # shellcheck disable=SC2206
  svcs=($(tr ' ' '\n' <<<"${APIS[$p]}" | sed '/^$/d' | sort -u))
  echo "-- $p (${#svcs[@]} services)"
  run gcloud services enable "${svcs[@]}" --project="$p"
done

echo "== Backup and DR service agents =="
for p in $(printf '%s\n' "$PROJECT_ID" "$GCBDR_PROJECT_ID" "$VAULT_PROJECT_ID" "$DR_PROJECT_ID" | sort -u); do
  run gcloud beta services identity create --service=backupdr.googleapis.com --project="$p" --format="value(email)" --quiet
done

echo "== Org policies that commonly affect this lab =="
for p in $(printf '%s\n' "${!APIS[@]}" | sort -u); do
  echo "-- $p"
  for c in compute.requireShieldedVm compute.vmExternalIpAccess compute.restrictVpcPeering \
           compute.restrictSharedVpcHostProjects compute.restrictSharedVpcSubnetworks \
           gcp.restrictCmekCryptoKeyProjects gcp.restrictNonCmekServices compute.storageResourceUseRestrictions; do
    out=$(timeout 30 gcloud org-policies describe "$c" --project="$p" --effective --format=json --quiet </dev/null 2>/dev/null \
      | jq -c '.spec.rules // [] | map(if .enforce != null then {enforce} elif .allowAll then "allowAll" elif .denyAll then "denyAll" else (.values // {}) end)' 2>/dev/null || echo "?")
    printf '   %-42s %s\n' "$c" "$out"
  done
done

echo
echo "Done. APIs can take a few minutes to propagate; Terraform also waits 180s (time_sleep.wait_for_apis)."
