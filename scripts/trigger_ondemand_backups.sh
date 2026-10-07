#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# trigger_ondemand_backups.sh
# ------------------------------------------------------------------------------
# Triggers an on-demand backup for every backup plan association (BPA) in the
# lab's workload projects, so you can run a DR drill immediately instead of
# waiting for the scheduled backup window. Covers Terraform-managed BPAs AND
# BPAs created by auto-protection policies.
#
# Usage:
#   ./scripts/trigger_ondemand_backups.sh                 # all BPAs, projects from terraform output
#   ./scripts/trigger_ondemand_backups.sh -m vm-ap        # only BPAs whose resource matches 'vm-ap'
#   ./scripts/trigger_ondemand_backups.sh -n              # dry run
#   ./scripts/trigger_ondemand_backups.sh -p proj-a -p proj-b -r asia-southeast1
#   ./scripts/trigger_ondemand_backups.sh -d 7            # custom retention (days) instead of rule retention
# ------------------------------------------------------------------------------
set -euo pipefail

cd "$(dirname "$0")/.."

PROJECTS=()
REGION=""
MATCH=""
DRY_RUN=0
CUSTOM_RETENTION=""

while getopts "p:r:m:d:nh" opt; do
  case $opt in
    p) PROJECTS+=("$OPTARG") ;;
    r) REGION="$OPTARG" ;;
    m) MATCH="$OPTARG" ;;
    d) CUSTOM_RETENTION="$OPTARG" ;;
    n) DRY_RUN=1 ;;
    h|*) sed -n '2,17p' "$0"; exit 0 ;;
  esac
done

if [[ ${#PROJECTS[@]} -eq 0 || -z "$REGION" ]]; then
  CTX=$(terraform output -json lab_context 2>/dev/null) || {
    echo "[ERROR] Pass -p/-r or run terraform apply so 'lab_context' output exists." >&2; exit 1; }
  [[ -z "$REGION" ]] && REGION=$(jq -r '.region' <<<"$CTX")
  if [[ ${#PROJECTS[@]} -eq 0 ]]; then
    mapfile -t PROJECTS < <(jq -r '[.project_id, .infra_prod_project_id] + (.auto_protection_scope // []) | unique | .[]' <<<"$CTX")
  fi
fi

echo "Triggering on-demand backups in region $REGION for: ${PROJECTS[*]}"
[[ $DRY_RUN -eq 1 ]] && echo "(dry run)"

total=0
for PROJECT in "${PROJECTS[@]}"; do
  BPAS=$(gcloud backup-dr backup-plan-associations list --project="$PROJECT" --location="$REGION" --format=json 2>/dev/null || echo '[]')
  # Unit separator (non-whitespace) so empty fields are not collapsed by read
  while IFS=$'\x1f' read -r NAME RESOURCE RULE PLAN; do
    [[ -z "$NAME" ]] && continue
    [[ -n "$MATCH" && "$RESOURCE" != *"$MATCH"* && "$NAME" != *"$MATCH"* ]] && continue

    if [[ -z "$RULE" || "$RULE" == "null" ]]; then
      # Fall back to the first rule defined on the backup plan
      RULE=$(gcloud backup-dr backup-plans describe "$PLAN" --format="value(backupRules[0].ruleId)" 2>/dev/null || true)
    fi

    ARGS=("$NAME")
    if [[ -n "$CUSTOM_RETENTION" ]]; then
      ARGS+=(--custom-retention-days="$CUSTOM_RETENTION")
    elif [[ -n "$RULE" ]]; then
      ARGS+=(--backup-rule-id="$RULE")
    fi

    printf '  %-60s rule=%-16s %s\n' "${NAME##*/}" "${RULE:-n/a}" "${RESOURCE##*/}"
    total=$((total + 1))
    if [[ $DRY_RUN -eq 0 ]]; then
      gcloud backup-dr backup-plan-associations trigger-backup "${ARGS[@]}" --async --quiet >/dev/null \
        || echo "    [WARN] trigger failed for ${NAME##*/}"
    fi
  done < <(jq -r '.[] | [.name, (.resource // ""), (.rulesConfigInfo[0].ruleId // ""), (.backupPlan // "")] | join("\u001f")' <<<"$BPAS")
done

echo "Done: $total backup(s) $( [[ $DRY_RUN -eq 1 ]] && echo 'would be' ) triggered."
echo "Monitor: Backup and DR > Jobs in the console, or 'gcloud backup-dr operations list --project=<workload-project> --location=$REGION' (operations are created in the BPA's project)"
