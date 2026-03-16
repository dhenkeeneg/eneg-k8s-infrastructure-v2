# TEST Environment - OpenTofu/Terraform

Erstellt die 3 TEST-Cluster VMs auf vCenter-A (VLAN 179).

## Nutzung

```bash
# Auf k8s-mgmt-10:
cd ~/git/eneg-k8s-infrastructure-v2/terraform/environments/test
cp credentials.example.tfvars credentials.auto.tfvars
# Passwort in credentials.auto.tfvars eintragen

tofu init
tofu plan -var-file="credentials.auto.tfvars"
tofu apply -var-file="credentials.auto.tfvars"
```

## VMs

| VM | IP | Host | Datastore |
|----|-----|------|-----------|
| k8s-test-21 | 192.168.179.21 | s2842.eneg.de | S2842_SSD_01_VMS |
| k8s-test-22 | 192.168.179.22 | s2843.eneg.de | S2843_SSD_01_VMS |
| k8s-test-23 | 192.168.179.23 | s3168.eneg.de | S3168_SSD_01_VMS |

## Ressourcen

- 6 vCPU, 16 GB RAM, 512 GB Disk pro Node
- Ubuntu 24.04.4 LTS (Template: ubuntu-24.04-k8s-template)
- VLAN 179, Gateway: 192.168.179.247
