#!/bin/bash

# VM.Standard.A1.Flex Deployment Retry Script
# This script tries to deploy the VM every 2 minutes until successful
# Oracle Cloud free tier A1 instances have limited capacity

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="$SCRIPT_DIR/logs/deployment.log"
SSH_KEY_NAME="oci_k3s_server"
SSH_PRIVATE_KEY="$HOME/.ssh/$SSH_KEY_NAME"
SSH_PUBLIC_KEY="$HOME/.ssh/$SSH_KEY_NAME.pub"
MAX_ATTEMPTS=720  # 24 hours worth of attempts
ATTEMPT=1

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log() {
    echo -e "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

cleanup() {
    log "${YELLOW}Script interrupted. Cleaning up...${NC}"
    exit 1
}

# Function to generate SSH keys and setup alias
setup_ssh_keys() {
    # Ensure ~/.ssh directory exists
    mkdir -p "$HOME/.ssh"
    chmod 700 "$HOME/.ssh"

    # Check if SSH key already exists
    if [ -f "$SSH_PRIVATE_KEY" ] && [ -f "$SSH_PUBLIC_KEY" ]; then
        log "${GREEN}SSH key pair already exists: $SSH_KEY_NAME${NC}"
    else
        log "${YELLOW}Generating SSH key pair: $SSH_KEY_NAME${NC}"

        # Generate SSH key pair
        ssh-keygen -t ed25519 -f "$SSH_PRIVATE_KEY" -N "" -C "oci-k3s-server-$(date +%Y%m%d)"

        if [ $? -eq 0 ]; then
            log "${GREEN}SSH key pair generated successfully${NC}"
            chmod 600 "$SSH_PRIVATE_KEY"
            chmod 644 "$SSH_PUBLIC_KEY"
        else
            log "${RED}Failed to generate SSH key pair${NC}"
            exit 1
        fi
    fi

    # Read the public key content for Terraform
    if [ -f "$SSH_PUBLIC_KEY" ]; then
        SSH_PUBLIC_KEY_CONTENT=$(cat "$SSH_PUBLIC_KEY")
        log "${GREEN}SSH public key loaded${NC}"
    else
        log "${RED}SSH public key not found${NC}"
        exit 1
    fi
}

# Function to create SSH alias after successful deployment
create_ssh_alias() {
    local public_ip="$1"
    local alias_name="OCI-k3s"

    # Create SSH config entry
    local ssh_config="$HOME/.ssh/config"

    # Remove existing entry if it exists
    if [ -f "$ssh_config" ]; then
        sed -i "/^Host $alias_name$/,/^Host /{ /^Host $alias_name$/d; /^Host /!d; }" "$ssh_config"
        sed -i "/^Host $alias_name$/,\${ /^Host $alias_name$/d; /^$/!{ /^Host /!d; }; }" "$ssh_config"
    fi

    # Add new SSH config entry
    cat >> "$ssh_config" << EOF

Host $alias_name
    HostName $public_ip
    User ubuntu
    IdentityFile $SSH_PRIVATE_KEY
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
EOF

    chmod 600 "$ssh_config"
    log "${GREEN}SSH alias created: ssh $alias_name${NC}"
}

# Function to resize VM to maximum free tier
resize_vm() {
    local instance_id="$1"

    log "Stopping instance for resize..."
    if oci compute instance action --instance-id "$instance_id" --action STOP --wait-for-state STOPPED --max-wait-seconds 300 2>&1 | tee -a "$LOG_FILE"; then
        log "${GREEN}Instance stopped successfully${NC}"
    else
        log "${RED}Failed to stop instance. Continuing without resize...${NC}"
        return 1
    fi

    log "Resizing to 4 OCPU / 24GB RAM..."
    if oci compute instance update --instance-id "$instance_id" \
        --shape-config '{"ocpus":4,"memory_in_gbs":24}' \
        --force --wait-for-state STOPPED --max-wait-seconds 300 2>&1 | tee -a "$LOG_FILE"; then
        log "${GREEN}Instance resized successfully${NC}"
    else
        log "${RED}Failed to resize instance. Continuing with original size...${NC}"
    fi

    log "Starting instance..."
    if oci compute instance action --instance-id "$instance_id" --action START --wait-for-state RUNNING --max-wait-seconds 300 2>&1 | tee -a "$LOG_FILE"; then
        log "${GREEN}Instance started successfully with new size${NC}"
        # Wait a bit more for SSH to be ready after resize
        log "Waiting 60 seconds for SSH to be ready after resize..."
        sleep 60
    else
        log "${RED}Failed to start instance after resize${NC}"
        return 1
    fi
}

# Function to setup K3s cluster
setup_k3s_cluster() {
    local public_ip="$1"

    # Check if k3s/.env file exists
    if [ ! -f "../k3s/.env" ]; then
        log "${RED}ERROR: k3s/.env file not found!${NC}"
        log "${YELLOW}Please copy k3s/.env.template to k3s/.env and fill in your values:${NC}"
        log "cp k3s/.env.template k3s/.env"
        return 1
    fi

    log "Waiting for SSH to be ready..."
    local ssh_ready=false
    for i in {1..30}; do
        if ssh -i "$SSH_PRIVATE_KEY" -o ConnectTimeout=10 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ubuntu@"$public_ip" "echo 'SSH Ready'" >/dev/null 2>&1; then
            ssh_ready=true
            break
        fi
        log "Waiting for SSH... (attempt $i/30)"
        sleep 10
    done

    if [ "$ssh_ready" = false ]; then
        log "${RED}SSH not ready after 5 minutes. Please manually run setup later.${NC}"
        log "${YELLOW}Manual setup: scp post-deployment-setup.sh and k3s/ to ubuntu@$public_ip, then run ./post-deployment-setup.sh${NC}"
        return 1
    fi

    log "Copying setup files to VM..."
    if scp -i "$SSH_PRIVATE_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ../post-deployment-setup.sh ubuntu@"$public_ip":~/ 2>&1 | tee -a "$LOG_FILE" && \
       scp -i "$SSH_PRIVATE_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -r ../k3s/ ubuntu@"$public_ip":~/ 2>&1 | tee -a "$LOG_FILE"; then
        log "${GREEN}Files copied successfully${NC}"
    else
        log "${RED}Failed to copy files${NC}"
        return 1
    fi

    log "Running K3s setup on VM (this may take 10-15 minutes)..."
    if ssh -i "$SSH_PRIVATE_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ubuntu@"$public_ip" "chmod +x ./post-deployment-setup.sh && ./post-deployment-setup.sh" 2>&1 | tee -a "$LOG_FILE"; then
        log "${GREEN}K3s cluster setup completed successfully!${NC}"

        return 0
    else
        log "${RED}K3s setup failed. Check logs above for details.${NC}"
        return 1
    fi
}

trap cleanup SIGINT SIGTERM

log "${GREEN}Starting VM.Standard.A1.Flex deployment retry script${NC}"
log "Will attempt deployment every 2 minutes for up to $MAX_ATTEMPTS attempts"

# Setup SSH keys before starting deployment
setup_ssh_keys

cd "$SCRIPT_DIR/terraform"

# Initialize Terraform if needed
if [ ! -d ".terraform" ]; then
    log "${YELLOW}Initializing Terraform...${NC}"
    terraform init
fi

while [ $ATTEMPT -le $MAX_ATTEMPTS ]; do
    log "${YELLOW}Attempt $ATTEMPT of $MAX_ATTEMPTS${NC}"

    # Check if instance already exists and is running
    if terraform show -json 2>/dev/null | jq -e '.values.root_module.resources[] | select(.type == "oci_core_instance" and .values.state == "RUNNING")' > /dev/null 2>&1; then
        log "${GREEN}Instance already exists and is running!${NC}"
        terraform output
        exit 0
    fi

    # Try to apply the configuration
    log "Attempting to deploy VM.Standard.A1.Flex instance..."

    if terraform apply -auto-approve 2>&1 | tee -a "$LOG_FILE"; then
        # Check if the apply was successful
        if terraform show -json 2>/dev/null | jq -e '.values.root_module.resources[] | select(.type == "oci_core_instance")' > /dev/null 2>&1; then
            log "${GREEN}SUCCESS! VM.Standard.A1.Flex instance deployed successfully!${NC}"
            log "${GREEN}Instance details:${NC}"
            terraform output

            # Get instance details
            INSTANCE_ID=$(terraform output -raw instance_id 2>/dev/null)
            PUBLIC_IP=$(terraform output -raw instance_public_ip 2>/dev/null || echo "Not available")

            if [ "$PUBLIC_IP" != "Not available" ] && [ -n "$INSTANCE_ID" ]; then
                log "${GREEN}Starting automated post-deployment setup...${NC}"

                # Step 1: Resize VM to maximum free tier (4 OCPU, 24GB RAM)
                log "${YELLOW}Step 1: Resizing VM to 4 OCPU / 24GB RAM...${NC}"
                resize_vm "$INSTANCE_ID"

                # Step 2: Copy files and run K3s setup
                log "${YELLOW}Step 2: Setting up K3s cluster...${NC}"
                setup_k3s_cluster "$PUBLIC_IP"

                # Step 3: Create SSH alias
                log "${YELLOW}Step 3: Creating SSH alias...${NC}"
                create_ssh_alias "$PUBLIC_IP"

                log "${GREEN}🎉 COMPLETE! Your K3s cluster is ready!${NC}"
                log "${GREEN}ArgoCD URL: https://argocd.$(grep DOMAIN_NAME ../k3s/.env 2>/dev/null | cut -d'=' -f2 | tr -d '"' || echo 'your-domain.com')${NC}"
                log "${GREEN}SSH to server: ssh OCI-k3s${NC}"
            else
                log "${GREEN}You can SSH to the instance with: ssh ubuntu@$PUBLIC_IP${NC}"
            fi

            exit 0
        fi
    fi

    # Check the error message
    if grep -q -i "out of capacity\|no available capacity\|insufficient capacity\|service limit\|shape VM.Standard.A1.Flex not available" "$LOG_FILE"; then
        log "${RED}Capacity not available. Will retry in 2 minutes...${NC}"
    elif grep -q -i "limit exceeded\|quota exceeded" "$LOG_FILE"; then
        log "${RED}Quota/limit exceeded. Will retry in 2 minutes...${NC}"
    else
        log "${RED}Deployment failed for unknown reason. Check the log above.${NC}"
        log "${YELLOW}Will retry in 2 minutes anyway...${NC}"
    fi

    # Clean up any partial resources
    log "Cleaning up any partial resources..."
    terraform destroy -auto-approve >/dev/null 2>&1 || true

    if [ $ATTEMPT -lt $MAX_ATTEMPTS ]; then
        log "${YELLOW}Waiting 2 minutes before next attempt...${NC}"
        sleep 60  # 2 minutes
    fi

    ATTEMPT=$((ATTEMPT + 1))
done

log "${RED}Failed to deploy after $MAX_ATTEMPTS attempts. Giving up.${NC}"
log "${YELLOW}You may want to try a different region or wait for capacity to become available.${NC}"
exit 1