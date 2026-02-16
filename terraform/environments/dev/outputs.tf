# =============================================================================
# DEV Environment - Outputs
# =============================================================================

output "dev_nodes" {
  value = {
    "k8s-dev-21" = {
      ip       = module.k8s_dev_21.ip_address
      hostname = module.k8s_dev_21.hostname
      host     = "s2842.eneg.de"
    }
    "k8s-dev-22" = {
      ip       = module.k8s_dev_22.ip_address
      hostname = module.k8s_dev_22.hostname
      host     = "s2843.eneg.de"
    }
    "k8s-dev-23" = {
      ip       = module.k8s_dev_23.ip_address
      hostname = module.k8s_dev_23.hostname
      host     = "s3168.eneg.de"
    }
  }
  description = "DEV Cluster Nodes (alle in vcenter-a.eneg.de)"
}

output "ssh_commands" {
  value = <<-EOT
    # SSH zu den DEV Nodes:
    ssh admin-ubuntu@192.168.180.21  # k8s-dev-21 (s2842)
    ssh admin-ubuntu@192.168.180.22  # k8s-dev-22 (s2843)
    ssh admin-ubuntu@192.168.180.23  # k8s-dev-23 (s3168)
  EOT
  description = "SSH Befehle für DEV Nodes"
}
