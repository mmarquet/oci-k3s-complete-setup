# Get the latest Ubuntu 24.04 image
data "oci_core_images" "ubuntu_24_04" {
  compartment_id           = var.compartment_id
  operating_system         = "Canonical Ubuntu"
  operating_system_version = "24.04"
  shape                    = "VM.Standard.A1.Flex"
  sort_by                  = "TIMECREATED"
  sort_order              = "DESC"
}

# Get availability domains
data "oci_identity_availability_domains" "ads" {
  compartment_id = var.tenancy_ocid
}

# Read the SSH public key from standard location
locals {
  ssh_public_key = try(file(pathexpand("~/.ssh/oci_k3s_server.pub")), "")
}

