# Phase 3b: SOPS + Age Secret Management - Abschlussdokument

**Status:** ✅ Abgeschlossen  
**Abgeschlossen am:** 10.02.2026  
**Dauer:** < 1 Stunde  
**Umgebung:** DEV (K3s Cluster)

---

## Zusammenfassung

Phase 3b wurde erfolgreich abgeschlossen. SOPS + Age ist eingerichtet und funktioniert. Secrets können jetzt verschlüsselt in Git gespeichert werden. Das ArgoCD Repository Secret ist bereits verschlüsselt und das IONOS API Secret ist vorbereitet für Phase 4.

---

## Erreichte Ziele

### Age Key-Pair
- ✅ **Age Key generiert:** Auf Management-VM (.age/key.txt)
- ✅ **Public Key:** age1fdqtcha9jnzqafe5t6hed6v5sv858x2tt6nwuw00u3luyxuaqcxqh5mcrm
- ✅ **Private Key geschützt:** .gitignore verhindert Git-Commit
- ✅ **Speicherort:** ~/.age/key.txt (nur Management-VM)

### SOPS Konfiguration
- ✅ **.sops.yaml:** Verschlüsselungsregeln definiert
- ✅ **Drei Regeln:** kubernetes/secrets, .enc.yaml, credentials
- ✅ **encrypted_regex:** Nur stringData/data verschlüsselt (metadata lesbar)
- ✅ **Age Integration:** Public Key in allen Regeln

### Verschlüsselte Secrets
- ✅ **ArgoCD Repository Secret:** Verschlüsselt und in Git
- ✅ **IONOS API Secret:** Template vorbereitet für Phase 4
- ✅ **Alle PLACEHOLDER:** Durch echte Werte ersetzt
- ✅ **Git-sicher:** Nur verschlüsselte Versionen committed

### Dokumentation
- ✅ **SOPS-SECRET-MANAGEMENT.md:** Vollständige Nutzungsanleitung
- ✅ **Workflows:** Verschlüsseln, Entschlüsseln, Bearbeiten dokumentiert
- ✅ **Best Practices:** DOs und DON'Ts klar definiert
- ✅ **Troubleshooting:** Häufige Fehler und Lösungen

### .gitignore Update
- ✅ **Age Keys:** .age/ Directory komplett geschützt
- ✅ **Pattern:** *.age.key, *-key.txt ausgeschlossen
- ✅ **Public Keys:** !*.pub erlaubt (nur Public Keys in Git)

---

## Technische Details

### Age Key-Pair Generation

**Command:**
```bash
age-keygen -o .age/key.txt
```

**Output:**
```
Public key: age1fdqtcha9jnzqafe5t6hed6v5sv858x2tt6nwuw00u3luyxuaqcxqh5mcrm
```

**Speicherort:**
- Management-VM: `~/git/eneg-k8s-infrastructure-v2/.age/key.txt`
- **Nicht auf Windows/Mac** - nur auf Management-VM!

### SOPS Konfiguration (.sops.yaml)

```yaml
creation_rules:
  # Regel 1: Alle Secrets in kubernetes/
  - path_regex: kubernetes/.*/secrets/.*\.yaml$
    encrypted_regex: ^(data|stringData)$
    age: age1fdqtcha9jnzqafe5t6hed6v5sv858x2tt6nwuw00u3luyxuaqcxqh5mcrm

  # Regel 2: Alle .enc.yaml Dateien
  - path_regex: .*\.enc\.yaml$
    encrypted_regex: ^(data|stringData|spec)$
    age: age1fdqtcha9jnzqafe5t6hed6v5sv858x2tt6nwuw00u3luyxuaqcxqh5mcrm

  # Regel 3: Terraform/Ansible Credentials
  - path_regex: (terraform|ansible)/.*credentials.*\.yaml$
    age: age1fdqtcha9jnzqafe5t6hed6v5sv858x2tt6nwuw00u3luyxuaqcxqh5mcrm
```

**Wichtig:** `encrypted_regex` verschlüsselt nur bestimmte Felder - metadata bleibt lesbar für Git Diffs!

### ArgoCD Repository Secret Verschlüsselung

**Workflow:**

1. **SSH Key kopieren:**
```bash
scp C:\Users\dhenke\.ssh\argocd-deploy-key admin-ubuntu@192.168.180.10:~/.ssh/
```

2. **Secret erstellen mit korrekter YAML-Formatierung:**
```bash
cat > kubernetes/base/argocd/secrets/repository-secret.enc.yaml << EOF
apiVersion: v1
kind: Secret
metadata:
  name: repo-eneg-k8s-infrastructure-v2
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repository
type: Opaque
stringData:
  type: git
  url: git@github.com:dhenkeeneg/eneg-k8s-infrastructure-v2.git
  sshPrivateKey: |
$(cat ~/.ssh/argocd-deploy-key | sed 's/^/    /')
EOF
```

**Wichtig:** `sed 's/^/    /'` fügt 4 Spaces vor jede Zeile ein - korrekte YAML-Einrückung!

3. **Verschlüsseln:**
```bash
export SOPS_AGE_KEY_FILE=.age/key.txt
sops -e -i kubernetes/base/argocd/secrets/repository-secret.enc.yaml
```

**Ergebnis:** SSH Private Key ist jetzt verschlüsselt in Git!

### Verschlüsseltes Secret Format

**Vorher (unverschlüsselt):**
```yaml
stringData:
  sshPrivateKey: |
    -----BEGIN OPENSSH PRIVATE KEY-----
    b3BlbnNzaC1r...
    -----END OPENSSH PRIVATE KEY-----
```

**Nachher (verschlüsselt):**
```yaml
stringData:
  sshPrivateKey: ENC[AES256_GCM,data:Hs+...,iv:...,tag:...,type:str]
sops:
  kms: []
  gcp_kms: []
  azure_kv: []
  age:
    - recipient: age1fdqtcha9jnzqafe5t6hed6v5sv858x2tt6nwuw00u3luyxuaqcxqh5mcrm
      enc: |
        -----BEGIN AGE ENCRYPTED FILE-----
        YWdlLWVuY3J5cHRpb24ub3JnL3YxCi0+IFgyNTUxOSBx...
        -----END AGE ENCRYPTED FILE-----
  version: 3.9.2
```

**metadata bleibt lesbar** - nur stringData ist verschlüsselt!

---

## Wichtige Learnings

### 1. YAML Multi-Line String Einrückung

**Problem:** SSH Key als mehrzeilige Strings in YAML

**Falsch:**
```yaml
sshPrivateKey: |
-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaC1r...
```

**Richtig:**
```yaml
sshPrivateKey: |
    -----BEGIN OPENSSH PRIVATE KEY-----
    b3BlbnNzaC1r...
```

**Lösung:** Pipe-Symbol `|` + 4 Spaces Einrückung für jede Folgezeile

**Automatisch:** `sed 's/^/    /'` fügt Einrückung ein

### 2. encrypted_regex für selektive Verschlüsselung

**Warum:** metadata sollte lesbar bleiben für Git Diffs

**Best Practice:**
```yaml
encrypted_regex: ^(data|stringData)$
```

Verschlüsselt nur:
- `data:` Feld (base64-encoded Secrets)
- `stringData:` Feld (plain-text Secrets)

**Bleibt lesbar:**
- `metadata.name`
- `metadata.namespace`
- `metadata.labels`

**Vorteil:** Git Diff zeigt welches Secret geändert wurde (Name), aber nicht den Inhalt

### 3. Age Key Sicherheit

**DO ✅:**
- Private Key nur auf Management-VM
- .gitignore schützt .age/ Directory
- Backup von Private Key (extern, nicht in Git!)

**DON'T ❌:**
- Private Key auf Workstations kopieren
- Private Key in Git committen
- Private Key per Slack/Email teilen

**Backup-Strategie:** Private Key manuell auf NAS/USB speichern (außerhalb Git!)

### 4. SOPS Environment Variable

**Wichtig:** Vor jedem SOPS-Befehl setzen!

```bash
export SOPS_AGE_KEY_FILE=.age/key.txt
```

**Alternativ:** In ~/.bashrc auf Management-VM:
```bash
echo 'export SOPS_AGE_KEY_FILE=~/git/eneg-k8s-infrastructure-v2/.age/key.txt' >> ~/.bashrc
```

**Ohne Environment Variable:** `error: no key could be found to encrypt`

---

## Workflow Cheat Sheet

### Secret verschlüsseln

```bash
cd ~/git/eneg-k8s-infrastructure-v2
export SOPS_AGE_KEY_FILE=.age/key.txt

# Datei erstellen/bearbeiten
nano kubernetes/base/cert-manager/secrets/ionos-secret.enc.yaml

# Verschlüsseln
sops -e -i kubernetes/base/cert-manager/secrets/ionos-secret.enc.yaml

# Committen
git add kubernetes/base/cert-manager/secrets/ionos-secret.enc.yaml
git commit -m "Encrypt IONOS API secret"
git push
```

### Secret entschlüsseln und bearbeiten

```bash
export SOPS_AGE_KEY_FILE=.age/key.txt

# SOPS öffnet Editor, nach Speichern automatisch verschlüsselt
sops kubernetes/base/argocd/secrets/repository-secret.enc.yaml
```

### Secret entschlüsselt anzeigen

```bash
export SOPS_AGE_KEY_FILE=.age/key.txt

# Nur anzeigen, nicht bearbeiten
sops -d kubernetes/base/argocd/secrets/repository-secret.enc.yaml
```

### Secret in Cluster deployen

```bash
export SOPS_AGE_KEY_FILE=.age/key.txt

# Entschlüsseln on-the-fly und deployen
sops -d kubernetes/base/argocd/secrets/repository-secret.enc.yaml | kubectl apply -f -
```

---

## Repository-Struktur

```
eneg-k8s-infrastructure-v2/
├── .sops.yaml                          # SOPS Konfiguration
├── .gitignore                          # .age/ geschützt
├── .age/
│   └── key.txt                         # Private Key (NICHT in Git!)
├── docs/
│   └── SOPS-SECRET-MANAGEMENT.md      # Vollständige Dokumentation
└── kubernetes/
    └── base/
        ├── argocd/
        │   └── secrets/
        │       └── repository-secret.enc.yaml  # ✅ Verschlüsselt
        └── cert-manager/
            └── secrets/
                └── ionos-secret.enc.yaml       # Template (Phase 4)
```

---

## Troubleshooting-Erfahrungen

### Problem: YAML Parse Error

**Symptom:**
```
Error unmarshalling file: yaml: line 15: could not find expected ':'
```

**Ursache:** Falsche Einrückung bei mehrzeiligen Strings

**Lösung:** `sed 's/^/    /'` für automatische 4-Space Einrückung

### Problem: no key could be found to encrypt

**Symptom:**
```
error: no key could be found to encrypt
```

**Ursache:** `SOPS_AGE_KEY_FILE` Environment Variable nicht gesetzt

**Lösung:**
```bash
export SOPS_AGE_KEY_FILE=.age/key.txt
```

### Problem: MAC mismatch beim Entschlüsseln

**Symptom:**
```
Failed to decrypt: MAC mismatch
```

**Ursache:** Datei wurde nach Verschlüsselung manuell bearbeitet

**Lösung:** Neu verschlüsseln:
```bash
sops -d file.enc.yaml > file.yaml
nano file.yaml
sops -e file.yaml > file.enc.yaml
```

---

## Verwendete Versionen

| Tool | Version | Hinweis |
|------|---------|---------|
| SOPS | 3.11.0 | Auf Management-VM |
| Age | 1.1.1 | Auf Management-VM |
| SOPS Format | 3.9.2 | In verschlüsselten Files |

---

## Vorbereitete Secrets für Phase 4

### IONOS API Secret

**Datei:** `kubernetes/base/cert-manager/secrets/ionos-secret.enc.yaml`

**Status:** Template erstellt, noch nicht verschlüsselt

**Vor Phase 4 erledigen:**

```bash
cd ~/git/eneg-k8s-infrastructure-v2
export SOPS_AGE_KEY_FILE=.age/key.txt

# 1. Credentials aus 1Password holen
# IONOS_PUBLIC_PREFIX: publicpre-...
# IONOS_SECRET: secret...

# 2. In Secret einfügen
nano kubernetes/base/cert-manager/secrets/ionos-secret.enc.yaml
# PLACEHOLDER_PUBLIC_PREFIX ersetzen
# PLACEHOLDER_SECRET_KEY ersetzen

# 3. Verschlüsseln
sops -e -i kubernetes/base/cert-manager/secrets/ionos-secret.enc.yaml

# 4. Committen
git add kubernetes/base/cert-manager/secrets/ionos-secret.enc.yaml
git commit -m "Encrypt IONOS API secret for cert-manager"
git push
```

---

## Nächste Schritte

### Phase 4: Kubernetes-Basis

**Bereit für Installation:**
- ✅ SOPS eingerichtet
- ✅ IONOS Secret Template vorhanden
- ✅ ArgoCD läuft und ist bereit

**Phase 4 Komponenten:**
1. MetalLB (LoadBalancer) - keine Secrets
2. Traefik (Ingress) - keine Secrets initial
3. Cert-Manager + IONOS Webhook - **IONOS Secret verschlüsseln!**
4. Longhorn (Storage) - keine Secrets

**Vor Phase 4 Start:**
- [ ] IONOS Secret verschlüsseln (siehe oben)
- [ ] Test: Secret entschlüsseln und deployen

---

## Git Commits (Phase 3b)

1. `85df6bc` - Phase 3b: Setup SOPS + Age for secret management
2. `ec38c75` - Encrypt ArgoCD repository secret with SOPS

**Dateien:**
- `.sops.yaml` - SOPS Konfiguration
- `.gitignore` - Age Key Schutz
- `docs/SOPS-SECRET-MANAGEMENT.md` - Dokumentation
- `kubernetes/base/argocd/secrets/repository-secret.enc.yaml` - Verschlüsselt
- `kubernetes/base/cert-manager/secrets/ionos-secret.enc.yaml` - Template

---

## Best Practices Summary

### Security ✅
- ✅ Private Key nur auf Management-VM
- ✅ .gitignore schützt Private Keys
- ✅ Encrypted Secrets in Git (GitOps-konform)
- ✅ metadata lesbar (encrypted_regex)

### Workflow ✅
- ✅ SOPS_AGE_KEY_FILE Environment Variable
- ✅ `sops -e -i` für in-place Verschlüsselung
- ✅ `sops -d | kubectl apply` für Deployment
- ✅ Git als Single Source of Truth

### Documentation ✅
- ✅ Vollständige SOPS-Anleitung
- ✅ Troubleshooting-Guide
- ✅ Workflow Cheat Sheets
- ✅ Phase 3b Abschlussdokument

---

**Ende Phase 3b - Secret Management steht! Bereit für Phase 4!** 🔐🚀
