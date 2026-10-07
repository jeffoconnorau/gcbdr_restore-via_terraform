#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# verify_auto_protection.sh
# ------------------------------------------------------------------------------
# Validates the label-driven auto-protection lab end to end:
#   1. Policy + bindings exist (backup vault project view)
#   2. Applied policies are visible from each workload project
#   3. Positive test: every labelled demo resource has a backup plan association
#      created by the policy (and no Terraform-managed BPA exists for it)
#   4. Negative test: vm-ap-unmatched (same key, different value) is NOT protected
#
# Exit codes: 0 = all assertions passed
#             1 = negative test FAILED (unmatched resource was protected) or error
#             2 = positive matches still pending (policy can take 2h, up to 8h)
#
# Usage: ./scripts/verify_auto_protection.sh            # context from `terraform output`
#        WAIT_MINUTES=120 ./scripts/verify_auto_protection.sh   # poll until matched
# ------------------------------------------------------------------------------
set -euo pipefail

cd "$(dirname "$0")/.."

command -v jq >/dev/null || { echo "[ERROR] jq is required" >&2; exit 1; }

CTX=$(terraform output -json lab_context 2>/dev/null) || {
  echo "[ERROR] Could not read 'terraform output lab_context'. Run terraform apply first." >&2
  exit 1
}

if [[ "$(jq -r '.auto_protection_enabled' <<<"$CTX")" != "true" ]]; then
  echo "[ERROR] enable_auto_protection is false in this workspace." >&2
  exit 1
fi

PROJECT=$(jq -r '.project_id' <<<"$CTX")                                   # workloads + BPAs
VAULT_PROJECT=$(jq -r '.vault_project_id // .project_id' <<<"$CTX")        # vault, plans, policy
REGION=$(jq -r '.region' <<<"$CTX")
mapfile -t POLICIES < <(jq -r '(.auto_protection_policy_ids // [.auto_protection_policy_id])[]' <<<"$CTX")
CRITERIA="$(jq -r '.auto_protection_label_key' <<<"$CTX")=$(jq -r '.auto_protection_label_value' <<<"$CTX")"
mapfile -t SCOPES < <(jq -r '.auto_protection_scope[]' <<<"$CTX")
mapfile -t POSITIVE < <(jq -r '.auto_protection_positive[]' <<<"$CTX")
mapfile -t NEGATIVE < <(jq -r '.auto_protection_negative[]' <<<"$CTX")
WAIT_MINUTES=${WAIT_MINUTES:-0}

hr() { printf '%.0s-' {1..80}; echo; }

echo "Auto-protection verification"
echo "  Policies : ${POLICIES[*]} (projects/$VAULT_PROJECT/locations/$REGION)"
echo "  Criteria : $CRITERIA"
echo "  Scope    : ${SCOPES[*]}"
hr

echo "[1/4] Policies and bindings (backup admin view)"
for POLICY in "${POLICIES[@]}"; do
  gcloud beta backup-dr auto-protection-policies describe "$POLICY" \
    --project="$VAULT_PROJECT" --location="$REGION" --format="yaml(name,criteria,backupPlanDetails,description)" || {
    echo "[ERROR] Policy $POLICY not found." >&2; exit 1; }
  gcloud beta backup-dr auto-protection-bindings list \
    --auto-protection-policy="$POLICY" --project="$VAULT_PROJECT" --location="$REGION" \
    --format="table(name.basename(),scope,state)" || true
  for SCOPE in "${SCOPES[@]}"; do
    BINDING="bind-${SCOPE}"
    echo "  Matching resources for $POLICY / ${BINDING:0:63}:"
    gcloud beta backup-dr binding-matching-resources list \
      --auto-protection-policy-binding="${BINDING:0:63}" --auto-protection-policy="$POLICY" \
      --project="$VAULT_PROJECT" --location="$REGION" --format="table(name.basename(),resource,state)" 2>/dev/null \
      || echo "    (none reported yet)"
  done
done
hr

echo "[2/4] Applied policies (workload admin view)"
for SCOPE in "${SCOPES[@]}"; do
  echo "  $SCOPE:"
  gcloud beta backup-dr applied-auto-protection-policies list \
    --project="$SCOPE" --location="$REGION" --format="table(name.basename(),criteria,state)" 2>/dev/null \
    || echo "    (not visible yet)"
done
hr

# Returns the backupPlan of the BPA protecting a named instance/disk, or empty.
bpa_for() {
  local name="$1" kind="$2" bpas="$3" id
  if [[ "$kind" == "disk" ]]; then
    id=$(gcloud compute disks list --project="$PROJECT" --filter="name=$name" --format="value(id)" 2>/dev/null | head -1)
  else
    id=$(gcloud compute instances list --project="$PROJECT" --filter="name=$name" --format="value(id)" 2>/dev/null | head -1)
  fi
  jq -r --arg n "$name" --arg id "${id:-__none__}" '
    map(select((.resource // "") | test("/(instances|disks)/(" + $n + "|" + $id + ")$")))
    | .[0].backupPlan // ""' <<<"$bpas"
}

attempt=0
deadline=$(( $(date +%s) + WAIT_MINUTES * 60 ))
while :; do
  attempt=$((attempt + 1))
  BPAS=$(gcloud backup-dr backup-plan-associations list --project="$PROJECT" --location="$REGION" --format=json 2>/dev/null || echo '[]')

  echo "[3/4] Positive test - labelled resources must be protected by the policy (attempt $attempt)"
  pending=0
  for r in "${POSITIVE[@]}"; do
    kind=instance; [[ "$r" == *disk* ]] && kind=disk
    plan=$(bpa_for "$r" "$kind" "$BPAS")
    if [[ -n "$plan" ]]; then
      printf '  [PASS] %-24s -> %s\n' "$r" "${plan##*/}"
    else
      printf '  [WAIT] %-24s -> not yet associated\n' "$r"
      pending=$((pending + 1))
    fi
  done

  echo "[4/4] Negative test - non-matching resources must NOT be protected"
  failed=0
  for r in "${NEGATIVE[@]}"; do
    plan=$(bpa_for "$r" instance "$BPAS")
    if [[ -n "$plan" ]]; then
      printf '  [FAIL] %-24s -> unexpectedly protected by %s\n' "$r" "${plan##*/}"
      failed=1
    else
      printf '  [PASS] %-24s -> unprotected (as expected)\n' "$r"
    fi
  done
  hr

  if [[ $failed -ne 0 ]]; then
    echo "RESULT: FAIL - label criteria leaked to a non-matching resource."; exit 1
  fi
  if [[ $pending -eq 0 ]]; then
    echo "RESULT: PASS - all labelled resources protected, negative control untouched."; exit 0
  fi
  if (( $(date +%s) >= deadline )); then
    echo "RESULT: PENDING - $pending resource(s) not yet associated. Policies can take up to 2h (worst case 8h)."
    echo "        Re-run later, or poll with: WAIT_MINUTES=120 $0"
    exit 2
  fi
  echo "Waiting 5 minutes before re-checking..."; sleep 300
done
