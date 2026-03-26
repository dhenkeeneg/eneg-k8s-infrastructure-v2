# =============================================================================
# PROD Environment - VM Definitionen
# =============================================================================
# Alle 3 Hosts sind in vcenter-a.eneg.de (ESXi 8.0.3)
#
# VM-Verteilung:
#   k8s-prod-21 -> HOST1 (s2842) -> S2842_SSD_01_VMS
#   k8s-prod-22 -> HOST2 (s2843) -> S2843_SSD_01_VMS
#   k8s-prod-23 -> HOST3 (s3168) -> S3168_SSD_01_VMS
# =============================================================================

# -----------------------------------------------------------------------------
# k8s-prod-21 auf HOST1 (s2842)
# -----------------------------------------------------------------------------

module "k8s_prod_21" {
  source = "../../modules/vm"

  # vCenter-A Einstellungen
  datacenter    = var.datacenter
  host          = "s2842.eneg.de"
  datastore     = "S2842_SSD_01_VMS"
  network       = var.network
  template_name = var.template_name
  folder        = "eNeG-VM-K8s/PROD"

  # VM Konfiguration
  vm_name    = "k8s-prod-21"
  hostname   = "k8s-prod-21"
  domain     = var.domain
  cpu        = var.vm_cpu
  memory     = var.vm_memory_mb
  disk_size  = var.vm_disk_gb

  # Netzwerk
  ip_address  = "192.168.178.21"
  gateway     = var.gateway
  dns_servers = var.dns_servers
}

# -----------------------------------------------------------------------------
# k8s-prod-22 auf HOST2 (s2843)
# -----------------------------------------------------------------------------

module "k8s_prod_22" {
  source = "../../modules/vm"

  # vCenter-A Einstellungen
  datacenter    = var.datacenter
  host          = "s2843.eneg.de"
  datastore     = "S2843_SSD_01_VMS"
  network       = var.network
  template_name = var.template_name
  folder        = "eNeG-VM-K8s/PROD"

  # VM Konfiguration
  vm_name    = "k8s-prod-22"
  hostname   = "k8s-prod-22"
  domain     = var.domain
  cpu        = var.vm_cpu
  memory     = var.vm_memory_mb
  disk_size  = var.vm_disk_gb

  # Netzwerk
  ip_address  = "192.168.178.22"
  gateway     = var.gateway
  dns_servers = var.dns_servers
}

# -----------------------------------------------------------------------------
# k8s-prod-23 auf HOST3 (s3168)
# -----------------------------------------------------------------------------

module "k8s_prod_23" {
  source = "../../modules/vm"

  # vCenter-A Einstellungen
  datacenter    = var.datacenter
  host          = "s3168.eneg.de"
  datastore     = "S3168_SSD_01_VMS"
  network       = var.network
  template_name = var.template_name
  folder        = "eNeG-VM-K8s/PROD"

  # VM Konfiguration
  vm_name    = "k8s-prod-23"
  hostname   = "k8s-prod-23"
  domain     = var.domain
  cpu        = var.vm_cpu
  memory     = var.vm_memory_mb
  disk_size  = var.vm_disk_gb

  # Netzwerk
  ip_address  = "192.168.178.23"
  gateway     = var.gateway
  dns_servers = var.dns_servers
}
