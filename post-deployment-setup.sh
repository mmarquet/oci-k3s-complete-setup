#!/bin/bash

# Post-deployment configuration script with k3s cluster setup
# Run this after the VM is provisioned and accessible via SSH

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load environment variables if .env file exists
if [ -f "$SCRIPT_DIR/k3s/.env" ]; then
    echo "Loading environment variables from k3s/.env..."
    source "$SCRIPT_DIR/k3s/.env"
else
    echo "ERROR: k3s/.env file not found!"
    echo "Please copy k3s/.env.template to k3s/.env and fill in your values:"
    echo "cp k3s/.env.template k3s/.env"
    echo "Then edit k3s/.env with your Dynu API key and domain settings."
    exit 1
fi

# Validate required variables
if [ -z "$DYNU_API_KEY" ] || [ -z "$LETSENCRYPT_EMAIL" ] || [ -z "$DOMAIN_NAME" ] || [ -z "$WILDCARD_DOMAIN" ] || [ -z "$ARGOCD_SUBDOMAIN" ]; then
    echo "ERROR: Missing required environment variables in .env file"
    echo "Please ensure all variables are set in .env file"
    exit 1
fi

# Export variables for envsubst
export DYNU_API_KEY
export LETSENCRYPT_EMAIL
export DOMAIN_NAME
export WILDCARD_DOMAIN
export ARGOCD_SUBDOMAIN

echo "Starting post-deployment configuration..."

# Update system
echo "Updating system packages..."
sudo apt update && sudo apt upgrade -y

# Install essential packages
echo "Installing essential packages..."
sudo apt install -y \
    curl \
    wget \
    git \
    vim \
    htop \
    net-tools \
    unzip \
    ca-certificates \
    jq \
    gettext-base

# Additional SSH hardening
echo "Applying additional SSH security..."
sudo sed -i 's/#PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config
sudo systemctl restart ssh

# Configure OS-level firewall for HTTP/HTTPS
echo "Configuring firewall rules for HTTP/HTTPS traffic..."
sudo apt install -y iptables-persistent netfilter-persistent
sudo iptables -I INPUT 6 -p tcp --dport 443 -j ACCEPT
sudo iptables -I INPUT 6 -p tcp --dport 80 -j ACCEPT
sudo netfilter-persistent save
echo "Firewall rules configured and saved"

# Install Helm
echo "Installing Helm..."
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# Install k3s master node
echo "Installing k3s master node..."
curl -sfL https://get.k3s.io | sh -s - --disable=servicelb --disable=traefik --secrets-encryption

# Wait for k3s to be ready
echo "Waiting for k3s to be ready..."
for i in {1..60}; do
    if sudo k3s kubectl get nodes 2>/dev/null | grep -q Ready; then
        echo "K3s is ready!"
        break
    fi
    echo "Waiting for k3s... (attempt $i/60)"
    sleep 5
done

# Set up kubectl for regular user
echo "Setting up kubectl access..."
mkdir -p ~/.kube
sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
sudo chown $(id -u):$(id -g) ~/.kube/config
chmod 600 ~/.kube/config

# Update kubeconfig to use localhost
sed -i 's/127.0.0.1/127.0.0.1/' ~/.kube/config

# Verify kubectl is working (using sudo k3s kubectl since kubectl might not be in PATH)
echo "Verifying kubectl access..."
sudo k3s kubectl get nodes

# Install nginx ingress controller
echo "Installing nginx ingress controller..."
helm upgrade ingress-nginx ingress-nginx \
    --repo https://kubernetes.github.io/ingress-nginx \
    --namespace ingress-nginx \
    --atomic --install --create-namespace \
    --set controller.service.type=NodePort \
    --set controller.kind=DaemonSet \
    --set controller.hostNetwork=true \
    --values k3s/nginx-values.yml

# Wait for nginx to be ready
echo "Waiting for nginx ingress to be ready..."
sudo k3s kubectl wait --namespace ingress-nginx \
    --for=condition=ready pod \
    --selector=app.kubernetes.io/component=controller \
    --timeout=300s

# Install cert-manager
echo "Installing cert-manager..."
export chart="cert-manager" && \
export name="cert-manager" && \
export repo="https://charts.jetstack.io" && \
export namespace="cert-manager" && \
helm upgrade ${name} ${chart} \
    --repo ${repo} \
    --namespace ${namespace} \
    --atomic --install --reuse-values --create-namespace \
    --values k3s/certman-values.yml

# Wait for cert-manager to be ready
echo "Waiting for cert-manager to be ready..."
sudo k3s kubectl wait --namespace cert-manager \
    --for=condition=ready pod \
    --selector=app.kubernetes.io/name=cert-manager \
    --timeout=300s

# Create dynu token secret
echo "Creating dynu token secret..."
if ! sudo k3s kubectl get secret dynu-token -n cert-manager >/dev/null 2>&1; then
    sudo k3s kubectl create secret generic dynu-token -n cert-manager --from-literal=api-key="$DYNU_API_KEY"
    echo "Dynu token secret created"
else
    echo "Dynu token secret already exists, skipping"
fi

# Install dynu webhook
echo "Installing dynu webhook..."
export chart="dynu-webhook" && \
export name="dynu-webhook" && \
export repo="https://dopingus.github.io/cert-manager-webhook-dynu" && \
export namespace="cert-manager" && \
helm upgrade ${name} ${chart} \
    --repo ${repo} \
    --namespace ${namespace} \
    --atomic --install --reuse-values --create-namespace \
    --values k3s/dynu-values.yml

# Wait for dynu webhook to be ready
echo "Waiting for dynu webhook to be ready..."
sudo k3s kubectl wait --namespace cert-manager \
    --for=condition=ready pod \
    --selector=app=dynu-webhook \
    --timeout=300s

# Generate cert-manager configuration from template
echo "Generating cert-manager configuration..."
envsubst < k3s/cert-manager.yaml.template > k3s/cert-manager.yaml

# Apply cert-manager configuration
echo "Applying cert-manager configuration..."
sudo k3s kubectl apply -f k3s/cert-manager.yaml

# Install ArgoCD
echo "Installing ArgoCD..."
sudo k3s kubectl create namespace argocd --dry-run=client -o yaml | sudo k3s kubectl apply -f -
sudo k3s kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Wait for ArgoCD to be ready
echo "Waiting for ArgoCD to be ready..."
sudo k3s kubectl wait --namespace argocd \
    --for=condition=ready pod \
    --selector=app.kubernetes.io/name=argocd-server \
    --timeout=600s

# Generate ArgoCD ingress from template
echo "Generating ArgoCD ingress configuration..."
envsubst < k3s/argocd-ingress.yaml.template > k3s/argocd-ingress.yaml

# Apply ArgoCD ingress
echo "Applying ArgoCD ingress..."
sudo k3s kubectl apply -f k3s/argocd-ingress.yaml

# Get ArgoCD admin password
echo "Getting ArgoCD admin password..."
ARGOCD_PASSWORD=$(sudo k3s kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)

# Log completion
echo "Post-deployment setup completed at $(date)" | sudo tee -a /var/log/post-deployment.log

echo "=== k3s Cluster Setup Complete ==="
echo "Cluster is ready with:"
echo "- k3s master node"
echo "- nginx ingress controller"
echo "- cert-manager with Let's Encrypt"
echo "- ArgoCD"
echo ""
echo "Domain: $DOMAIN_NAME"
echo "ArgoCD URL: https://$ARGOCD_SUBDOMAIN"
echo "ArgoCD admin username: admin"
echo "ArgoCD admin password: $ARGOCD_PASSWORD"
echo ""
echo "Kubectl is available on the server at: ~/.kube/config"