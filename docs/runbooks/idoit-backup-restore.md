# Runbook: i-doit Backup-Restore (Tarball-basiert, Phase 2)

**Status:** Active
**Letzte Aktualisierung:** 17.05.2026
**Gilt fuer:** DEV (verifiziert), TEST und PROD (GitOps-konfiguriert, Erst-Lauf
nach Cluster-Reaktivierung steht aus).

## Kontext

Seit Phase 2 sichert der `idoit-backup`-CronJob die i-doit-Daten als komprimierte Tarballs auf NAS10 (QNAP QuObjects S3):

- `nas10:k8s-{env}-idoit/upload/upload-YYYY-MM-DD.tar.gz` (taeglich, skip wenn leer)
- `nas10:k8s-{env}-idoit/src/src-YYYY-MM-DD.tar.gz` (Sonntags + bei BACKUP_FORCE_SRC=yes)

Retention: 7 Tage via `rclone delete --min-age 7d`.

## Wann was wiederherstellen

- **upload/**: User-Uploads in i-doit (CMDB-Anhaenge, Bilder, Dokumente)
- **src/**: i-doit Source-Code + Konfiguration (z.B. nach fehlgeschlagenem Update)

Niemals beides parallel ueber den laufenden i-doit-Pod zuruecksichern, da das PVC dann inkonsistent werden kann. Stattdessen i-doit vorher herunterskalieren.

## Restore-Verfahren (Kubernetes-nativ)

### Schritt 1: i-doit-Deployment herunterfahren

```bash
kubectl --context k8s-{env} -n idoit scale deployment idoit --replicas=0
kubectl --context k8s-{env} -n idoit get pods   # Warten bis idoit-Pod weg ist
```

### Schritt 2: Restore-Pod starten (PVC read-write mounten)

Erstelle eine temporaere Pod-Spec, die die ZIEL-Subpfade rw mountet:

```bash
cat <<'EOF' | kubectl --context k8s-{env} -n idoit apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: idoit-restore
  labels:
    app: idoit-restore
spec:
  restartPolicy: Never
  containers:
    - name: rclone
      image: rclone/rclone:1.73.1
      command: ["sleep", "3600"]
      env:
        - name: RCLONE_CONFIG_NAS10_ACCESS_KEY_ID
          valueFrom:
            secretKeyRef:
              name: idoit-backup-credentials
              key: NAS10_ACCESS_KEY_ID
        - name: RCLONE_CONFIG_NAS10_SECRET_ACCESS_KEY
          valueFrom:
            secretKeyRef:
              name: idoit-backup-credentials
              key: NAS10_SECRET_ACCESS_KEY
      volumeMounts:
        - name: config
          mountPath: /config/rclone.conf
          subPath: rclone.conf
          readOnly: true
        - name: idoit-data-upload
          mountPath: /restore/upload
          subPath: upload
        - name: idoit-data-src
          mountPath: /restore/src
          subPath: src
  volumes:
    - name: config
      configMap:
        name: idoit-backup-config
        items:
          - key: rclone.conf
            path: rclone.conf
    - name: idoit-data-upload
      persistentVolumeClaim:
        claimName: idoit-data
    - name: idoit-data-src
      persistentVolumeClaim:
        claimName: idoit-data
EOF

kubectl --context k8s-{env} -n idoit wait --for=condition=Ready pod/idoit-restore --timeout=60s
```

### Schritt 3: Verfuegbare Backups listen

```bash
kubectl --context k8s-{env} -n idoit exec idoit-restore -- \
  rclone --config /config/rclone.conf ls nas10:k8s-{env}-idoit/upload/
kubectl --context k8s-{env} -n idoit exec idoit-restore -- \
  rclone --config /config/rclone.conf ls nas10:k8s-{env}-idoit/src/
```

### Schritt 4: Gewuenschten Tarball herunterladen und entpacken

Beispiel: Upload-Stand vom 16.05.2026:

```bash
BACKUP_DATE=2026-05-16   # Anpassen

# Upload
kubectl --context k8s-{env} -n idoit exec idoit-restore -- sh -c "
  rclone --config /config/rclone.conf copyto nas10:k8s-{env}-idoit/upload/upload-${BACKUP_DATE}.tar.gz /tmp/upload.tar.gz && \
  tar -tzf /tmp/upload.tar.gz | head    # Integrity-Check + Inhalt antasten
"

# Aktuellen upload-Inhalt sichern, danach leeren und neuen Stand entpacken
kubectl --context k8s-{env} -n idoit exec idoit-restore -- sh -c "
  mv /restore/upload /restore/upload.preRestore.$(date +%s) 2>/dev/null || true
  mkdir -p /restore/upload
  tar -xzf /tmp/upload.tar.gz -C /restore/upload
  ls -la /restore/upload | head
"
```

Analog fuer src (nur bei kompromittierter Code-Basis):

```bash
kubectl --context k8s-{env} -n idoit exec idoit-restore -- sh -c "
  rclone --config /config/rclone.conf copyto nas10:k8s-{env}-idoit/src/src-${BACKUP_DATE}.tar.gz /tmp/src.tar.gz && \
  tar -tzf /tmp/src.tar.gz | head
"

kubectl --context k8s-{env} -n idoit exec idoit-restore -- sh -c "
  mv /restore/src /restore/src.preRestore.$(date +%s) 2>/dev/null || true
  mkdir -p /restore/src
  tar -xzf /tmp/src.tar.gz -C /restore/src
"
```

### Schritt 5: Restore-Pod entfernen, i-doit wieder hochfahren

```bash
kubectl --context k8s-{env} -n idoit delete pod idoit-restore
kubectl --context k8s-{env} -n idoit scale deployment idoit --replicas=1
kubectl --context k8s-{env} -n idoit rollout status deployment/idoit
```

### Schritt 6: Funktion verifizieren

- i-doit Login (Admin)
- CMDB-Anhang oeffnen (falls upload restored)
- Logbuch auf Fehler pruefen

## Restore von einem anderen Cluster

Cross-Environment-Restore (z.B. PROD-Backup nach DEV ziehen):

1. NAS10-Credentials und Bucket-Pfad anpassen (`k8s-prod-idoit` statt `k8s-dev-idoit`)
2. Restore-Pod-Spec entsprechend mit Quell-Bucket parametrisieren
3. Alle weiteren Schritte wie oben
4. **Wichtig:** i-doit-DB-Migration nach Bedarf (PROD->DEV: ggf. Datenbank-Owner und Tenant-Settings pruefen)

## Notfall-Restore ueber rclone vom Mgmt-Server

Falls der Cluster nicht erreichbar ist:

```bash
# Auf k8s-mgmt-10 oder einem anderen Host mit s3cmd/rclone und NAS10-Cred
rclone --config /path/to/rclone.conf ls nas10:k8s-dev-idoit/src/
rclone --config /path/to/rclone.conf copyto \
  nas10:k8s-dev-idoit/src/src-2026-05-18.tar.gz \
  /backup-export/src-2026-05-18.tar.gz
```

Dann manuell zur Disaster-Recovery-Umgebung kopieren.

## Aenderungshistorie

| Datum | Aenderung |
|------|-----------|
| 17.05.2026 | Initial fuer DEV (Phase 2 Tarball-Refactor). TEST + PROD Files identisch in Git (k8s-test-idoit / k8s-prod-idoit), Aktivierung mit erstem Cron-Lauf nach Cluster-Reaktivierung. |
