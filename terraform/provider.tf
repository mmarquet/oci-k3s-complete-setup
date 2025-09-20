terraform {
  required_version = ">= 1.0"
  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "~> 5.0"
    }
  }
}

provider "oci" {
  # OCI provider will automatically use:
  # - ~/.oci/config (default config file)
  # - Or environment variables: OCI_TENANCY_OCID, OCI_USER_OCID, etc.
  # - Or explicit variables below

  tenancy_ocid = var.tenancy_ocid
  region       = var.region

  # Optional: Uncomment and configure if not using ~/.oci/config
  # user_ocid        = var.user_ocid
  # fingerprint      = var.fingerprint
  # private_key_path = var.private_key_path
}