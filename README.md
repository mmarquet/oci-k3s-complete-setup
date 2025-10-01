# ⚠️ **DISCLAIMER**

**YOU ARE RESPONSIBLE FROM CLONING THIS REPO AND USING IT. I CANNOT BE HELD RESPONSIBLE if you are not on a free plan at Oracle Cloud and you start spending money through the terraform operations.**

This repository provides a complete, tested deployment solution for OCI K3s clusters. The deployment is fully automated, modular, and idempotent.

# OCI k3s Single-Node Cluster Deployment

## 🎯 Goal

This repository provides automated provisioning and setup of a k3s Kubernetes cluster on Oracle Cloud Infrastructure (OCI) using the free tier. It's designed to be a complete solution that takes you from zero to a fully functional k3s cluster with ingress controller, cert-manager, and ArgoCD.

Perfect for:
- Learning Kubernetes and k3s
- Development and testing environments
- Personal projects and demos
- CI/CD experimentation with ArgoCD

## 🚀 Quick Start Workflow

> **🎯 True One-Command Deployment!** Configure once, run `./deploy-retry.sh`, and get a complete K3s cluster with GitOps!

### Prerequisites

1. **OCI Account**: Oracle Cloud free tier account (works with a pay as you go account as well but **YOU** are **RESPONSIBLE** if any charge occurs). Pay as you go makes provisioning easier but if you are already above the free tier limit, you **WILL** be charged some fees for provisioning the various components necessary.

2. **OCI CLI**: Install and configure the Oracle Cloud CLI
   ```bash
   # Install OCI CLI (Linux/macOS)
   bash -c "$(curl -L https://raw.githubusercontent.com/oracle/oci-cli/master/scripts/install/install.sh)"

   # Or using package managers:
   # macOS: brew install oci-cli
   # Ubuntu/Debian: sudo apt install python3-oci-cli

   # Configure with your OCI credentials
   oci setup config
   ```
   Follow the prompts to enter:
   - User OCID
   - Tenancy OCID
   - Region
   - Generate/upload API keys
   
   You can get these information in your OCI account via the OCI Console.

3. **Terraform**: Install Terraform on your local machine
   ```bash
   # Using package managers:
   # macOS: brew install terraform
   # Ubuntu/Debian:
   wget -O- https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
   echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
   sudo apt update && sudo apt install terraform

   # Or download from: https://www.terraform.io/downloads
   # Verify installation
   terraform version
   ```

4. **Domain with Dynu**: A domain name managed by Dynu DNS
   > ⚠️ **Important**: This repository is specifically configured for Dynu DNS provider. The cert-manager webhook is pre-configured for Dynu's API. Other DNS providers will require webhook configuration changes.

   - Sign up at [Dynu.com](https://www.dynu.com/)
   - Add your domain or get a free subdomain
   - Generate an API key from your Dynu control panel, you will need it later

### Step 1: Prepare Configuration

1. **Clone and configure**:
   ```bash
   git clone <this-repo>
   cd oci-k3s-complete-setup
   ```

2. **Set up k3s configuration**:
   ```bash
   cp k3s/.env.template k3s/.env
   # Edit k3s/.env with your domain name and API key from DYNU
   ```

3. **Set up Terraform configuration**:
   ```bash
   cp terraform/terraform.tfvars.template terraform/terraform.tfvars
   # Edit terraform/terraform.tfvars with your actual OCI values
   ```

   You'll need to update:
   - `region`: Your OCI region (e.g. "eu-marseille-1", "eu-paris-1", etc.)
   - `tenancy_ocid`: Your OCI tenancy OCID
   - `compartment_id`: Your compartment OCID (can be same as tenancy for root compartment)
   - `instance_name`: Desired name for your VM

### Step 2: One-Command Complete Deployment

Start the fully automated deployment:
```bash
./deploy-retry.sh
```

This script will:
- Generate SSH keys automatically (ed25519, stored in `~/.ssh/`)
- Create complete networking infrastructure (VCN, subnet, security lists, gateway)
- Try to provision VM every 2 minutes for up to 24 hours (configurable with `--max-attempts`)
- Start with minimal resources (1 CPU, 6GB RAM) for better success rate
- Handle capacity errors automatically and retry
- Resize to 4 CPU, 24GB RAM (maximum free tier)
- Configure OS-level firewall rules for HTTP/HTTPS
- Copy files and install K3s cluster
- Set up complete Kubernetes environment (nginx ingress, cert-manager, dynu webhook, ArgoCD)
- Create SSH alias on your machine for easy server access (`ssh OCI-k3s`)
- Log all operations to `logs/deployment.log`

**The script is fully idempotent** - you can run it multiple times safely. It will detect existing resources and skip completed steps.

The VM provisioning can take a VERY long time depending on Oracle's current capacity. Be patient.

### Step 3: Update DNS Records

After deployment completes, update your Dynu DNS records to point to the instance's public IP:
1. Go to [Dynu Control Panel](https://www.dynu.com/en-US/ControlPanel/DDNS)
2. Update the A record for your domain to the IP shown in deployment output
3. Update the wildcard record `*.yourdomain.com` to the same IP

DNS propagation typically takes 5-15 minutes with Dynu.

### What You Get

After the script completes and DNS propagates:
- **Full K3s cluster** running on maximum free tier resources (4 OCPU / 24GB RAM)
- **ArgoCD UI** at `https://argocd.<yourdynudomain>.com`
- **Easy SSH access** via `ssh OCI-k3s` alias
- **Secure authentication** using generated ed25519 keys
- **Production-ready setup** with ingress, automatic SSL certificates, and GitOps
- **Let's Encrypt wildcard certificate** (may take 5-10 minutes to issue)

### Getting ArgoCD Password

Once deployment completes, get your ArgoCD admin password:
```bash
ssh OCI-k3s "sudo k3s kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
```

Login to ArgoCD with:
- **Username**: `admin`
- **Password**: (from command above)

## 🔧 Configuration Details

### Environment Variables (k3s/.env)

```bash
# Dynu API key for DNS challenges
DYNU_API_KEY=your-api-key-here

# Email for Let's Encrypt certificates
LETSENCRYPT_EMAIL=your-email

# Your domain configuration
DOMAIN_NAME=yourdomain.com
WILDCARD_DOMAIN=*.yourdomain.com
ARGOCD_SUBDOMAIN=argocd.yourdomain.com
```

## 🎛️ What Gets Installed

### Infrastructure
- **VM**: Oracle Cloud A1.Flex instance (ARM64)
- **OS**: Ubuntu 24.04 LTS
- **Network**: Public IP with SSH access
- **Storage**: 50GB boot volume

### k3s Cluster Components
- **k3s**: Lightweight Kubernetes distribution
- **nginx-ingress**: Ingress controller with SSL termination
- **cert-manager**: Automatic SSL certificate management
- **Dynu webhook**: DNS-01 challenge solver for Let's Encrypt
- **ArgoCD**: GitOps continuous deployment

### Security Features
- SSH key-only authentication
- Automatic SSL certificates via Let's Encrypt
- Network policies and security hardening

## 🎨 Modular Usage

The deployment system is modular. You can run specific steps:

```bash
# Run all steps (default)
./deploy-retry.sh

# Run only specific steps
./deploy-retry.sh --k3s              # K3s setup only
./deploy-retry.sh --resize           # Resize VM only
./deploy-retry.sh --deploy-resize    # Deploy and resize
./deploy-retry.sh --ssh-alias        # Create SSH alias only

# Set maximum deployment attempts
./deploy-retry.sh --max-attempts 100

# View help
./deploy-retry.sh --help
```

Individual modules are available in `scripts/`:
- `scripts/1-deploy-vm.sh` - VM deployment
- `scripts/2-resize-vm.sh` - VM resizing
- `scripts/3-setup-k3s.sh` - K3s installation
- `scripts/4-create-ssh-alias.sh` - SSH alias creation

## 🔍 Monitoring and Access

**During deployment**, monitor progress:
```bash
# Watch deployment attempts (in another terminal)
tail -f logs/deployment.log
```

**After deployment**, you'll have access to:
- **ArgoCD UI**: `https://argocd.yourdomain.com`
- **SSH access**: `ssh OCI-k3s` (automatic alias created)

**Check cluster status:**
```bash
ssh OCI-k3s
sudo k3s kubectl get nodes
sudo k3s kubectl get pods -A
sudo k3s kubectl get certificates -A  # Check SSL certificates
```

## 🧹 Cleanup

To remove everything:
```bash
# Destroy the VM and all resources
cd terraform/
terraform destroy
```

## 🛠️ Troubleshooting

### Common Issues

**Capacity errors**: The retry script handles this automatically. Oracle typically has better capacity during off-peak hours. Once again, understand that on a free tier account, you have zero priority and it can takes days to get your own VM. Some people tried for weeks.

**DNS issues**: Ensure your domain DNS is properly configured and Dynu API key is correct.

**Certificate issues**: Check cert-manager logs: `kubectl logs -n cert-manager -l app=cert-manager`

**Networking issues**: The setup now automatically creates all networking components. If you have existing VCN/subnets, they won't conflict as new ones are created with unique names.

### Getting Help

1. Check logs in `logs/deployment.log`
2. Verify your `.env` configuration
3. Test your domain DNS settings
4. Check OCI service limits and quotas
5. Ensure your OCI CLI is properly configured: `oci iam user get --user-id $(oci iam user list --query 'data[0].id' --raw-output)`

## 🤝 Contributing

This is an open-source project! Feel free to:
- Report issues
- Submit pull requests
- Suggest improvements
- Add support for other DNS providers

## 📄 License

MIT License - see LICENSE file for details.