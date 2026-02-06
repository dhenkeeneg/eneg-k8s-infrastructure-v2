# VM Module

Erstellt eine virtuelle Maschine aus einem vSphere-Template.

## Verwendung

```hcl
module "my_vm" {
  source = "../../modules/vm"

  providers = {
    vsphere = vsphere.vcenter_a  # oder vsphere.vcenter_legacy
  }

  # vCenter Einstellungen
  datacenter    = "eNeG-Datacenter"
  host          = "s2843.eneg.de"
  datastore     = "S2843_SSD_01_VMS"
  network       = "VT 180 - K8s Dev"
  template_name = "ubuntu-24.04-k8s-template"
  folder        = "K8s-DEV"

  # VM Konfiguration
  vm_name    = "my-vm"
  hostname   = "my-vm"
  domain     = "eneg.de"
  cpu        = 4
  memory     = 12288  # MB
  disk_size  = 384    # GB

  # Netzwerk
  ip_address  = "192.168.180.100"
  gateway     = "192.168.180.247"
  dns_servers = ["192.168.161.101", "192.168.161.102"]
}
```

## Variablen

| Variable | Typ | Beschreibung | Default |
|----------|-----|--------------|---------|
| `datacenter` | string | vSphere Datacenter Name | - |
| `host` | string | ESXi Host Name | - |
| `datastore` | string | Datastore Name | - |
| `network` | string | Port Group Name | - |
| `template_name` | string | VM Template Name | - |
| `folder` | string | VM Folder | - |
| `vm_name` | string | VM Name | - |
| `hostname` | string | Hostname (ohne Domain) | - |
| `domain` | string | Domain | eneg.de |
| `cpu` | number | Anzahl vCPUs | - |
| `memory` | number | RAM in MB | - |
| `disk_size` | number | Disk in GB | - |
| `ip_address` | string | Statische IP | - |
| `netmask` | number | Netzmaske (Prefix) | 24 |
| `gateway` | string | Gateway IP | - |
| `dns_servers` | list(string) | DNS Server | 192.168.161.101-103 |

## Outputs

| Output | Beschreibung |
|--------|--------------|
| `vm_id` | vSphere VM ID |
| `vm_name` | VM Name |
| `ip_address` | IP-Adresse |
| `hostname` | FQDN |
