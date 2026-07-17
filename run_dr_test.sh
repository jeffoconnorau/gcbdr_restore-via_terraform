#!/bin/bash
set -e

# =========================================================================
# GCBDR Automated DR restoration verification wrapper
# =========================================================================

show_help() {
    echo "Usage: $0 [options]"
    echo ""
    echo "Options:"
    echo "  --apply       Execute the DR restoration plan and generate a compliance report."
    echo "  --destroy     Destroy all restored DR workloads and clean the workspace."
    echo "  --help        Show this help message."
    echo ""
    echo "Without options, the script will show a dry-run plan."
}

ACTION="plan"
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --apply) ACTION="apply"; shift ;;
        --destroy) ACTION="destroy"; shift ;;
        --help) show_help; exit 0 ;;
        *) echo "Unknown parameter: $1"; show_help; exit 1 ;;
    esac
done

# Read parallelism parameter
PARALLELISM=$(grep -E '^\s*parallelism\s*=' terraform.tfvars 2>/dev/null | awk -F '=' '{print $2}' | tr -d ' "[:space:]')
PARALLELISM=${PARALLELISM:-30}

case $ACTION in
    plan)
        echo "========================================================================="
        echo "Step 1: Generating DR dry-run plan..."
        echo "========================================================================="
        terraform plan -parallelism="$PARALLELISM"
        ;;
        
    apply)
        echo "========================================================================="
        echo "Step 1: Initiating Disaster Recovery Restoration Drill..."
        echo "========================================================================="
        START_EPOCH=$(date +%s)
        
        # Execute the apply wrapper
        ./run_restore.sh -auto-approve
        
        echo "========================================================================="
        echo "Step 2: Compiling Automated DR Drill Verification Report..."
        echo "========================================================================="
        echo "Waiting 5 seconds for telemetry logs to settle..."
        sleep 5
        
        # Compile report
        python3 scripts/generate_report.py "$START_EPOCH"
        ;;
        
    destroy)
        echo "========================================================================="
        echo "Step 1: Destroying restored DR test workloads..."
        echo "========================================================================="
        terraform destroy -parallelism="$PARALLELISM" -auto-approve
        ;;
esac
