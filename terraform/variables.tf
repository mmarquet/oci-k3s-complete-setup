variable "tenancy_ocid" {
  description = "The OCID of the tenancy"
  type        = string
}

variable "region" {
  description = "The OCI region"
  type        = string
  default     = "eu-marseille-1"
}

variable "compartment_id" {
  description = "The OCID of the compartment"
  type        = string
}

variable "instance_name" {
  description = "Name for the compute instance"
  type        = string
  default     = "ubuntu-a1-flex"
}