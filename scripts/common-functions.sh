#!/bin/bash

# Common functions for OCI K3s deployment scripts
# Source this file in other scripts with: source "$(dirname "$0")/common-functions.sh"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging function
log() {
    local level="${2:-INFO}"
    local color="$NC"
    case "$level" in
        ERROR) color="$RED" ;;
        SUCCESS) color="$GREEN" ;;
        WARN) color="$YELLOW" ;;
        INFO) color="$BLUE" ;;
    esac
    # Write to stderr to avoid polluting function return values
    echo -e "$(date '+%Y-%m-%d %H:%M:%S') - ${color}$1${NC}" | tee -a "${LOG_FILE:-/dev/null}" >&2
}

# Get compartment ID from Terraform or OCI config
get_compartment_id() {
    local compartment_id=""
    local script_dir="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

    # Try to get from Terraform tfvars (both compartment_id and compartment_ocid)
    if [ -f "$script_dir/terraform/terraform.tfvars" ]; then
        compartment_id=$(grep -E "^compartment_id\s*=" "$script_dir/terraform/terraform.tfvars" | cut -d'"' -f2)
        if [ -z "$compartment_id" ]; then
            compartment_id=$(grep -E "^compartment_ocid\s*=" "$script_dir/terraform/terraform.tfvars" | cut -d'"' -f2)
        fi
    fi

    # Fallback to tenancy OCID if still empty
    if [ -z "$compartment_id" ] && [ -f "$script_dir/terraform/terraform.tfvars" ]; then
        compartment_id=$(grep -E "^tenancy_ocid\s*=" "$script_dir/terraform/terraform.tfvars" | cut -d'"' -f2)
    fi

    # Last fallback to OCI config
    if [ -z "$compartment_id" ]; then
        compartment_id=$(oci iam compartment list --query 'data[0]."compartment-id"' --raw-output 2>/dev/null || echo "")
    fi

    echo "$compartment_id"
}

# Check if instance exists and get its details
get_instance_details() {
    local compartment_id="$1"
    local instance_name="${2:-k3s-host}"

    oci compute instance list \
        --compartment-id "$compartment_id" \
        --display-name "$instance_name" \
        --query 'data[0]' \
        --output json 2>/dev/null || echo "{}"
}

# Get instance state
get_instance_state() {
    local instance_id="$1"

    oci compute instance get \
        --instance-id "$instance_id" \
        --query 'data."lifecycle-state"' \
        --raw-output 2>/dev/null || echo "NOT_FOUND"
}

# Get instance shape config
get_instance_shape_config() {
    local instance_id="$1"

    oci compute instance get \
        --instance-id "$instance_id" \
        --query 'data."shape-config"' \
        --output json 2>/dev/null || echo "{}"
}

# Start instance if stopped
ensure_instance_running() {
    local instance_id="$1"
    local current_state=$(get_instance_state "$instance_id")

    case "$current_state" in
        RUNNING)
            log "Instance is already RUNNING" "SUCCESS"
            return 0
            ;;
        STOPPED)
            log "Instance is STOPPED, starting..." "WARN"
            local start_attempts=0
            local max_start_attempts=5
            while [ $start_attempts -lt $max_start_attempts ]; do
                if oci compute instance action --instance-id "$instance_id" --action START --wait-for-state RUNNING --max-wait-seconds 300 2>&1 | tee -a "${LOG_FILE:-/dev/null}"; then
                    local new_state=$(get_instance_state "$instance_id")
                    if [ "$new_state" = "RUNNING" ]; then
                        log "Instance started successfully" "SUCCESS"
                        return 0
                    fi
                fi

                start_attempts=$((start_attempts + 1))
                if [ $start_attempts -lt $max_start_attempts ]; then
                    log "Start attempt $start_attempts failed, waiting 15 seconds before retry..." "WARN"
                    sleep 15
                fi
            done

            log "Failed to start instance after $max_start_attempts attempts" "ERROR"
            return 1
            ;;
        *)
            log "Instance is in state: $current_state (cannot start)" "ERROR"
            return 1
            ;;
    esac
}

# Get instance public IP
get_instance_public_ip() {
    local instance_id="$1"

    # Get the public IP directly from list-vnics
    local public_ip=$(oci compute instance list-vnics \
        --instance-id "$instance_id" \
        --query 'data[0]."public-ip"' \
        --raw-output 2>/dev/null)

    if [ -z "$public_ip" ] || [ "$public_ip" = "null" ]; then
        echo "NOT_AVAILABLE"
        return 0
    fi

    echo "$public_ip"
    return 0
}

# Check if SSH is ready
wait_for_ssh() {
    local public_ip="$1"
    local ssh_key="$2"
    local max_attempts="${3:-30}"

    log "Waiting for SSH to be ready at $public_ip..."

    for i in $(seq 1 $max_attempts); do
        if ssh -i "$ssh_key" -o ConnectTimeout=10 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ubuntu@"$public_ip" "echo 'SSH Ready'" >/dev/null 2>&1; then
            log "SSH is ready!" "SUCCESS"
            return 0
        fi
        log "Waiting for SSH... (attempt $i/$max_attempts)"
        sleep 10
    done

    log "SSH not ready after $max_attempts attempts" "ERROR"
    return 1
}

# Check if K3s is installed on remote host
check_k3s_installed() {
    local public_ip="$1"
    local ssh_key="$2"

    if ssh -i "$ssh_key" -o ConnectTimeout=10 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ubuntu@"$public_ip" "command -v k3s >/dev/null 2>&1" 2>/dev/null; then
        return 0
    else
        return 1
    fi
}

# Setup SSH keys
setup_ssh_keys() {
    local ssh_key_name="${1:-oci_k3s_server}"
    local ssh_private_key="$HOME/.ssh/$ssh_key_name"
    local ssh_public_key="$HOME/.ssh/$ssh_key_name.pub"

    # Ensure ~/.ssh directory exists
    mkdir -p "$HOME/.ssh"
    chmod 700 "$HOME/.ssh"

    # Check if SSH key already exists
    if [ -f "$ssh_private_key" ] && [ -f "$ssh_public_key" ]; then
        log "SSH key pair already exists: $ssh_key_name" "SUCCESS"
    else
        log "Generating SSH key pair: $ssh_key_name" "INFO"

        # Generate SSH key pair
        ssh-keygen -t ed25519 -f "$ssh_private_key" -N "" -C "oci-k3s-server-$(date +%Y%m%d)"

        if [ $? -eq 0 ]; then
            log "SSH key pair generated successfully" "SUCCESS"
            chmod 600 "$ssh_private_key"
            chmod 644 "$ssh_public_key"
        else
            log "Failed to generate SSH key pair" "ERROR"
            return 1
        fi
    fi

    echo "$ssh_private_key"
}

# Export functions
export -f log
export -f get_compartment_id
export -f get_instance_details
export -f get_instance_state
export -f get_instance_shape_config
export -f ensure_instance_running
export -f get_instance_public_ip
export -f wait_for_ssh
export -f check_k3s_installed
export -f setup_ssh_keys
