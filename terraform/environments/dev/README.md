# =============================================================================
# DEV Environment - README
# =============================================================================

# DEV Kubernetes Cluster

Erstellt 3 VMs für den DEV K3s-Cluster.

## VM-Verteilung

| VM | Host | vCenter | IP | Datastore |
|----|------|---------|-----|-----------|
| k8s-dev-21 | s2842.eneg.de | vcenter.eneg.de | 192.168.180.21 | S2842_D08-10_R5_SSD_K8s |
| k8s-dev-22 | s2843.eneg.de | vcenter-a.eneg.de | 192.168.180.22 | S2843_SSD_01_VMS |
| k8s-dev-23 | s3168.eneg.de | vcenter-a.eneg.de | 192.168.180.23 | S3168_SSD_01_VMS |

## Ressourcen pro VM

- **vCPU:** 4
- **RAM:** 12 GB
- **Disk:** 384 GB

## Voraussetzungen

1. VM-Templates müssen in beiden vCentern existieren:
   - `ubuntu-24.04-k8s-template` in vcenter.eneg.de
   - `ubuntu-24.04-k8s-template` in vcenter-a.eneg.de

2. VM-Ordner-Struktur muss in beiden vCentern existieren:
   - `eNeG-VM-K8s/DEV`
   - (später: `eNeG-VM-K8s/TEST`, `eNeG-VM-K8s/PROD`)

3. DNS-Einträge sollten vorbereitet sein (optional, aber empfohlen)

## Verwendung

### 1. Credentials-Datei erstellen

```bash
cd terraform/environments/dev
cp credentials.example.tfvars credentials.auto.tfvars
nano credentials.auto.tfvars
```

### 2. OpenTofu initialisieren

```bash
tofu init
```

### 3. Plan prüfen

```bash
tofu plan
```

### 4. VMs erstellen

```bash
tofu apply
```

### 5. VMs löschen (falls nötig)

```bash
tofu destroy
```

## Hinweise

- Die Credentials-Datei (`credentials.auto.tfvars`) ist in `.gitignore` und wird NICHT committed
- Der vCenter-Benutzername muss exakt `OpenTofu@eneg.de` lauten (Groß-/Kleinschreibung beachten!)
- Nach dem Erstellen der VMs können diese per SSH erreicht werden:
  ```bash
  ssh admin-ubuntu@192.168.180.21
  ssh admin-ubuntu@192.168.180.22
  ssh admin-ubuntu@192.168.180.23
  ```
