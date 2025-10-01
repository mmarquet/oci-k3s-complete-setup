#!/bin/bash

# K3s Setup Module
# Installs and configures K3s cluster on the remote VM
# Idempotent: Checks if K3s is already installed before proceeding

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
LOG_FILE="${LOG_FILE:-$PROJECT_DIR/logs/deployment.log}"

# Source common functions
source "$SCRIPT_DIR/common-functions.sh"

log "=== K3s Setup Module ===" "INFO"

# Get parameters
PUBLIC_IP="${1:-$PUBLIC_IP}"
SSH_KEY="${2:-$SSH_KEY}"

if [ -z "$PUBLIC_IP" ] || [ -z "$SSH_KEY" ]; then
    log "Error: PUBLIC_IP and SSH_KEY are required" "ERROR"
    log "Usage: $0 <public-ip> <ssh-key-path>" "ERROR"
    exit 1
fi

log "Target VM: ubuntu@$PUBLIC_IP" "INFO"
log "SSH Key: $SSH_KEY" "INFO"

# Check if k3s/.env file exists
if [ ! -f "$PROJECT_DIR/k3s/.env" ]; then
    log "ERROR: k3s/.env file not found!" "ERROR"
    log "Please copy k3s/.env.template to k3s/.env and fill in your values:" "WARN"
    log "  cp k3s/.env.template k3s/.env" "WARN"
    exit 1
fi

# Wait for SSH to be ready
if ! wait_for_ssh "$PUBLIC_IP" "$SSH_KEY" 30; then
    log "SSH not available" "ERROR"
    exit 1
fi

# Check if K3s is already installed
log "Checking if K3s is already installed..." "INFO"
if check_k3s_installed "$PUBLIC_IP" "$SSH_KEY"; then
    log "K3s is already installed, checking cluster health..." "INFO"

    # Check if cluster is healthy
    if ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ubuntu@"$PUBLIC_IP" \
        "sudo k3s kubectl get nodes --no-headers 2>/dev/null | grep -q Ready" 2>/dev/null; then
        log "K3s cluster is healthy and ready" "SUCCESS"

        # Get ArgoCD password if available
        ARGOCD_PASSWORD=$(ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ubuntu@"$PUBLIC_IP" \
            "sudo k3s kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null" || echo "")

        if [ -n "$ARGOCD_PASSWORD" ]; then
            log "ArgoCD is fully configured, nothing to do" "SUCCESS"
            echo "K3S_INSTALLED=true"
            echo "K3S_ALREADY_CONFIGURED=true"
            echo "ARGOCD_PASSWORD=$ARGOCD_PASSWORD"
            exit 0
        else
            log "K3s installed but ArgoCD not found, will run full setup" "WARN"
            # Don't exit - continue with full setup below
        fi
    else
        log "K3s is installed but cluster is not healthy, will attempt reinstall" "WARN"
    fi
else
    log "K3s is not installed" "INFO"
fi

# Copy setup files to VM
log "Copying setup files to VM..." "INFO"
if scp -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    "$PROJECT_DIR/post-deployment-setup.sh" ubuntu@"$PUBLIC_IP":~/ 2>&1 | tee -a "$LOG_FILE" && \
   scp -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -r \
    "$PROJECT_DIR/k3s/" ubuntu@"$PUBLIC_IP":~/ 2>&1 | tee -a "$LOG_FILE"; then
    log "Files copied successfully" "SUCCESS"
else
    log "Failed to copy files" "ERROR"
    exit 1
fi

# Run K3s setup on VM
log "Running K3s setup on VM (this may take 10-15 minutes)..." "INFO"
log "You can monitor progress in real-time..." "INFO"

if ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ubuntu@"$PUBLIC_IP" \
    "chmod +x ./post-deployment-setup.sh && ./post-deployment-setup.sh" 2>&1 | tee -a "$LOG_FILE"; then
    log "K3s cluster setup completed successfully!" "SUCCESS"

    # Get ArgoCD password
    log "Retrieving ArgoCD credentials..." "INFO"
    ARGOCD_PASSWORD=$(ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ubuntu@"$PUBLIC_IP" \
        "sudo k3s kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null" || echo "")

    if [ -n "$ARGOCD_PASSWORD" ]; then
        log "ArgoCD password retrieved" "SUCCESS"
        echo "K3S_INSTALLED=true"
        echo "K3S_SETUP_COMPLETED=true"
        echo "ARGOCD_PASSWORD=$ARGOCD_PASSWORD"
        exit 0
    else
        log "Warning: Could not retrieve ArgoCD password" "WARN"
        echo "K3S_INSTALLED=true"
        echo "K3S_SETUP_COMPLETED=true"
        exit 0
    fi
else
    log "K3s setup failed. Check logs above for details." "ERROR"
    exit 1
fi
