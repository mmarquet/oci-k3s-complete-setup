#!/bin/bash

# SSH Alias Creation Module
# Creates an SSH config entry for easy access to the VM
# Idempotent: Updates existing entry if present

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
LOG_FILE="${LOG_FILE:-$PROJECT_DIR/logs/deployment.log}"

# Source common functions
source "$SCRIPT_DIR/common-functions.sh"

log "=== SSH Alias Creation Module ===" "INFO"

# Get parameters
PUBLIC_IP="${1:-$PUBLIC_IP}"
SSH_KEY="${2:-$SSH_KEY}"
ALIAS_NAME="${3:-OCI-k3s}"

if [ -z "$PUBLIC_IP" ] || [ -z "$SSH_KEY" ]; then
    log "Error: PUBLIC_IP and SSH_KEY are required" "ERROR"
    log "Usage: $0 <public-ip> <ssh-key-path> [alias-name]" "ERROR"
    exit 1
fi

log "Creating SSH alias: $ALIAS_NAME" "INFO"
log "  Host: $PUBLIC_IP" "INFO"
log "  Key: $SSH_KEY" "INFO"

SSH_CONFIG="$HOME/.ssh/config"

# Ensure SSH config exists
touch "$SSH_CONFIG"
chmod 600 "$SSH_CONFIG"

# Check if alias already exists
if grep -q "^Host $ALIAS_NAME$" "$SSH_CONFIG" 2>/dev/null; then
    log "SSH alias '$ALIAS_NAME' already exists, updating..." "WARN"

    # Remove existing entry (including all lines until next Host or EOF)
    sed -i "/^Host $ALIAS_NAME$/,/^Host \|^$/{ /^Host $ALIAS_NAME$/d; /^Host /! { /^$/!d; }; }" "$SSH_CONFIG"
fi

# Add new SSH config entry
cat >> "$SSH_CONFIG" << EOF

Host $ALIAS_NAME
    HostName $PUBLIC_IP
    User ubuntu
    IdentityFile $SSH_KEY
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
EOF

log "SSH alias created successfully" "SUCCESS"
log "You can now connect with: ssh $ALIAS_NAME" "SUCCESS"

echo "SSH_ALIAS=$ALIAS_NAME"
echo "SSH_ALIAS_CREATED=true"

exit 0
