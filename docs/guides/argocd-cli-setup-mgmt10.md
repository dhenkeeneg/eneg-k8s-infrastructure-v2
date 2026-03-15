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

### Schritt 2: DNS-Aufloesung fuer ArgoCD einrichten

Da `argocd-dev-v2.eneg.de` vom mgmt-10 nicht direkt aufgeloest werden kann
(DNS zeigt auf die Traefik LB-IP), muss ein /etc/hosts Eintrag gesetzt werden:

```bash
echo "192.168.180.100 argocd-dev-v2.eneg.de" | sudo tee -a /etc/hosts
```

### Schritt 3: Admin-Passwort ermitteln

```bash
kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath='{.data.password}' | base64 -d; echo
```

### Schritt 4: Login

```bash
argocd login argocd-dev-v2.eneg.de --grpc-web --insecure
# Username: admin
# Password: <ausgelesenes Passwort aus Schritt 3>
```

**Hinweis:** Falls `--grpc-web --insecure` nicht funktioniert, alternative Optionen:

```bash
# Option A: Ohne gRPC-Web (direkter gRPC)
argocd login argocd-dev-v2.eneg.de --insecure

# Option B: Per Port-Forward (falls DNS/Netzwerk Probleme)
# Terminal 1:
kubectl port-forward svc/argocd-server -n argocd 8080:443
# Terminal 2:
argocd login localhost:8080 --insecure --plaintext
```

### Schritt 5: Login testen

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

# Einzelne App syncen (mit Prune)
argocd app sync garage --prune

# Alle Apps syncen
argocd app sync --all

# App-Status anzeigen
argocd app get garage

# Diff zwischen Git und Cluster anzeigen
argocd app diff garage

# Hard-Refresh (Cache invalidieren)
argocd app get garage --hard-refresh
```

### Shutdown/Maintenance Befehle

```bash
# Auto-Sync fuer eine App deaktivieren
argocd app patch garage --patch '{"spec":{"syncPolicy":null}}' --type merge

# Auto-Sync wieder aktivieren
argocd app patch garage --patch '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}' --type merge

# Auto-Sync fuer ALLE Apps deaktivieren (vor geplantem Shutdown)
for app in $(argocd app list -o name); do
  argocd app patch "$app" --patch '{"spec":{"syncPolicy":null}}' --type merge
done

# Auto-Sync fuer ALLE Apps wieder aktivieren (nach Startup)
argocd app sync --all
```

### Troubleshooting

```bash
# App-Logs anzeigen
argocd app logs garage

# Sync-Status und Health als JSON
argocd app get garage -o json | jq '.status.health, .status.sync'

# Alle Apps mit Problemen anzeigen
argocd app list --status OutOfSync
argocd app list --health Degraded
```

---

## Hinweise

- Der Login-Token laeuft nach 24 Stunden ab — erneut `argocd login` ausfuehren
- Bei /etc/hosts Eintrag: Muss bei IP-Aenderung der Traefik LB aktualisiert werden
- `--grpc-web` ist noetig wenn Traefik als Reverse Proxy vor ArgoCD steht
- `--insecure` ist noetig da das TLS-Zertifikat ggf. nicht vom CLI vertraut wird
- Fuer TEST/PROD Umgebungen spaeter separate /etc/hosts Eintraege und Logins einrichten

---

## Referenzen

- ArgoCD CLI Dokumentation: https://argo-cd.readthedocs.io/en/stable/user-guide/commands/argocd/
- ArgoCD Releases: https://github.com/argoproj/argo-cd/releases
