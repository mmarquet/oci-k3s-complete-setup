#!/bin/bash

# VM Resize Module
# Resizes existing OCI instance to target OCPU/memory configuration
# Idempotent: Checks current size before resizing

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
LOG_FILE="${LOG_FILE:-$PROJECT_DIR/logs/deployment.log}"

# Source common functions
source "$SCRIPT_DIR/common-functions.sh"

# Target configuration (OCI free tier maximum for A1.Flex)
TARGET_OCPUS="${TARGET_OCPUS:-4}"
TARGET_MEMORY_GB="${TARGET_MEMORY_GB:-24}"

# Wait for instance to reach specific state
wait_for_state() {
    local instance_id="$1"
    local target_state="$2"
    local max_attempts="${3:-60}"
    local check_interval="${4:-5}"

    log "Waiting for instance to reach state: $target_state" "INFO"

    for i in $(seq 1 $max_attempts); do
        local current_state=$(get_instance_state "$instance_id")
        if [ "$current_state" = "$target_state" ]; then
            log "Instance reached state: $target_state" "SUCCESS"
            return 0
        fi
        log "Current state: $current_state, waiting... (attempt $i/$max_attempts)"
        sleep "$check_interval"
    done

    log "Timeout waiting for state $target_state" "ERROR"
    return 1
}

# Wait for shape config to match target
wait_for_shape_config() {
    local instance_id="$1"
    local target_ocpus="$2"
    local target_memory="$3"
    local max_attempts="${4:-30}"
    local check_interval="${5:-5}"

    log "Waiting for shape configuration to update..." "INFO"

    for i in $(seq 1 $max_attempts); do
        local shape_config=$(get_instance_shape_config "$instance_id")
        local current_ocpus=$(echo "$shape_config" | jq -r '.ocpus // 0')
        local current_memory=$(echo "$shape_config" | jq -r '."memory-in-gbs" // 0')

        if [ "$current_ocpus" = "$target_ocpus" ] && [ "$current_memory" = "$target_memory" ]; then
            log "Shape configuration updated: $current_ocpus OCPU, $current_memory GB" "SUCCESS"
            return 0
        fi

        log "Current: $current_ocpus OCPU, $current_memory GB - waiting... (attempt $i/$max_attempts)"
        sleep "$check_interval"
    done

    log "Timeout waiting for shape configuration update" "ERROR"
    return 1
}

log "=== VM Resize Module ===" "INFO"

# Get instance ID from arguments or environment
INSTANCE_ID="${1:-$INSTANCE_ID}"

if [ -z "$INSTANCE_ID" ]; then
    log "Error: INSTANCE_ID not provided" "ERROR"
    log "Usage: $0 <instance-id>" "ERROR"
    exit 1
fi

log "Checking instance: $INSTANCE_ID" "INFO"

# Get current instance state
CURRENT_STATE=$(get_instance_state "$INSTANCE_ID")
if [ "$CURRENT_STATE" = "NOT_FOUND" ]; then
    log "Instance not found: $INSTANCE_ID" "ERROR"
    exit 1
fi

log "Current instance state: $CURRENT_STATE" "INFO"

# Get current shape configuration
SHAPE_CONFIG=$(get_instance_shape_config "$INSTANCE_ID")
CURRENT_OCPUS=$(echo "$SHAPE_CONFIG" | jq -r '.ocpus // 0')
CURRENT_MEMORY=$(echo "$SHAPE_CONFIG" | jq -r '."memory-in-gbs" // 0')

log "Current configuration: $CURRENT_OCPUS OCPU, $CURRENT_MEMORY GB RAM" "INFO"
log "Target configuration: $TARGET_OCPUS OCPU, $TARGET_MEMORY_GB GB RAM" "INFO"

# Check if resize is needed
if [ "$CURRENT_OCPUS" = "$TARGET_OCPUS" ] && [ "$CURRENT_MEMORY" = "$TARGET_MEMORY_GB" ]; then
    log "Instance is already at target size, skipping resize" "SUCCESS"
    echo "RESIZE_NEEDED=false"
    echo "CURRENT_OCPUS=$CURRENT_OCPUS"
    echo "CURRENT_MEMORY=$CURRENT_MEMORY"
    exit 0
fi

log "Resize needed" "WARN"

# Ensure instance is stopped
if [ "$CURRENT_STATE" != "STOPPED" ]; then
    log "Stopping instance for resize..." "INFO"
    if oci compute instance action --instance-id "$INSTANCE_ID" --action STOP --wait-for-state STOPPED --max-wait-seconds 300 2>&1 | tee -a "$LOG_FILE"; then
        # Double-check state
        if ! wait_for_state "$INSTANCE_ID" "STOPPED" 60 5; then
            log "Failed to confirm instance is stopped" "ERROR"
            exit 1
        fi
    else
        log "Failed to stop instance" "ERROR"
        exit 1
    fi
else
    log "Instance is already stopped" "INFO"
fi

# Perform resize
log "Resizing to $TARGET_OCPUS OCPU / $TARGET_MEMORY_GB GB RAM..." "INFO"
if oci compute instance update --instance-id "$INSTANCE_ID" \
    --shape-config "{\"ocpus\":$TARGET_OCPUS,\"memory_in_gbs\":$TARGET_MEMORY_GB}" \
    --force 2>&1 | tee -a "$LOG_FILE"; then
    log "Resize command sent" "SUCCESS"
else
    log "Failed to send resize command" "ERROR"
    exit 1
fi

# Wait for instance to settle in STOPPED state after resize
if ! wait_for_state "$INSTANCE_ID" "STOPPED" 60 5; then
    log "Instance state unstable after resize" "ERROR"
    exit 1
fi

# Wait for shape configuration to actually change
if ! wait_for_shape_config "$INSTANCE_ID" "$TARGET_OCPUS" "$TARGET_MEMORY_GB" 30 5; then
    log "Shape configuration did not update as expected" "ERROR"
    exit 1
fi

# Start instance
log "Starting instance..." "INFO"
if ensure_instance_running "$INSTANCE_ID"; then
    log "Instance started successfully" "SUCCESS"

    # Verify instance is actually running
    if ! wait_for_state "$INSTANCE_ID" "RUNNING" 60 5; then
        log "Instance not in RUNNING state" "ERROR"
        exit 1
    fi

    # Get final configuration
    FINAL_SHAPE_CONFIG=$(get_instance_shape_config "$INSTANCE_ID")
    FINAL_OCPUS=$(echo "$FINAL_SHAPE_CONFIG" | jq -r '.ocpus // 0')
    FINAL_MEMORY=$(echo "$FINAL_SHAPE_CONFIG" | jq -r '."memory-in-gbs" // 0')

    log "Final configuration: $FINAL_OCPUS OCPU, $FINAL_MEMORY GB RAM" "SUCCESS"

    echo "RESIZE_NEEDED=true"
    echo "RESIZE_COMPLETED=true"
    echo "NEW_OCPUS=$FINAL_OCPUS"
    echo "NEW_MEMORY=$FINAL_MEMORY"
    exit 0
else
    log "Failed to start instance after resize" "ERROR"
    exit 1
fi
