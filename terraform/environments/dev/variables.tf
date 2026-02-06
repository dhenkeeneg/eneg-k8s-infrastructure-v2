# =============================================================================
# DEV Environment - Variables
# =============================================================================

# -----------------------------------------------------------------------------
# vCenter Verbindungen
# -----------------------------------------------------------------------------

variable "vcenter_legacy_server" {
  type        = string
  default     = "vcenter.eneg.de"
  description = "vCenter Legacy Server (für s2842)"
}

variable "vcenter_a_server" {
  type        = string
  default     = "vcenter-a.eneg.de"
  description = "vCenter-A Server (für s2843, s3168)"
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
# Gemeinsame Einstellungen
# -----------------------------------------------------------------------------

variable "environment" {
  type        = string
  default     = "dev"
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
  description = "Name des VM Templates (in beiden vCentern gleich)"
}

# -----------------------------------------------------------------------------
# DEV Netzwerk (VLAN 180)
# -----------------------------------------------------------------------------

variable "network" {
  type        = string
  default     = "VT 180 - K8s Dev"
  description = "Port Group für DEV"
}

variable "gateway" {
  type        = string
  default     = "192.168.180.247"
  description = "Gateway für DEV"
}

variable "dns_servers" {
  type        = list(string)
  default     = ["192.168.161.101", "192.168.161.102", "192.168.161.103"]
  description = "DNS Server"
}

# -----------------------------------------------------------------------------
# DEV VM Ressourcen
# -----------------------------------------------------------------------------

variable "vm_cpu" {
  type        = number
  default     = 4
  description = "vCPUs pro DEV Node"
}

variable "vm_memory_mb" {
  type        = number
  default     = 12288  # 12 GB
  description = "RAM in MB pro DEV Node"
}

variable "vm_disk_gb" {
  type        = number
  default     = 384
  description = "Disk-Größe in GB pro DEV Node"
}
