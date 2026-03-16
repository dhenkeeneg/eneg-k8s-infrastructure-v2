# =============================================================================
# TEST Environment - Terraform/OpenTofu Konfiguration
# =============================================================================
# Projekt: eNeG K8s Infrastructure v2
# Umgebung: TEST (VLAN 179)
# vCenter: vcenter-a.eneg.de (einziges vCenter seit Feb 2026)
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
  #   key    = "test/terraform.tfstate"
  #   region = "us-east-1"
  # }
}

# =============================================================================
# Provider: vCenter-A (einziges vCenter für alle Hosts)
# =============================================================================

provider "vsphere" {
  vsphere_server       = var.vcenter_server
  user                 = var.vcenter_username
  password             = var.vcenter_password
  allow_unverified_ssl = true
}
