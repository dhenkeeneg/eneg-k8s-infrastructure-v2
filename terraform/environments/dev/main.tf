# =============================================================================
# DEV Environment - Terraform/OpenTofu Konfiguration
# =============================================================================
# Projekt: eNeG K8s Infrastructure v2
# Umgebung: DEV (VLAN 180)
# =============================================================================

terraform {
  required_version = ">= 1.6.0"

  required_providers {
    vsphere = {
      source  = "hashicorp/vsphere"
      version = ">= 2.6.0"
    }
  }

  # Backend für State-Speicherung (später S3)
  # backend "s3" {
  #   bucket = "k8s-terraform-state"
  #   key    = "dev/terraform.tfstate"
  #   region = "us-east-1"
  # }
}

# =============================================================================
# Provider: vCenter Legacy (für HOST1/s2842)
# =============================================================================

provider "vsphere" {
  alias                = "vcenter_legacy"
  vsphere_server       = var.vcenter_legacy_server
  user                 = var.vcenter_username
  password             = var.vcenter_password
  allow_unverified_ssl = true
}

# =============================================================================
# Provider: vCenter-A (für HOST2/s2843 und HOST3/s3168)
# =============================================================================

provider "vsphere" {
  alias                = "vcenter_a"
  vsphere_server       = var.vcenter_a_server
  user                 = var.vcenter_username
  password             = var.vcenter_password
  allow_unverified_ssl = true
}
