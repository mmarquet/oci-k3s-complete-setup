# Minimal VM.Standard.A1.Flex compute instance for fast provisioning
resource "oci_core_instance" "ubuntu_a1_flex" {
  availability_domain = data.oci_identity_availability_domains.ads.availability_domains[0].name
  compartment_id      = var.compartment_id
  display_name        = var.instance_name
  shape               = "VM.Standard.A1.Flex"

  # Minimal resources for faster provisioning (can scale up later)
  shape_config {
    ocpus         = 1
    memory_in_gbs = 6
  }

  # Basic networking
  create_vnic_details {
    assign_public_ip = "true"
    subnet_id = oci_core_subnet.k3s_public_subnet.id
  }

  # Use the latest Ubuntu 24.04 image with minimal boot volume
  source_details {
    source_type = "image"
    source_id   = data.oci_core_images.ubuntu_24_04.images[0].id
    boot_volume_size_in_gbs = 50
  }

  # SSH key for access - minimal user data for hostname only
  metadata = {
    ssh_authorized_keys = local.ssh_public_key
    user_data = base64encode(templatefile("${path.module}/user-data.sh", {
      hostname = var.instance_name
    }))
  }
}