output "instance_id" {
  description = "OCID of the created instance"
  value       = oci_core_instance.ubuntu_a1_flex.id
}

output "instance_public_ip" {
  description = "Public IP address of the instance"
  value       = oci_core_instance.ubuntu_a1_flex.public_ip
}

output "instance_private_ip" {
  description = "Private IP address of the instance"
  value       = oci_core_instance.ubuntu_a1_flex.private_ip
}

output "instance_state" {
  description = "Current state of the instance"
  value       = oci_core_instance.ubuntu_a1_flex.state
}

output "ssh_connection" {
  description = "SSH connection command"
  value       = "ssh ubuntu@${oci_core_instance.ubuntu_a1_flex.public_ip}"
}

output "instance_shape_config" {
  description = "Instance shape configuration"
  value = {
    shape      = oci_core_instance.ubuntu_a1_flex.shape
    ocpus      = oci_core_instance.ubuntu_a1_flex.shape_config[0].ocpus
    memory_gbs = oci_core_instance.ubuntu_a1_flex.shape_config[0].memory_in_gbs
  }
}

# Networking outputs
output "vcn_id" {
  description = "OCID of the VCN"
  value       = oci_core_vcn.k3s_vcn.id
}

output "subnet_id" {
  description = "OCID of the subnet"
  value       = oci_core_subnet.k3s_public_subnet.id
}

output "internet_gateway_id" {
  description = "OCID of the internet gateway"
  value       = oci_core_internet_gateway.k3s_ig.id
}

output "security_list_id" {
  description = "OCID of the security list"
  value       = oci_core_security_list.k3s_security_list.id
}