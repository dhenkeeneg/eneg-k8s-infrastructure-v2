# SOPS + Age Secret Management

Dieses Projekt verwendet [SOPS](https://github.com/getsops/sops) mit [Age](https://github.com/FiloSottile/age) für verschlüsselte Secret-Verwaltung in Git.

## Übersicht

**Warum SOPS + Age?**
- ✅ Secrets können verschlüsselt in Git gespeichert werden
- ✅ GitOps-konform (kein manuelles kubectl create secret)
- ✅ Versioniert und nachvollziehbar
- ✅ Einfacher als Vault für kleine Setups

**Verschlüsselung:**
- Secrets werden mit Age Public Key verschlüsselt
- Entschlüsselung nur mit Age Private Key möglich
- Private Key liegt NUR auf Management-VM und wird NICHT in Git committed

---

## Setup

### Age Key-Pair (einmalig - bereits erledigt)

```bash
# Key-Pair generieren (auf Management-VM)
mkdir -p .age
age-keygen -o .age/key.txt

# Public Key anzeigen
grep "public key:" .age/key.txt
```

**Wichtig:** Private Key `.age/key.txt` ist durch `.gitignore` geschützt!

---

## Verwendung

### Secret verschlüsseln

```bash
# 1. Unverschlüsseltes Secret erstellen/bearbeiten
nano kubernetes/base/argocd/secrets/repository-secret.enc.yaml

# 2. Mit SOPS verschlüsseln (verwendet .sops.yaml Config)
export SOPS_AGE_KEY_FILE=.age/key.txt
sops -e -i kubernetes/base/argocd/secrets/repository-secret.enc.yaml

# 3. In Git committen (jetzt verschlüsselt!)
git add kubernetes/base/argocd/secrets/repository-secret.enc.yaml
git commit -m "Add encrypted ArgoCD repository secret"
git push
```

### Secret entschlüsseln (zum Bearbeiten)

```bash
# Secret entschlüsseln und bearbeiten
export SOPS_AGE_KEY_FILE=.age/key.txt
sops kubernetes/base/argocd/secrets/repository-secret.enc.yaml

# SOPS öffnet Editor, nach Speichern wird automatisch verschlüsselt
```

### Secret anzeigen (ohne Bearbeiten)

```bash
# Entschlüsselt anzeigen
export SOPS_AGE_KEY_FILE=.age/key.txt
sops -d kubernetes/base/argocd/secrets/repository-secret.enc.yaml
```

### Secret in Cluster deployen

```bash
# Via kubectl (entschlüsselt on-the-fly)
export SOPS_AGE_KEY_FILE=.age/key.txt
sops -d kubernetes/base/argocd/secrets/repository-secret.enc.yaml | kubectl apply -f -

# Via ArgoCD (mit KSOPS Plugin - später)
# ArgoCD kann verschlüsselte Secrets automatisch entschlüsseln
```

---

## SOPS-Konfiguration (.sops.yaml)

Die `.sops.yaml` definiert, welche Dateien wie verschlüsselt werden:

```yaml
creation_rules:
  # Alle Secrets in kubernetes/*/secrets/
  - path_regex: kubernetes/.*/secrets/.*\.yaml$
    encrypted_regex: ^(data|stringData)$
    age: age1fdqtcha9jnzqafe5t6hed6v5sv858x2tt6nwuw00u3luyxuaqcxqh5mcrm

  # Alle .enc.yaml Dateien
  - path_regex: .*\.enc\.yaml$
    encrypted_regex: ^(data|stringData|spec)$
    age: age1fdqtcha9jnzqafe5t6hed6v5sv858x2tt6nwuw00u3luyxuaqcxqh5mcrm
```

**encrypted_regex:** Nur diese YAML-Felder werden verschlüsselt (metadata bleibt lesbar!)

---

## Vorhandene Secrets

### ArgoCD Repository Secret

**Datei:** `kubernetes/base/argocd/secrets/repository-secret.enc.yaml`

**Inhalt:**
- GitHub Repository URL
- SSH Private Key (für Deploy Key)

**Verschlüsseln:**
```bash
export SOPS_AGE_KEY_FILE=.age/key.txt

# 1. SSH Key aus Windows kopieren
cat /mnt/c/Users/dhenke/.ssh/argocd-deploy-key

# 2. In Secret einfügen (PLACEHOLDER ersetzen)
nano kubernetes/base/argocd/secrets/repository-secret.enc.yaml

# 3. Verschlüsseln
sops -e -i kubernetes/base/argocd/secrets/repository-secret.enc.yaml
```

### IONOS API Secret (für Phase 4)

**Datei:** `kubernetes/base/cert-manager/secrets/ionos-secret.enc.yaml`

**Inhalt:**
- IONOS_PUBLIC_PREFIX
- IONOS_SECRET

**Verschlüsseln:**
```bash
export SOPS_AGE_KEY_FILE=.age/key.txt

# 1. Credentials aus 1Password holen
# 2. In Secret einfügen (PLACEHOLDER ersetzen)
nano kubernetes/base/cert-manager/secrets/ionos-secret.enc.yaml

# 3. Verschlüsseln
sops -e -i kubernetes/base/cert-manager/secrets/ionos-secret.enc.yaml
```

---

## ArgoCD Integration (später)

Aktuell: Secrets manuell mit `sops -d | kubectl apply` deployen

**Phase 4+:** ArgoCD mit KSOPS Plugin für automatische Entschlüsselung:
- ArgoCD entschlüsselt Secrets automatisch beim Sync
- Age Key wird als Secret in ArgoCD hinterlegt
- Vollständig GitOps-konform

---

## Best Practices

### DO ✅
- Age Private Key nur auf Management-VM
- Secrets mit `.enc.yaml` Endung markieren
- `encrypted_regex` verwenden (nur Daten verschlüsseln, nicht metadata)
- Verschlüsselte Secrets in Git committen

### DON'T ❌
- Age Private Key in Git committen
- Age Private Key auf Workstations kopieren
- Unverschlüsselte Secrets committen
- metadata verschlüsseln (ArgoCD braucht name/namespace)

---

## Troubleshooting

### "no key could be found to encrypt"

**Problem:** SOPS findet den Age Key nicht

**Lösung:**
```bash
export SOPS_AGE_KEY_FILE=.age/key.txt
# oder
export SOPS_AGE_KEY_FILE=/home/admin-ubuntu/git/eneg-k8s-infrastructure-v2/.age/key.txt
```

### "MAC mismatch" beim Entschlüsseln

**Problem:** Datei wurde manuell bearbeitet nach Verschlüsselung

**Lösung:** Datei neu verschlüsseln:
```bash
sops -d file.enc.yaml > file.yaml
# Bearbeiten
nano file.yaml
# Neu verschlüsseln
sops -e file.yaml > file.enc.yaml
```

### Secret in Cluster nicht entschlüsselt

**Problem:** kubectl apply ohne SOPS

**Lösung:**
```bash
# Falsch:
kubectl apply -f secret.enc.yaml

# Richtig:
sops -d secret.enc.yaml | kubectl apply -f -
```

---

## Referenzen

- [SOPS Documentation](https://github.com/getsops/sops)
- [Age Documentation](https://github.com/FiloSottile/age)
- [KSOPS (ArgoCD Plugin)](https://github.com/viaduct-ai/kustomize-sops)
