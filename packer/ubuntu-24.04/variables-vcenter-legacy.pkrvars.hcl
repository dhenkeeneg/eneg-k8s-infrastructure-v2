# =============================================================================
# Packer Variablen für eNeG K8s Infrastructure - vCenter Legacy (s2842)
# =============================================================================
# HINWEIS: Diese Datei enthält KEINE sensitiven Daten!
# Passwörter werden über credentials.auto.pkrvars.hcl übergeben.
# =============================================================================

# vCenter Verbindung (altes vCenter für HOST1/s2842)
vcenter_server     = "vcenter.eneg.de"
vcenter_datacenter = "eNeG"
vcenter_host       = "s2842.eneg.de"
vcenter_datastore  = "S2842_D08-10_R5_SSD_K8s"
vcenter_network    = "VT 180 - K8s Dev"
vcenter_folder     = "eNeG-VM-Vorlagen"
vcenter_insecure   = true

# ISO Pfad (anderer Datastore im alten vCenter)
iso_path = "[S2842_D18-23_R6_SSD] ISO/ubuntu-24.04.3-live-server-amd64.iso"

# VM Template Konfiguration
vm_name      = "ubuntu-24.04-k8s-template"
vm_cpus      = 2
vm_memory    = 4096
vm_disk_size = 51200
vm_version   = 14  # ESXi 6.7 unterstützt max. Version 14

# SSH User (Passwort wird separat übergeben)
ssh_username = "admin-ubuntu"

# Netzwerk für Template-Build (statische IP, da kein DHCP)
build_ip = "192.168.180.9"
gateway  = "192.168.180.247"
