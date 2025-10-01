#!/bin/bash

# VM Deployment Module
# Deploys OCI VM.Standard.A1.Flex instance using Terraform
# Idempotent: Checks if instance exists before deploying

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
LOG_FILE="${LOG_FILE:-$PROJECT_DIR/logs/deployment.log}"

# Source common functions
source "$SCRIPT_DIR/common-functions.sh"

# Configuration
TERRAFORM_DIR="$PROJECT_DIR/terraform"
INSTANCE_NAME="k3s-host"
MAX_DEPLOY_ATTEMPTS="${MAX_DEPLOY_ATTEMPTS:-1}"

# Change to terraform directory
cd "$TERRAFORM_DIR"

log "=== VM Deployment Module ===" "INFO"

# Initialize Terraform if needed
if [ ! -d ".terraform" ]; then
    log "Initializing Terraform..." "INFO"
    terraform init
fi

# Get compartment ID
COMPARTMENT_ID=$(get_compartment_id)
if [ -z "$COMPARTMENT_ID" ]; then
    log "Failed to get compartment ID" "ERROR"
    exit 1
fi

log "Using compartment: $COMPARTMENT_ID" "INFO"

# Check if instance already exists
log "Checking for existing instance..." "INFO"
INSTANCE_DETAILS=$(get_instance_details "$COMPARTMENT_ID" "$INSTANCE_NAME")
INSTANCE_ID=$(echo "$INSTANCE_DETAILS" | jq -r '.id // empty')

if [ -n "$INSTANCE_ID" ] && [ "$INSTANCE_ID" != "null" ]; then
    INSTANCE_STATE=$(echo "$INSTANCE_DETAILS" | jq -r '."lifecycle-state" // empty')
    log "Instance already exists: $INSTANCE_ID (State: $INSTANCE_STATE)" "SUCCESS"

    # Ensure instance is running
    if [ "$INSTANCE_STATE" != "RUNNING" ]; then
        log "Instance is not running, attempting to start..." "WARN"
        ensure_instance_running "$INSTANCE_ID"
    fi

    # Get instance details
    PUBLIC_IP=$(get_instance_public_ip "$INSTANCE_ID")
    SHAPE_CONFIG=$(get_instance_shape_config "$INSTANCE_ID")

    log "Instance is ready!" "SUCCESS"
    log "  Instance ID: $INSTANCE_ID" "INFO"
    log "  Public IP: $PUBLIC_IP" "INFO"
    log "  Shape: $(echo "$SHAPE_CONFIG" | jq -r '.ocpus // "N/A"') OCPU, $(echo "$SHAPE_CONFIG" | jq -r '."memory-in-gbs" // "N/A"') GB RAM" "INFO"

    # Output for use by other scripts
    echo "INSTANCE_ID=$INSTANCE_ID"
    echo "PUBLIC_IP=$PUBLIC_IP"
    echo "INSTANCE_STATE=$INSTANCE_STATE"

    exit 0
fi

# Instance doesn't exist, deploy it
log "No existing instance found, deploying new instance..." "INFO"

ATTEMPT=1
while [ $ATTEMPT -le $MAX_DEPLOY_ATTEMPTS ]; do
    log "Deployment attempt $ATTEMPT of $MAX_DEPLOY_ATTEMPTS" "INFO"

    if terraform apply -auto-approve 2>&1 | tee -a "$LOG_FILE"; then
        # Check if the apply was successful
        if terraform show -json 2>/dev/null | jq -e '.values.root_module.resources[] | select(.type == "oci_core_instance")' > /dev/null 2>&1; then
            log "VM deployed successfully!" "SUCCESS"

            # Get instance details from Terraform
            INSTANCE_ID=$(terraform output -raw instance_id 2>/dev/null)
            PUBLIC_IP=$(terraform output -raw instance_public_ip 2>/dev/null || echo "NOT_AVAILABLE")
            INSTANCE_STATE=$(terraform output -raw instance_state 2>/dev/null || echo "UNKNOWN")

            log "Instance details:" "SUCCESS"
            log "  Instance ID: $INSTANCE_ID" "INFO"
            log "  Public IP: $PUBLIC_IP" "INFO"
            log "  State: $INSTANCE_STATE" "INFO"

            # Output for use by other scripts
            echo "INSTANCE_ID=$INSTANCE_ID"
            echo "PUBLIC_IP=$PUBLIC_IP"
            echo "INSTANCE_STATE=$INSTANCE_STATE"

            exit 0
        fi
    fi

    # Check the error message
    if grep -q -i "out of capacity\|no available capacity\|insufficient capacity\|service limit\|shape VM.Standard.A1.Flex not available" "$LOG_FILE"; then
        log "Capacity not available. Will retry..." "ERROR"
    elif grep -q -i "limit exceeded\|quota exceeded" "$LOG_FILE"; then
        log "Quota/limit exceeded. Will retry..." "ERROR"
    else
        log "Deployment failed for unknown reason. Check the log above." "ERROR"
    fi

    # Clean up any partial resources
    if [ $ATTEMPT -lt $MAX_DEPLOY_ATTEMPTS ]; then
        log "Cleaning up any partial resources..." "WARN"
        terraform destroy -auto-approve >/dev/null 2>&1 || true

        log "Waiting 2 minutes before next attempt..." "INFO"
        sleep 120
    fi

    ATTEMPT=$((ATTEMPT + 1))
done

log "Failed to deploy after $MAX_DEPLOY_ATTEMPTS attempts" "ERROR"
exit 1
