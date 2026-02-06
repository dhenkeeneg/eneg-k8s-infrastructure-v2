# =============================================================================
# DEV Environment - VM Definitionen
# =============================================================================
# VM-Verteilung:
#   k8s-dev-21 -> HOST1 (s2842) -> vCenter Legacy
#   k8s-dev-22 -> HOST2 (s2843) -> vCenter-A
#   k8s-dev-23 -> HOST3 (s3168) -> vCenter-A
# =============================================================================

# -----------------------------------------------------------------------------
# k8s-dev-21 auf HOST1 (s2842) - vCenter Legacy
# -----------------------------------------------------------------------------
# HINWEIS: ESXi 6.7 + Ubuntu 24.04 = Guest Customization funktioniert nicht
#          Stattdessen cloud-init über vApp Properties verwenden
# -----------------------------------------------------------------------------

module "k8s_dev_21" {
  source = "../../modules/vm"

  providers = {
    vsphere = vsphere.vcenter_legacy
  }

  # vCenter Legacy Einstellungen
  datacenter    = "eNeG"
  host          = "s2842.eneg.de"
  datastore     = "S2842_D08-10_R5_SSD_K8s"
  network       = var.network
  template_name = var.template_name
  folder        = vsphere_folder.k8s_dev_legacy.path

  # VM Konfiguration
  vm_name    = "k8s-dev-21"
  hostname   = "k8s-dev-21"
  domain     = var.domain
  cpu        = var.vm_cpu
  memory     = var.vm_memory_mb
  disk_size  = var.vm_disk_gb

  # Netzwerk
  ip_address  = "192.168.180.21"
  gateway     = var.gateway
  dns_servers = var.dns_servers

  # ESXi 6.7: Guest Customization deaktivieren, cloud-init verwenden
  use_guest_customization = false
  cloud_init_userdata     = <<-EOT
    #cloud-config
    hostname: k8s-dev-21
    fqdn: k8s-dev-21.eneg.de
    manage_etc_hosts: true
    
    write_files:
      - path: /etc/netplan/50-cloud-init.yaml
        content: |
          network:
            version: 2
            ethernets:
              ens160:
                addresses:
                  - 192.168.180.21/24
                routes:
                  - to: default
                    via: 192.168.180.247
                nameservers:
                  addresses:
                    - 192.168.161.101
                    - 192.168.161.102
                    - 192.168.161.103
                  search:
                    - eneg.de
    
    runcmd:
      - netplan apply
      - ssh-keygen -A
      - systemctl restart ssh
  EOT
}

# -----------------------------------------------------------------------------
# k8s-dev-22 auf HOST2 (s2843) - vCenter-A
# -----------------------------------------------------------------------------

module "k8s_dev_22" {
  source = "../../modules/vm"

  providers = {
    vsphere = vsphere.vcenter_a
  }

  # vCenter-A Einstellungen
  datacenter    = "eNeG-Datacenter"
  host          = "s2843.eneg.de"
  datastore     = "S2843_SSD_01_VMS"
  network       = var.network
  template_name = var.template_name
  folder        = vsphere_folder.k8s_dev_a.path

  # VM Konfiguration
  vm_name    = "k8s-dev-22"
  hostname   = "k8s-dev-22"
  domain     = var.domain
  cpu        = var.vm_cpu
  memory     = var.vm_memory_mb
  disk_size  = var.vm_disk_gb

  # Netzwerk
  ip_address  = "192.168.180.22"
  gateway     = var.gateway
  dns_servers = var.dns_servers
}

# -----------------------------------------------------------------------------
# k8s-dev-23 auf HOST3 (s3168) - vCenter-A
# -----------------------------------------------------------------------------

module "k8s_dev_23" {
  source = "../../modules/vm"

  providers = {
    vsphere = vsphere.vcenter_a
  }

  # vCenter-A Einstellungen
  datacenter    = "eNeG-Datacenter"
  host          = "s3168.eneg.de"
  datastore     = "S3168_SSD_01_VMS"
  network       = var.network
  template_name = var.template_name
  folder        = vsphere_folder.k8s_dev_a.path

  # VM Konfiguration
  vm_name    = "k8s-dev-23"
  hostname   = "k8s-dev-23"
  domain     = var.domain
  cpu        = var.vm_cpu
  memory     = var.vm_memory_mb
  disk_size  = var.vm_disk_gb

  # Netzwerk
  ip_address  = "192.168.180.23"
  gateway     = var.gateway
  dns_servers = var.dns_servers
}
