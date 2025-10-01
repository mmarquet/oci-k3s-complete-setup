# OCI K3s Deployment Scripts

Modular scripts for deploying and managing OCI K3s infrastructure.

## Modules

### `common-functions.sh`
Shared utility functions used by all modules:
- Logging with colors
- OCI instance state management
- SSH connection testing
- K3s installation checks

### `1-deploy-vm.sh`
Deploys a new OCI VM.Standard.A1.Flex instance.

**Idempotent**: Checks if instance already exists before deploying.

**Usage**:
```bash
./scripts/1-deploy-vm.sh
```

**Outputs**:
- `INSTANCE_ID`: The OCI instance OCID
- `PUBLIC_IP`: The instance public IP address
- `INSTANCE_STATE`: Current instance state

### `2-resize-vm.sh`
Resizes an existing instance to target OCPU/memory configuration.

**Idempotent**: Checks current size before resizing. Skips if already at target size.

**Usage**:
```bash
./scripts/2-resize-vm.sh <instance-id>
```

**Environment Variables**:
- `TARGET_OCPUS` (default: 4)
- `TARGET_MEMORY_GB` (default: 24)

**Outputs**:
- `RESIZE_NEEDED`: true/false
- `RESIZE_COMPLETED`: true/false if resize was performed
- `NEW_OCPUS`: Final OCPU count
- `NEW_MEMORY`: Final memory in GB

### `3-setup-k3s.sh`
Installs and configures K3s cluster on the remote VM.

**Idempotent**: Checks if K3s is already installed and healthy before proceeding.

**Usage**:
```bash
./scripts/3-setup-k3s.sh <public-ip> <ssh-key-path>
```

**Requirements**:
- `k3s/.env` file must exist with required configuration

**Outputs**:
- `K3S_INSTALLED`: true/false
- `K3S_ALREADY_CONFIGURED`: true/false/partial
- `K3S_SETUP_COMPLETED`: true if setup was performed
- `ARGOCD_PASSWORD`: ArgoCD admin password

### `4-create-ssh-alias.sh`
Creates an SSH config entry for easy access.

**Idempotent**: Updates existing entry if already present.

**Usage**:
```bash
./scripts/4-create-ssh-alias.sh <public-ip> <ssh-key-path> [alias-name]
```

**Default alias**: `OCI-k3s`

**Outputs**:
- `SSH_ALIAS`: The alias name
- `SSH_ALIAS_CREATED`: true

## State Detection

All modules implement state detection to ensure idempotent behavior:

- **Deploy**: Checks if instance exists in any state
- **Resize**: Checks current OCPU/memory vs target
- **K3s**: Checks if K3s is installed and cluster is healthy
- **SSH Alias**: Updates existing config if present

## Polling vs Sleep

Scripts use **state polling** instead of arbitrary sleeps:
- Polls OCI API to verify state changes
- Configurable timeouts and retry intervals
- No guessing - waits for actual state confirmation
