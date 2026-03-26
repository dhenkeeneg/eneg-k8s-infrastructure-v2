# PROD Environment - OpenTofu/Terraform

## Uebersicht

| Parameter | Wert |
|-----------|------|
| VLAN | 178 |
| Netzwerk | 192.168.178.0/24 |
| Gateway | 192.168.178.247 |
| Nodes | k8s-prod-21/22/23 |
| vCPU/Node | 8 |
| RAM/Node | 24 GB (24576 MB) |
| Disk/Node | 768 GB |

## VM-Verteilung

| Host | VM | Datastore |
|------|----|-----------|
| s2842 | k8s-prod-21 | S2842_SSD_01_VMS |
| s2843 | k8s-prod-22 | S2843_SSD_01_VMS |
| s3168 | k8s-prod-23 | S3168_SSD_01_VMS |

## Ausfuehrung

```bash
# Auf k8s-mgmt-10:
cd ~/git/eneg-k8s-infrastructure-v2/terraform/environments/prod

# Credentials-Datei erstellen (einmalig):
cp credentials.example.tfvars credentials.auto.tfvars
# -> Passwort eintragen

tofu init
tofu plan
tofu apply
```
