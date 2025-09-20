# Networking Infrastructure for K3s Cluster
# This creates the necessary networking components before deploying the VM

# Virtual Cloud Network (VCN)
resource "oci_core_vcn" "k3s_vcn" {
  compartment_id = var.compartment_id
  display_name   = "k3s-vcn"
  cidr_blocks    = ["10.0.0.0/16"]
  dns_label      = "k3svcn"

  freeform_tags = {
    "Purpose" = "k3s-cluster"
  }
}

# Internet Gateway
resource "oci_core_internet_gateway" "k3s_ig" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.k3s_vcn.id
  display_name   = "k3s-internet-gateway"
  enabled        = true

  freeform_tags = {
    "Purpose" = "k3s-cluster"
  }
}

# Route Table for Public Subnet
resource "oci_core_default_route_table" "k3s_default_route_table" {
  manage_default_resource_id = oci_core_vcn.k3s_vcn.default_route_table_id
  display_name               = "k3s-default-route-table"

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.k3s_ig.id
  }

  freeform_tags = {
    "Purpose" = "k3s-cluster"
  }
}

# Security List for K3s
resource "oci_core_security_list" "k3s_security_list" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.k3s_vcn.id
  display_name   = "k3s-security-list"

  # Egress Rules - Allow all outbound traffic
  egress_security_rules {
    destination = "0.0.0.0/0"
    protocol    = "all"
  }

  # Ingress Rules
  # SSH access
  ingress_security_rules {
    protocol = "6" # TCP
    source   = "0.0.0.0/0"
    tcp_options {
      min = 22
      max = 22
    }
  }

  # HTTP access
  ingress_security_rules {
    protocol = "6" # TCP
    source   = "0.0.0.0/0"
    tcp_options {
      min = 80
      max = 80
    }
  }

  # HTTPS access
  ingress_security_rules {
    protocol = "6" # TCP
    source   = "0.0.0.0/0"
    tcp_options {
      min = 443
      max = 443
    }
  }

  # K3s API Server
  ingress_security_rules {
    protocol = "6" # TCP
    source   = "0.0.0.0/0"
    tcp_options {
      min = 6443
      max = 6443
    }
  }

  # NodePort range (optional, for K3s services)
  ingress_security_rules {
    protocol = "6" # TCP
    source   = "0.0.0.0/0"
    tcp_options {
      min = 30000
      max = 32767
    }
  }

  # ICMP (ping)
  ingress_security_rules {
    protocol = "1" # ICMP
    source   = "0.0.0.0/0"
  }

  freeform_tags = {
    "Purpose" = "k3s-cluster"
  }
}

# Public Subnet for K3s node
resource "oci_core_subnet" "k3s_public_subnet" {
  compartment_id      = var.compartment_id
  vcn_id              = oci_core_vcn.k3s_vcn.id
  display_name        = "k3s-public-subnet"
  cidr_block          = "10.0.1.0/24"
  dns_label           = "k3spublic"
  route_table_id      = oci_core_vcn.k3s_vcn.default_route_table_id
  security_list_ids   = [oci_core_security_list.k3s_security_list.id]
  dhcp_options_id     = oci_core_vcn.k3s_vcn.default_dhcp_options_id

  freeform_tags = {
    "Purpose" = "k3s-cluster"
  }
}