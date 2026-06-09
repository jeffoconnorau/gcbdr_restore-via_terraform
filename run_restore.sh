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
echo "[INFO] Running terraform apply with -parallelism=$PARALLELISM"
terraform apply -parallelism="$PARALLELISM" "$@"
