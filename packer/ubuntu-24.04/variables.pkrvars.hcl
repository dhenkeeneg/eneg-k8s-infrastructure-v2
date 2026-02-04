# =============================================================================
# Packer Variablen für eNeG K8s Infrastructure
# =============================================================================
# HINWEIS: Diese Datei enthält KEINE sensitiven Daten!
# Passwörter werden über Umgebungsvariablen oder .auto.pkrvars.hcl übergeben.
# =============================================================================

# vCenter Verbindung
vcenter_server     = "vcenter-a.eneg.de"
vcenter_datacenter = "eNeG-Datacenter"
vcenter_host       = "S2843"
vcenter_datastore  = "S2843_HDD_00_BOOT"
vcenter_network    = "VT 180 - K8s Dev"
vcenter_folder     = "eNeG-VM-Vorlagen"
vcenter_insecure   = true

# ISO Pfad
iso_path = "[S2843_HDD_00_BOOT] eNeG-ISO/ubuntu-24.04.3-live-server-amd64.iso"

# VM Template Konfiguration
vm_name      = "ubuntu-24.04-k8s-template"
vm_cpus      = 2
vm_memory    = 4096
vm_disk_size = 51200

# SSH User (Passwort wird separat übergeben)
ssh_username = "admin-ubuntu"

# Netzwerk für Template-Build (statische IP, da kein DHCP)
build_ip = "192.168.180.9"
gateway  = "192.168.180.247"
