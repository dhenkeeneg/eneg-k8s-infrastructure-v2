Wir arbeiten gemeinsam an diesem Projekt "eNeG K8s Infrastruktur OpenTofuAnsible". 
Es gibt drei verschiedenen Arbeitsumgebungen auf denen ich die Konfigurationen für die Server anpasse: 
- Einen Windows-Laptop mit Windows 11
- Einen MacMini
- Ein MacBook
Auf allen drei Umgebungen ist der Desktop-Commander eingerichtet und du hast Terminalzugriff und Dateizugriff direkt auf mein geclontes Git Repository. 
Pfad bei Windows ist: "C:\Users\dhenke\git\eneg-k8s-infrastructure-v2"
Der Pfad bei MacBook und MacMini ist jeweils: "/Users/danielhenke/git/eneg-k8s-infrastructure-v2"
Erstelle nötige Dateien und Änderungen eigenständig über Desktop-Commander aber in Absprache mit mir.

Wir arbeiten an der DEV Umgebung mit den folgenden Servern: k8s-dev-21, k8s-dev-22, k8s-dev-23
Die Server der Testumgebung werden dann heißen: k8s-test-21, k8s-test-22, k8s-test23
Die Server der Produktivumgebung werden dann heißen k8s-prod-21, k8s-prod-22, k8s-prod-23
Test- und Produktivumgebung werden in einer späteren Phase erst erstellt.

Du hast keinen direkten SSH Zugriff auf die Server. Dafür arbeiten wir per DevOps über GitHub und das lokale Repository auf dem Windows-Laptop oder den MacBook und MacMini.
Du führst keine Commit und Push Befehle selbst aus. Du gibst mir die entsprechenden Anweisungen und ich führe diese in einem gesonderten Terminal dann selbst aus.

Du führst keine Befehle auf dem Management-Server (k8s-mgmt-10 - 192.168.180.10) selbst aus. Wenn nötig, gibst du mir die entsprechenden Anweisungen und ich führe diese in einem gesonderten Terminal dann selbst aus. Immer wenn es möglich ist sollen die Anpassungen über GitOps laufen und nicht direkt auf den Servern.
Der Pfad zum Repository auf dem Managementserver (k8s-mgmt-10) ist: "~/git/eneg-k8s-infrastructure-v2"
Im Repository gibt es den /docs-Pfad. Darin sind alle Entscheidungen, die Projektplanung und der Projektfortschritt dokumentiert.
Lies die Dokumentation zu beginn des Chats und merke sie dir wenn möglich im Projektwissen.
Nach erfolgreichem Abschluss einer Phase wirst Du die Dokumentation entsprechend anpassen und erweitern.

---

## Aktueller Projektstand

Phasen 0-5 sind abgeschlossen. Lies zu Beginn folgende Dokumente:

1. `docs/K8s-GitOps-Infrastruktur-Projektplanung_v2.0.md` — Gesamtplanung
2. `docs/phases/README.md` — Phasen-Übersicht
3. `docs/phases/phase-05-abschluss.md` — Phase 5 Details (Datenbank-Cluster)

## Abgeschlossene Infrastruktur

**Cluster:** K3s v1.35.1+k3s1, 3-Node HA (k8s-dev-21/22/23), Ubuntu 24.04
**GitOps:** ArgoCD v3.3.0, App-of-Apps Pattern, SOPS/Age Secrets
**Netzwerk:** MetalLB v0.15.3, Traefik v3.6.7, cert-manager v1.17.2 (Let's Encrypt + IONOS)
**Storage:** Longhorn v1.9.2, StorageClass `longhorn-db` (strict-local, Replica=1, Retain)

**Datenbanken (Phase 5):**
- CloudNativePG Operator v1.28.1 (Helm Chart 0.27.1)
- PostgreSQL cnpg-shared: 17.8, 3 Instanzen (n8n, Keycloak, Gitea, Papermerge)
- PostgreSQL cnpg-erp: 17.8, 3 Instanzen (Odoo, OpenProject)
- mariadb-operator v25.10.4
- MariaDB Galera 11.8.6 LTS: 3 Nodes (Nextcloud, i-doit, KixDesk)

**Backups auf S3 (nas10.eneg.de:8010):**
- WAL-Archivierung: kontinuierlich → k8s-dev-postgres-wal
- Physical Backups: 02:00/02:15 UTC (Barman) → k8s-dev-postgres-wal (7d Retention)
- Physical Backups: 02:30 UTC (mariabackup) → k8s-dev-mariadb-backup (7d Retention)
- Logical Backups: 03:00/03:15 UTC (pg_dumpall) → k8s-dev-postgres-backup (32d Retention)

**DB-Services:**
- cnpg-shared-rw/ro/r.databases.svc.cluster.local:5432
- cnpg-erp-rw/ro/r.databases.svc.cluster.local:5432
- mariadb-galera.databases.svc.cluster.local:3306

**18 ArgoCD Apps** (alle Synced + Healthy)

## Offener Punkt aus Phase 5

- Schritt 5.11: PostgreSQL Minor-Upgrade 17.8 → 17.9 (wenn verfügbar)

## Nächster Schritt: Phase 6 — Pilot-Apps

Wir beginnen mit Phase 6: Pilot-App Deployment. Dazu gehört:
- Datenbanken per CNPG Database CRD und mariadb-operator Database CRD anlegen
- App-spezifische DB-User und Grants konfigurieren
- Erste Apps deployen (Vorschlag: OpenProject als Pilot, dann Odoo, dann N8n, dann i-doit)
- Ingress + TLS für jede App

Bitte lies zuerst die Dokumentation und erstelle dann einen Implementierungsplan für Phase 6.
