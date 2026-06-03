#!/bin/bash
# Wrapper script to run Terraform apply with the parallelism level defined in terraform.tfvars

# Parse the parallelism variable from terraform.tfvars (defaults to 30 if not found)
PARALLELISM=$(grep -E '^\s*parallelism\s*=' terraform.tfvars 2>/dev/null | awk -F '=' '{print $2}' | tr -d ' "[:space:]')
PARALLELISM=${PARALLELISM:-30}

echo "[INFO] Running terraform apply with -parallelism=$PARALLELISM"
terraform apply -parallelism="$PARALLELISM" "$@"
