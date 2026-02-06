# =============================================================================
# DEV Environment - VM Ordner
# =============================================================================
# Die Ordnerstruktur wird in beiden vCentern erstellt:
#   eNeG-VM-K8s/
#   └── DEV/
# =============================================================================

# -----------------------------------------------------------------------------
# vCenter Legacy - Ordnerstruktur
# -----------------------------------------------------------------------------

resource "vsphere_folder" "k8s_root_legacy" {
  provider = vsphere.vcenter_legacy

  path          = "eNeG-VM-K8s"
  type          = "vm"
  datacenter_id = data.vsphere_datacenter.dc_legacy.id
}

resource "vsphere_folder" "k8s_dev_legacy" {
  provider = vsphere.vcenter_legacy

  path          = "${vsphere_folder.k8s_root_legacy.path}/DEV"
  type          = "vm"
  datacenter_id = data.vsphere_datacenter.dc_legacy.id

  depends_on = [vsphere_folder.k8s_root_legacy]
}

# -----------------------------------------------------------------------------
# vCenter-A - Ordnerstruktur
# -----------------------------------------------------------------------------

resource "vsphere_folder" "k8s_root_a" {
  provider = vsphere.vcenter_a

  path          = "eNeG-VM-K8s"
  type          = "vm"
  datacenter_id = data.vsphere_datacenter.dc_a.id
}

resource "vsphere_folder" "k8s_dev_a" {
  provider = vsphere.vcenter_a

  path          = "${vsphere_folder.k8s_root_a.path}/DEV"
  type          = "vm"
  datacenter_id = data.vsphere_datacenter.dc_a.id

  depends_on = [vsphere_folder.k8s_root_a]
}

# -----------------------------------------------------------------------------
# Data Sources für Datacenters
# -----------------------------------------------------------------------------

data "vsphere_datacenter" "dc_legacy" {
  provider = vsphere.vcenter_legacy
  name     = "eNeG"
}

data "vsphere_datacenter" "dc_a" {
  provider = vsphere.vcenter_a
  name     = "eNeG-Datacenter"
}
