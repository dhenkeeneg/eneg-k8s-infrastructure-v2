# =============================================================================
# VM Module - Outputs
# =============================================================================

output "vm_id" {
  value       = vsphere_virtual_machine.vm.id
  description = "VM ID"
}

output "vm_name" {
  value       = vsphere_virtual_machine.vm.name
  description = "VM Name"
}

output "ip_address" {
  value       = var.ip_address
  description = "IP-Adresse der VM"
}

output "hostname" {
  value       = "${var.hostname}.${var.domain}"
  description = "FQDN der VM"
}
