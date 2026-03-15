# ArgoCD CLI Installation und Einrichtung auf k8s-mgmt-10

## Chat-Anweisung fuer die Installation der ArgoCD CLI auf dem Management-Server

**Erstellt:** 15.03.2026
**Server:** k8s-mgmt-10 (192.168.180.10)
**Geschaetzter Aufwand:** 15 Minuten

---

## Hintergrund

Die ArgoCD CLI ermoeglicht direkte Verwaltung der ArgoCD-Instanz vom Management-Server aus,
ohne das Web-UI nutzen zu muessen. Nuetzlich fuer:
- Batch-Sync aller Applications (`argocd app sync --all`)
- App-Status pruefen (`argocd app list`)
- Schnelles Debugging (`argocd app diff <app>`)
- Geplante Shutdowns (Sync-Policies deaktivieren/reaktivieren)

---

## Installationsschritte

### Schritt 1: ArgoCD CLI herunterladen und installieren

```bash
# Aktuelle stable Version herunterladen
curl -sSL -o argocd https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64
chmod +x argocd
sudo mv argocd /usr/local/bin/

# Version pruefen
argocd version --client
```

### Schritt 2: Login konfigurieren

Da `argocd.eneg.de` vom mgmt-10 nicht aufgeloest werden kann (DNS zeigt auf die
Traefik LB-IP 192.168.180.100), gibt es zwei Optionen:

**Option A: /etc/hosts Eintrag (empfohlen, dauerhaft)**

```bash
# Traefik LB-IP fuer ArgoCD-Hostname setzen
echo "192.168.180.100 argocd-dev-v2.eneg.de" | sudo tee -a /etc/hosts

# Login
argocd login argocd-dev-v2.eneg.de --grpc-web --insecure
```

**Option B: Port-Forward (temporaer)**

```bash
# Terminal 1: Port-Forward starten
kubectl port-forward svc/argocd-server -n argocd 8080:443 &

# Terminal 2: Login
argocd login localhost:8080 --insecure
```

### Schritt 3: Admin-Passwort ermitteln

```bash
# Initial-Admin-Passwort auslesen
kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath='{.data.password}' | base64 -d; echo

# Login mit Username "admin" und dem ausgelesenen Passwort
argocd login argocd-dev-v2.eneg.de --grpc-web --insecure
# Username: admin
# Password: <ausgelesenes Passwort>
```

### Schritt 4: Login testen

```bash
# Alle Apps auflisten
argocd app list

# Cluster-Info
argocd cluster list
```

---

## Haeufig verwendete Befehle

### App-Verwaltung

```bash
# Alle Apps auflisten
argocd app list

# Einzelne App syncen
argocd app sync garage --prune

# Alle Apps syncen
argocd app sync --all

# App-Status anzeigen
argocd app get garage

# Diff zwischen Git und Cluster anzeigen
argocd app diff garage
```

### Shutdown/Maintenance

```bash
# Auto-Sync fuer eine App deaktivieren
argocd app patch garage --patch '{"spec":{"syncPolicy":null}}' --type merge

# Auto-Sync wieder aktivieren
argocd app patch garage --patch '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}' --type merge

# Auto-Sync fuer alle Apps deaktivieren (vor Shutdown)
for app in $(argocd app list -o name); do
  argocd app patch "$app" --patch '{"spec":{"syncPolicy":null}}' --type merge
done
```

### Troubleshooting

```bash
# App-Logs anzeigen
argocd app logs garage

# Sync-Status und Health pruefen
argocd app get garage -o json | jq '.status.health, .status.sync'

# Hard-Refresh (Cache invalidieren)
argocd app get garage --hard-refresh
```

---

## Hinweise

- Der Login-Token laeuft nach 24 Stunden ab — erneut `argocd login` ausfuehren
- Bei Nutzung von Option A (/etc/hosts): Eintrag muss bei IP-Aenderung aktualisiert werden
- `--grpc-web` ist noetig wenn Traefik als Reverse Proxy vor ArgoCD steht
- `--insecure` ist noetig da wir ein self-signed oder Let's Encrypt Staging Zertifikat haben koennen

---

## Referenzen

- ArgoCD CLI Dokumentation: https://argo-cd.readthedocs.io/en/stable/user-guide/commands/argocd/
- ArgoCD Releases: https://github.com/argoproj/argo-cd/releases
