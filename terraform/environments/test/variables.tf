# =============================================================================
# TEST Environment - Variables
# =============================================================================

# -----------------------------------------------------------------------------
# vCenter Verbindung (einziges vCenter seit Feb 2026)
# -----------------------------------------------------------------------------

variable "vcenter_server" {
  type        = string
  default     = "vcenter-a.eneg.de"
  description = "vCenter Server"
}

variable "vcenter_username" {
  type        = string
  description = "vCenter Benutzername (OpenTofu@eneg.de)"
}

variable "vcenter_password" {
  type        = string
  sensitive   = true
  description = "vCenter Passwort"
}

# -----------------------------------------------------------------------------
# vSphere Datacenter
# -----------------------------------------------------------------------------

variable "datacenter" {
  type        = string
  default     = "eNeG-Datacenter"
  description = "vSphere Datacenter Name"
}

# -----------------------------------------------------------------------------
# Gemeinsame Einstellungen
# -----------------------------------------------------------------------------

variable "environment" {
  type        = string
  default     = "test"
  description = "Umgebungsname"
}

variable "domain" {
  type        = string
  default     = "eneg.de"
  description = "Domain"
}

variable "template_name" {
  type        = string
  default     = "ubuntu-24.04-k8s-template"
  description = "Name des VM Templates in vCenter-A"
}

# -----------------------------------------------------------------------------
# TEST Netzwerk (VLAN 179)
# -----------------------------------------------------------------------------

variable "network" {
  type        = string
  default     = "VT 179 - K8s Test"
  description = "Port Group fuer TEST"
}

variable "gateway" {
  type        = string
  default     = "192.168.179.247"
  description = "Gateway fuer TEST"
}

variable "dns_servers" {
  type        = list(string)
  default     = ["192.168.161.104", "192.168.161.105", "192.168.161.106"]
  description = "DNS Server"
}

# -----------------------------------------------------------------------------
# TEST VM Ressourcen
# -----------------------------------------------------------------------------

variable "vm_cpu" {
  type        = number
  default     = 6
  description = "vCPUs pro TEST Node"
}

variable "vm_memory_mb" {
  type        = number
  default     = 16384  # 16 GB
  description = "RAM in MB pro TEST Node"
}

variable "vm_disk_gb" {
  type        = number
  default     = 512
  description = "Disk-Groesse in GB pro TEST Node"
}
