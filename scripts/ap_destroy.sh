#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# Destroy-time helper for auto-protection (called from auto_protection.tf).
#
# Auto-protection teardown is asynchronous and strictly ordered:
#   1. binding delete  -> binding goes DELETION_INITIATED, the service unwinds the
#                         policy-managed BackupPlanAssociations, then the binding
#                         disappears.
#   2. policy delete   -> rejected with POLICY_IN_USE_BY_BINDING until (1) is done.
#   3. backup plan     -> rejected with BACKUP_PLAN_ASSOCIATIONS_EXIST until every
#                         policy-managed BPA is gone. Policy-managed BPAs CANNOT be
#                         deleted directly while the policy owns them.
#
# This script blocks (with timeout) at each step so `terraform destroy` succeeds
# in a single pass. On timeout it exits non-zero; the terraform_data stays in
# state and re-running `terraform destroy` resumes idempotently.
#
# Usage:
#   ap_destroy.sh binding <project> <location> <policy_id> <binding_id>
#   ap_destroy.sh policy  <project> <location> <policy_id> <plan_name> <scope_csv>
#
# Env: AP_DESTROY_TIMEOUT_SECONDS (default 3600), AP_POLL_SECONDS (default 30)
# ------------------------------------------------------------------------------
set -uo pipefail

TIMEOUT="${AP_DESTROY_TIMEOUT_SECONDS:-3600}"
POLL="${AP_POLL_SECONDS:-30}"

log() { echo "[ap-destroy] $*"; }
die() { echo "[ap-destroy][ERROR] $*" >&2; exit 1; }

# describe wrapper: prints state; rc 0=exists, 3=not found, 1=other error.
ap_describe() {
  local out rc
  out=$("$@" --format='value(state)' 2>&1); rc=$?
  if [[ $rc -eq 0 ]]; then echo "${out:-UNKNOWN}"; return 0; fi
  if grep -qiE 'NOT_FOUND|not found|does not exist' <<<"$out"; then return 3; fi
  echo "$out" >&2; return 1
}

wait_until_gone() { # <label> <describe cmd...>
  local label=$1; shift
  local deadline=$((SECONDS + TIMEOUT)) state rc
  while :; do
    state=$(ap_describe "$@"); rc=$?
    [[ $rc -eq 3 ]] && { log "$label deleted."; return 0; }
    [[ $rc -ne 0 ]] && die "Could not describe $label (see error above)."
    (( SECONDS >= deadline )) && die "$label still present (state=$state) after ${TIMEOUT}s. Re-run 'terraform destroy' later (or raise AP_DESTROY_TIMEOUT_SECONDS)."
    log "$label state=$state - waiting ${POLL}s..."
    sleep "$POLL"
  done
}

mode=${1:-}; shift || true
case "$mode" in
  binding)
    [[ $# -eq 4 ]] || die "usage: binding <project> <location> <policy_id> <binding_id>"
    project=$1 location=$2 policy=$3 binding=$4
    D=(gcloud beta backup-dr auto-protection-bindings describe "$binding"
       --auto-protection-policy="$policy" --project="$project" --location="$location")
    state=$(ap_describe "${D[@]}"); rc=$?
    [[ $rc -eq 3 ]] && { log "Binding $binding already gone."; exit 0; }
    [[ $rc -ne 0 ]] && die "Could not describe binding $binding."
    if [[ "$state" != "DELETION_INITIATED" ]]; then
      log "Deleting binding $binding (policy $policy)."
      gcloud beta backup-dr auto-protection-bindings delete "$binding" \
        --auto-protection-policy="$policy" --project="$project" --location="$location" --quiet \
        || die "Binding delete failed."
    fi
    wait_until_gone "binding $policy/$binding" "${D[@]}"
    ;;

  policy)
    [[ $# -eq 5 ]] || die "usage: policy <project> <location> <policy_id> <plan_name> <scope_csv>"
    project=$1 location=$2 policy=$3 plan=$4 scopes=$5
    D=(gcloud beta backup-dr auto-protection-policies describe "$policy"
       --project="$project" --location="$location")
    deadline=$((SECONDS + TIMEOUT))
    while :; do
      state=$(ap_describe "${D[@]}"); rc=$?
      [[ $rc -eq 3 ]] && { log "Policy $policy gone."; break; }
      [[ $rc -ne 0 ]] && die "Could not describe policy $policy."
      out=$(gcloud beta backup-dr auto-protection-policies delete "$policy" \
              --project="$project" --location="$location" --quiet 2>&1) && continue
      if grep -q POLICY_IN_USE_BY_BINDING <<<"$out"; then
        (( SECONDS >= deadline )) && die "Policy $policy still has bindings after ${TIMEOUT}s. Re-run 'terraform destroy' later."
        log "Policy $policy still in use by a binding - waiting ${POLL}s..."
        sleep "$POLL"
      else
        echo "$out" >&2; die "Policy delete failed."
      fi
    done

    # Drain policy-managed BPAs so the backup plan can be deleted next.
    IFS=',' read -r -a scope_list <<<"$scopes"
    deadline=$((SECONDS + TIMEOUT))
    while :; do
      remaining=()
      for sp in "${scope_list[@]}"; do
        mapfile -t found < <(gcloud backup-dr backup-plan-associations list \
          --project="$sp" --location="$location" \
          --filter="backupPlan~/backupPlans/${plan}\$" --format='value(name)' 2>/dev/null)
        for f in "${found[@]}"; do [[ -n "$f" ]] && remaining+=("$f"); done
      done
      [[ ${#remaining[@]} -eq 0 ]] && { log "No BPAs reference $plan - backup plan can be deleted."; break; }
      (( SECONDS >= deadline )) && die "${#remaining[@]} BPA(s) still reference $plan after ${TIMEOUT}s: ${remaining[*]}. Re-run 'terraform destroy' later."
      # Once the policy is gone the BPAs are normally released; try a direct
      # delete in case they were left behind as regular associations.
      for bpa in "${remaining[@]}"; do
        gcloud backup-dr backup-plan-associations delete "$bpa" --quiet --async >/dev/null 2>&1 || true
      done
      log "${#remaining[@]} BPA(s) still reference $plan - waiting ${POLL}s..."
      sleep "$POLL"
    done
    ;;

  *) die "unknown mode '$mode' (expected binding|policy)";;
esac
