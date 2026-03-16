# =============================================================================
# VM Ordner fuer TEST Environment
# =============================================================================
# Ordnerstruktur in vCenter-A:
#   eNeG-VM-K8s/
#   ├── DEV/    (bereits vorhanden)
#   ├── TEST/   (bereits vorhanden)
#   └── PROD/   (bereits vorhanden)
#
# HINWEIS: Die Ordner existieren bereits in vCenter-A.
# Wir verwenden data sources statt resources, um sie zu referenzieren.
# Bei Bedarf koennen die Ordner manuell importiert werden:
#   tofu import vsphere_folder.k8s_test "eNeG-VM-K8s/TEST"
# =============================================================================

data "vsphere_datacenter" "dc" {
  name = var.datacenter
}
