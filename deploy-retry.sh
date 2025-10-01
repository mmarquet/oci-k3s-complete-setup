#!/bin/bash

# VM.Standard.A1.Flex Deployment Script - Modular and Idempotent
# Supports running full deployment or individual steps
# Oracle Cloud free tier A1 instances have limited capacity

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="$SCRIPT_DIR/logs/deployment.log"
SSH_KEY_NAME="oci_k3s_server"
SSH_PRIVATE_KEY="$HOME/.ssh/$SSH_KEY_NAME"
SSH_PUBLIC_KEY="$HOME/.ssh/$SSH_KEY_NAME.pub"
MAX_ATTEMPTS=3000  # 24 hours worth of attempts

# Default: run all steps
RUN_DEPLOY=true
RUN_RESIZE=true
RUN_K3S=true
RUN_SSH_ALIAS=true

# Source common functions
source "$SCRIPT_DIR/scripts/common-functions.sh"

# Parse command-line arguments
show_usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Modular OCI K3s deployment script. By default, runs all steps.

OPTIONS:
    --all               Run all steps (default)
    --deploy            Deploy VM only
    --resize            Resize VM only (requires existing instance)
    --k3s               Setup K3s only (requires running instance)
    --ssh-alias         Create SSH alias only
    --deploy-resize     Deploy and resize
    --deploy-resize-k3s Deploy, resize, and setup K3s
    --max-attempts N    Maximum deployment attempts (default: 3000)
    --help              Show this help message

EXAMPLES:
    # Full deployment (default)
    $0

    # Resume from stopped instance (will detect state and continue)
    $0

    # Only setup K3s on existing VM
    $0 --k3s

    # Deploy and resize only
    $0 --deploy-resize

    # Create SSH alias for existing instance
    $0 --ssh-alias
EOF
    exit 0
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h)
            show_usage
            ;;
        --all)
            RUN_DEPLOY=true
            RUN_RESIZE=true
            RUN_K3S=true
            RUN_SSH_ALIAS=true
            shift
            ;;
        --deploy)
            RUN_DEPLOY=true
            RUN_RESIZE=false
            RUN_K3S=false
            RUN_SSH_ALIAS=false
            shift
            ;;
        --resize)
            RUN_DEPLOY=false
            RUN_RESIZE=true
            RUN_K3S=false
            RUN_SSH_ALIAS=false
            shift
            ;;
        --k3s)
            RUN_DEPLOY=false
            RUN_RESIZE=false
            RUN_K3S=true
            RUN_SSH_ALIAS=false
            shift
            ;;
        --ssh-alias)
            RUN_DEPLOY=false
            RUN_RESIZE=false
            RUN_K3S=false
            RUN_SSH_ALIAS=true
            shift
            ;;
        --deploy-resize)
            RUN_DEPLOY=true
            RUN_RESIZE=true
            RUN_K3S=false
            RUN_SSH_ALIAS=false
            shift
            ;;
        --deploy-resize-k3s)
            RUN_DEPLOY=true
            RUN_RESIZE=true
            RUN_K3S=true
            RUN_SSH_ALIAS=false
            shift
            ;;
        --max-attempts)
            MAX_ATTEMPTS="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            show_usage
            ;;
    esac
done

cleanup() {
    log "Script interrupted. Cleaning up..." "WARN"
    exit 1
}

trap cleanup SIGINT SIGTERM

# Ensure logs directory exists
mkdir -p "$SCRIPT_DIR/logs"

log "=== OCI K3s Deployment Script ===" "INFO"
log "Steps enabled: Deploy=$RUN_DEPLOY, Resize=$RUN_RESIZE, K3s=$RUN_K3S, SSH=$RUN_SSH_ALIAS" "INFO"

# Setup SSH keys before starting
SSH_KEY=$(setup_ssh_keys "$SSH_KEY_NAME")
export SSH_KEY
export LOG_FILE

# Get compartment ID
COMPARTMENT_ID=$(get_compartment_id)
if [ -z "$COMPARTMENT_ID" ]; then
    log "Failed to get compartment ID" "ERROR"
    exit 1
fi

# Check if instance already exists
log "Checking for existing instance..." "INFO"
INSTANCE_DETAILS=$(get_instance_details "$COMPARTMENT_ID" "k3s-host")
INSTANCE_ID=$(echo "$INSTANCE_DETAILS" | jq -r '.id // empty')

if [ -n "$INSTANCE_ID" ] && [ "$INSTANCE_ID" != "null" ]; then
    INSTANCE_STATE=$(echo "$INSTANCE_DETAILS" | jq -r '."lifecycle-state" // empty')
    log "Found existing instance: $INSTANCE_ID (State: $INSTANCE_STATE)" "INFO"

    # If deploy step was requested but instance exists, skip to next steps
    if [ "$RUN_DEPLOY" = true ]; then
        log "Instance already exists, skipping deployment" "SUCCESS"
        RUN_DEPLOY=false
    fi

    # Get instance details
    PUBLIC_IP=$(get_instance_public_ip "$INSTANCE_ID")

    # Ensure instance is running if we need to do anything with it
    if [ "$RUN_RESIZE" = true ] || [ "$RUN_K3S" = true ] || [ "$RUN_SSH_ALIAS" = true ]; then
        if [ "$INSTANCE_STATE" != "RUNNING" ]; then
            log "Instance needs to be running for the requested operations" "WARN"
            ensure_instance_running "$INSTANCE_ID"
            PUBLIC_IP=$(get_instance_public_ip "$INSTANCE_ID")
        fi
    fi
fi

# Step 1: Deploy VM
if [ "$RUN_DEPLOY" = true ]; then
    log "=== Step 1: Deploying VM ===" "INFO"

    export MAX_DEPLOY_ATTEMPTS=$MAX_ATTEMPTS
    # Use temporary file to capture output while showing logs
    TEMP_OUTPUT=$(mktemp)
    if "$SCRIPT_DIR/scripts/1-deploy-vm.sh" | tee >(grep "^[A-Z_]*=" > "$TEMP_OUTPUT"); then
        log "VM deployment completed" "SUCCESS"
        # Parse output variables
        source "$TEMP_OUTPUT"
    else
        log "VM deployment failed" "ERROR"
        rm -f "$TEMP_OUTPUT"
        exit 1
    fi
    rm -f "$TEMP_OUTPUT"
fi

# Step 2: Resize VM
if [ "$RUN_RESIZE" = true ]; then
    log "=== Step 2: Resizing VM ===" "INFO"

    if [ -z "$INSTANCE_ID" ]; then
        log "No instance ID available for resize" "ERROR"
        exit 1
    fi

    TEMP_OUTPUT=$(mktemp)
    if "$SCRIPT_DIR/scripts/2-resize-vm.sh" "$INSTANCE_ID" | tee >(grep "^[A-Z_]*=" > "$TEMP_OUTPUT"); then
        log "VM resize completed" "SUCCESS"
        source "$TEMP_OUTPUT"
    else
        log "VM resize failed" "ERROR"
        rm -f "$TEMP_OUTPUT"
        exit 1
    fi
    rm -f "$TEMP_OUTPUT"
fi

# Step 3: Setup K3s
if [ "$RUN_K3S" = true ]; then
    log "=== Step 3: Setting up K3s ===" "INFO"

    if [ -z "$PUBLIC_IP" ] || [ -z "$SSH_KEY" ]; then
        log "Missing PUBLIC_IP or SSH_KEY for K3s setup" "ERROR"
        exit 1
    fi

    TEMP_OUTPUT=$(mktemp)
    if "$SCRIPT_DIR/scripts/3-setup-k3s.sh" "$PUBLIC_IP" "$SSH_KEY" | tee >(grep "^[A-Z_]*=" > "$TEMP_OUTPUT"); then
        log "K3s setup completed" "SUCCESS"
        source "$TEMP_OUTPUT"
    else
        log "K3s setup failed" "ERROR"
        rm -f "$TEMP_OUTPUT"
        exit 1
    fi
    rm -f "$TEMP_OUTPUT"
fi

# Step 4: Create SSH alias
if [ "$RUN_SSH_ALIAS" = true ]; then
    log "=== Step 4: Creating SSH alias ===" "INFO"

    if [ -z "$PUBLIC_IP" ] || [ -z "$SSH_KEY" ]; then
        log "Missing PUBLIC_IP or SSH_KEY for SSH alias" "ERROR"
        exit 1
    fi

    TEMP_OUTPUT=$(mktemp)
    if "$SCRIPT_DIR/scripts/4-create-ssh-alias.sh" "$PUBLIC_IP" "$SSH_KEY" "OCI-k3s" | tee >(grep "^[A-Z_]*=" > "$TEMP_OUTPUT"); then
        log "SSH alias created" "SUCCESS"
        source "$TEMP_OUTPUT"
    else
        log "SSH alias creation failed" "WARN"
    fi
    rm -f "$TEMP_OUTPUT"
fi

# Final summary
log "=== Deployment Complete ===" "SUCCESS"
if [ -n "$INSTANCE_ID" ]; then
    log "Instance ID: $INSTANCE_ID" "INFO"
fi
if [ -n "$PUBLIC_IP" ]; then
    log "Public IP: $PUBLIC_IP" "INFO"
fi
if [ -n "$ARGOCD_PASSWORD" ]; then
    DOMAIN_NAME=$(grep DOMAIN_NAME "$SCRIPT_DIR/k3s/.env" 2>/dev/null | cut -d'=' -f2 | tr -d '"' || echo "your-domain.com")
    log "ArgoCD URL: https://argocd.$DOMAIN_NAME" "INFO"
    log "ArgoCD Username: admin" "INFO"
    log "ArgoCD Password: $ARGOCD_PASSWORD" "INFO"
fi
if [ -n "$SSH_ALIAS" ]; then
    log "SSH Connection: ssh $SSH_ALIAS" "INFO"
fi

exit 0