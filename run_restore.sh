#!/bin/bash
# Wrapper script to run Terraform apply with the parallelism level defined in terraform.tfvars

# Parse the parallelism variable from terraform.tfvars (defaults to 30 if not found)
PARALLELISM=$(grep -E '^\s*parallelism\s*=' terraform.tfvars 2>/dev/null | awk -F '=' '{print $2}' | tr -d ' "[:space:]')
PARALLELISM=${PARALLELISM:-30}

echo "================================================================================"
echo "[IMPORTANT REMINDER]: Two-Phase Apply Lifecycle for DR Restoration Testing"
echo "================================================================================"
echo "When activating perform_dr_test = true for the first time in a new project:"
echo "  1st Pass: Binds cross-project IAM privileges like restoreUser and alloydb.admin."
echo "            Dynamic backup lookups output dummy while pending IAM propagation."
echo "  2nd Pass: Authenticates with granted IAM, locates real recovery points,"
echo "            and actively provisions restored workloads like AlloyDB, VMs, and SQL."
echo ""
echo "  [TIMING NOTICE]: Google Cloud IAM cross-project replication can take up to"
echo "                   5 MINUTES to fully propagate new role bindings."
echo "                   Please pause for ~5 minutes after Pass 1 before running Pass 2."
echo ""
echo "If workloads report No changes on pass 1, re-run this script to execute pass 2."
echo "================================================================================"
echo ""
# This wrapper exists to run the DR drill, so enable it unless the caller
# explicitly set perform_dr_test (terraform.tfvars normally keeps it false for
# the base/backup phase).
EXTRA_ARGS=()
DR_ACTIVE=0
if [[ "$*" != *"perform_dr_test"* ]]; then
  EXTRA_ARGS+=("-var=perform_dr_test=true")
  DR_ACTIVE=1
  echo "[INFO] Adding -var=perform_dr_test=true (pass -var=perform_dr_test=false to override)"
elif [[ "$*" == *"perform_dr_test=true"* ]]; then
  DR_ACTIVE=1
fi

echo "[INFO] Running terraform apply with -parallelism=$PARALLELISM"
START_EPOCH=$(date +%s)

# Pipe output to log file and preserve exit status of terraform
terraform apply -parallelism="$PARALLELISM" "${EXTRA_ARGS[@]}" "$@" 2>&1 | tee terraform_apply.log
APPLY_STATUS=${PIPESTATUS[0]}

# Restored workloads currently in state (empty on pass 1 while IAM propagates)
RESTORED=$(terraform state list 2>/dev/null | grep -cE '^(google_backup_dr_restore_workload\.|google_sql_database_instance\.restored_|google_filestore_instance\.restored_|terraform_data\.restored_alloydb_cluster|google_alloydb_instance\.restored_)' || true)

if [[ $APPLY_STATUS -eq 0 ]] && [[ $DR_ACTIVE -eq 1 ]] && [[ "$*" != *"-destroy"* ]] && [[ "${RESTORED:-0}" -eq 0 ]]; then
  echo ""
  echo "========================================================================="
  echo "[PASS 1 COMPLETE] No restored workloads yet - skipping DR report."
  echo "  Cross-project IAM / recovery-point discovery is still settling."
  echo "  Wait ~5 minutes, then re-run: ./run_restore.sh $*"
  echo "========================================================================="
fi

# Compile report on successful apply that actually restored something
if [[ $DR_ACTIVE -eq 1 ]] && [[ "$*" != *"-destroy"* ]] && [[ "$*" != *"plan"* ]] && [[ $APPLY_STATUS -eq 0 ]] && [[ "${RESTORED:-0}" -gt 0 ]]; then
  echo ""
  echo "========================================================================="
  echo "Step 2: Compiling Automated DR Drill Verification Report..."
  echo "========================================================================="
  echo "Waiting 5 seconds for telemetry logs to settle..."
  sleep 5
  python3 scripts/generate_report.py "$START_EPOCH" "$(date +%s)" "terraform_apply.log"
fi

exit "$APPLY_STATUS"
