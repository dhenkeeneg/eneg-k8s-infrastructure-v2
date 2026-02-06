# =============================================================================
# VM Module - Variables
# =============================================================================

variable "datacenter" {
  type        = string
  description = "vSphere Datacenter Name"
}

variable "host" {
  type        = string
  description = "ESXi Host Name"
}

variable "datastore" {
  type        = string
  description = "Datastore Name"
}

variable "network" {
  type        = string
  description = "Network/Port Group Name"
}

variable "template_name" {
  type        = string
  description = "Name des VM Templates"
}

variable "folder" {
  type        = string
  description = "VM Folder in vCenter (z.B. 'eNeG-VM-K8s/DEV')"
}

variable "vm_name" {
  type        = string
  description = "Name der VM"
}

variable "hostname" {
  type        = string
  description = "Hostname der VM (ohne Domain)"
}

variable "domain" {
  type        = string
  default     = "eneg.de"
  description = "Domain für die VM"
}

variable "cpu" {
  type        = number
  description = "Anzahl vCPUs"
}

variable "memory" {
  type        = number
  description = "RAM in MB"
}

variable "disk_size" {
  type        = number
  description = "Disk-Größe in GB"
}

variable "ip_address" {
  type        = string
  description = "Statische IP-Adresse"
}

variable "netmask" {
  type        = number
  default     = 24
  description = "Netzmaske als Prefix-Länge"
}

variable "gateway" {
  type        = string
  description = "Gateway IP"
}

variable "dns_servers" {
  type        = list(string)
  default     = ["192.168.161.101", "192.168.161.102", "192.168.161.103"]
  description = "DNS Server Liste"
}

variable "dns_suffix_list" {
  type        = list(string)
  default     = ["eneg.de"]
  description = "DNS Search Domains"
}

variable "use_guest_customization" {
  type        = bool
  default     = true
  description = "VMware Guest Customization verwenden (false für ESXi 6.7 mit Ubuntu 24.04)"
}

variable "cloud_init_userdata" {
  type        = string
  default     = ""
  description = "Cloud-init user-data (nur wenn use_guest_customization=false)"
}
