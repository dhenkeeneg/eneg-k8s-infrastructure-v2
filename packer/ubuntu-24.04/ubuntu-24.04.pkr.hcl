# =============================================================================
# Packer Template für Ubuntu 24.04 LTS auf VMware vSphere
# =============================================================================
# Erstellt ein VM-Template für K3s Kubernetes Nodes
# Projekt: eNeG K8s Infrastructure v2
# =============================================================================

packer {
  required_version = ">= 1.10.0"
  
  required_plugins {
    vsphere = {
      version = ">= 1.4.0"
      source  = "github.com/hashicorp/vsphere"
    }
  }
}

# =============================================================================
# Variablen
# =============================================================================

variable "vcenter_server" {
  type        = string
  description = "vCenter Server FQDN oder IP"
}

variable "vcenter_username" {
  type        = string
  description = "vCenter Benutzername"
}

variable "vcenter_password" {
  type        = string
  sensitive   = true
  description = "vCenter Passwort"
}

variable "vcenter_insecure" {
  type        = bool
  default     = true
  description = "SSL-Zertifikatsprüfung überspringen"
}

variable "vcenter_datacenter" {
  type        = string
  description = "vCenter Datacenter Name"
}

variable "vcenter_cluster" {
  type        = string
  default     = ""
  description = "vCenter Cluster Name (optional)"
}

variable "vcenter_host" {
  type        = string
  description = "ESXi Host für den Build"
}

variable "vcenter_datastore" {
  type        = string
  description = "Datastore für das Template"
}

variable "vcenter_network" {
  type        = string
  description = "Netzwerk/Port Group für den Build"
}

variable "vcenter_folder" {
  type        = string
  description = "VM-Ordner für das Template"
}

variable "iso_path" {
  type        = string
  description = "Pfad zur Ubuntu ISO im Datastore"
}

variable "vm_name" {
  type        = string
  default     = "ubuntu-24.04-template"
  description = "Name des VM-Templates"
}

variable "vm_cpus" {
  type        = number
  default     = 2
  description = "Anzahl vCPUs für den Build"
}

variable "vm_memory" {
  type        = number
  default     = 4096
  description = "RAM in MB für den Build"
}

variable "vm_disk_size" {
  type        = number
  default     = 51200
  description = "Disk-Größe in MB (50GB)"
}

variable "ssh_username" {
  type        = string
  default     = "admin-ubuntu"
  description = "SSH Benutzername"
}

variable "ssh_password" {
  type        = string
  sensitive   = true
  description = "SSH Passwort (wird später durch SSH-Key ersetzt)"
}

variable "build_ip" {
  type        = string
  default     = "192.168.180.9"
  description = "Temporäre IP für den Template-Build"
}

variable "gateway" {
  type        = string
  default     = "192.168.180.247"
  description = "Gateway für das Build-Netzwerk"
}

# =============================================================================
# Source: VMware vSphere ISO
# =============================================================================

source "vsphere-iso" "ubuntu" {
  # vCenter Verbindung
  vcenter_server      = var.vcenter_server
  username            = var.vcenter_username
  password            = var.vcenter_password
  insecure_connection = var.vcenter_insecure

  # Ziel-Lokation
  datacenter   = var.vcenter_datacenter
  cluster      = var.vcenter_cluster != "" ? var.vcenter_cluster : null
  host         = var.vcenter_host
  datastore    = var.vcenter_datastore
  folder       = var.vcenter_folder

  # VM Konfiguration
  vm_name              = var.vm_name
  guest_os_type        = "ubuntu64Guest"
  vm_version           = 21
  firmware             = "efi"
  CPUs                 = var.vm_cpus
  cpu_cores            = var.vm_cpus
  RAM                  = var.vm_memory
  RAM_reserve_all      = false
  tools_upgrade_policy = true
  remove_cdrom         = true
  convert_to_template  = true

  # Netzwerk
  network_adapters {
    network      = var.vcenter_network
    network_card = "vmxnet3"
  }

  # Storage
  storage {
    disk_size             = var.vm_disk_size
    disk_thin_provisioned = true
  }

  # ISO und Boot
  iso_paths = [var.iso_path]
  
  cd_content = {
    "meta-data" = file("${path.root}/http/meta-data")
    "user-data" = templatefile("${path.root}/http/user-data.pkrtpl.hcl", {
      ssh_username = var.ssh_username
      ssh_password = var.ssh_password
      build_ip     = var.build_ip
      gateway      = var.gateway
    })
  }
  cd_label = "cidata"

  boot_order = "disk,cdrom"
  boot_wait  = "5s"
  boot_command = [
    "<wait>c<wait>",
    "linux /casper/vmlinuz autoinstall ds=nocloud",
    "<enter><wait>",
    "initrd /casper/initrd",
    "<enter><wait>",
    "boot",
    "<enter>"
  ]

  # SSH Verbindung
  ssh_username         = var.ssh_username
  ssh_password         = var.ssh_password
  ssh_timeout          = "30m"
  ssh_handshake_attempts = 100

  # Shutdown
  shutdown_command = "echo '${var.ssh_password}' | sudo -S shutdown -P now"
  shutdown_timeout = "15m"
}

# =============================================================================
# Build
# =============================================================================

build {
  name    = "ubuntu-24.04"
  sources = ["source.vsphere-iso.ubuntu"]

  # Warten bis Cloud-Init fertig ist
  provisioner "shell" {
    inline = [
      "while [ ! -f /var/lib/cloud/instance/boot-finished ]; do echo 'Waiting for cloud-init...'; sleep 5; done",
      "echo 'Cloud-init finished!'"
    ]
  }

  # System aktualisieren
  provisioner "shell" {
    inline = [
      "sudo apt-get update",
      "sudo apt-get upgrade -y",
      "sudo apt-get install -y open-vm-tools qemu-guest-agent curl wget git vim htop"
    ]
  }

  # K3s Voraussetzungen
  provisioner "shell" {
    inline = [
      "# Kernel Module für Kubernetes",
      "echo 'overlay' | sudo tee -a /etc/modules-load.d/k8s.conf",
      "echo 'br_netfilter' | sudo tee -a /etc/modules-load.d/k8s.conf",
      "",
      "# Sysctl Parameter",
      "echo 'net.bridge.bridge-nf-call-iptables  = 1' | sudo tee -a /etc/sysctl.d/k8s.conf",
      "echo 'net.bridge.bridge-nf-call-ip6tables = 1' | sudo tee -a /etc/sysctl.d/k8s.conf",
      "echo 'net.ipv4.ip_forward                 = 1' | sudo tee -a /etc/sysctl.d/k8s.conf",
      "",
      "# Module laden",
      "sudo modprobe overlay",
      "sudo modprobe br_netfilter",
      "sudo sysctl --system"
    ]
  }

  # Cleanup für Template
  provisioner "shell" {
    inline = [
      "# Cloud-init für erneute Ausführung vorbereiten",
      "sudo cloud-init clean --logs",
      "",
      "# Machine-ID zurücksetzen",
      "sudo truncate -s 0 /etc/machine-id",
      "sudo rm -f /var/lib/dbus/machine-id",
      "sudo ln -s /etc/machine-id /var/lib/dbus/machine-id",
      "",
      "# SSH Host Keys entfernen (werden beim Boot neu generiert)",
      "sudo rm -f /etc/ssh/ssh_host_*",
      "",
      "# Temporäre Dateien aufräumen",
      "sudo apt-get autoremove -y",
      "sudo apt-get clean",
      "sudo rm -rf /tmp/*",
      "sudo rm -rf /var/tmp/*",
      "",
      "# Log-Dateien leeren",
      "sudo truncate -s 0 /var/log/*.log 2>/dev/null || true",
      "sudo truncate -s 0 /var/log/**/*.log 2>/dev/null || true",
      "",
      "# Bash History löschen",
      "cat /dev/null > ~/.bash_history",
      "history -c"
    ]
  }
}
