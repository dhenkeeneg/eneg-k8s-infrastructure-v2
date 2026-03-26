# =============================================================================
# PROD Environment - Outputs
# =============================================================================

output "prod_nodes" {
  value = {
    "k8s-prod-21" = {
      ip       = module.k8s_prod_21.ip_address
      hostname = module.k8s_prod_21.hostname
      host     = "s2842.eneg.de"
    }
    "k8s-prod-22" = {
      ip       = module.k8s_prod_22.ip_address
      hostname = module.k8s_prod_22.hostname
      host     = "s2843.eneg.de"
    }
    "k8s-prod-23" = {
      ip       = module.k8s_prod_23.ip_address
      hostname = module.k8s_prod_23.hostname
      host     = "s3168.eneg.de"
    }
  }
  description = "PROD Cluster Nodes (alle in vcenter-a.eneg.de)"
}

output "ssh_commands" {
  value = <<-EOT
    # SSH zu den PROD Nodes:
    ssh admin-ubuntu@192.168.178.21  # k8s-prod-21 (s2842)
    ssh admin-ubuntu@192.168.178.22  # k8s-prod-22 (s2843)
    ssh admin-ubuntu@192.168.178.23  # k8s-prod-23 (s3168)
  EOT
  description = "SSH Befehle fuer PROD Nodes"
}
