# =============================================================================
# TEST Environment - Outputs
# =============================================================================

output "test_nodes" {
  value = {
    "k8s-test-21" = {
      ip       = module.k8s_test_21.ip_address
      hostname = module.k8s_test_21.hostname
      host     = "s2842.eneg.de"
    }
    "k8s-test-22" = {
      ip       = module.k8s_test_22.ip_address
      hostname = module.k8s_test_22.hostname
      host     = "s2843.eneg.de"
    }
    "k8s-test-23" = {
      ip       = module.k8s_test_23.ip_address
      hostname = module.k8s_test_23.hostname
      host     = "s3168.eneg.de"
    }
  }
  description = "TEST Cluster Nodes (alle in vcenter-a.eneg.de)"
}

output "ssh_commands" {
  value = <<-EOT
    # SSH zu den TEST Nodes:
    ssh admin-ubuntu@192.168.179.21  # k8s-test-21 (s2842)
    ssh admin-ubuntu@192.168.179.22  # k8s-test-22 (s2843)
    ssh admin-ubuntu@192.168.179.23  # k8s-test-23 (s3168)
  EOT
  description = "SSH Befehle fuer TEST Nodes"
}
