#!/bin/bash

# Minimal Ubuntu 24.04 setup for fast provisioning
set -e

# Set hostname only - minimal required setup
hostnamectl set-hostname ${hostname}
echo "127.0.1.1 ${hostname}" >> /etc/hosts

# Basic security - disable root login
sed -i 's/#PermitRootLogin yes/PermitRootLogin no/' /etc/ssh/sshd_config
systemctl restart sshd

# Completion marker
echo "Minimal setup completed at $(date)" > /var/log/cloud-init-complete.log