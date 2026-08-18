# Chat-Anweisung: OpenProject-Umzug MicroK8s -> k8s-dev

**Erstellt:** 18.08.2026
**Zweck:** Startprompt fuer einen neuen Chat, der den Datenumzug durchfuehrt
**Vorarbeit abgeschlossen:** beide Installationen laufen auf OpenProject 17.7.2

---

## Startprompt (ab hier kopieren)

```
Wir ziehen OpenProject von der alten MicroK8s-Installation in die v2-Umgebung
k8s-dev um, schalten die alte Installation ab und machen k8s-dev unter der
bisherigen URL verfuegbar.

AUSGANGSLAGE (Stand 18.08.2026, alles bereits erledigt)

Beide Installationen laufen auf OpenProject 17.7.2 - identische Version,
identisches DB-Schema. Das ist die Voraussetzung dafuer, dass der Umzug ein
reiner Restore ist und keine Migration mehr braucht.

Quelle: k8s-dev-microk8s (v1-Infrastruktur)
- Repo: github.com/dhenkeeneg/k8s-configs, Pfad clusters/dev/apps-dev/openproject
  Lokal: /Users/danielhenke/git/k8s-configs
- Namespace apps-dev, Komponenten web (2 Replicas), worker, cron
- ArgoCD v2.11.3, nginx-ingress (LB 192.168.180.50), sealed-secrets
- URL: https://openproject-dev.eneg.de
- DB: CNPG-Cluster openproject-postgres in Namespace databases,
  DB und Owner "openproject", Primary aktuell openproject-postgres-14
- Attachments im DATEISYSTEM: RWX-PVC openproject-data, gemountet auf
  /var/openproject/assets, Struktur assets/files/attachment/file/...
- Datenmengen: 24 Projekte, 100 Work Packages, 12 Benutzer, 6 Attachments,
  DB 27 MB, Assets 436 KB
- 1 LDAP-Quelle, 2 OAuth-Anwendungen, 0 2FA-Geraete, 0 Storages

Ziel: k8s-dev (v2-Infrastruktur)
- Repo: eneg-k8s-infrastructure-v2, Pfad
  kubernetes/environments/dev/apps/openproject
- Namespace openproject, Komponenten web, worker, memcached, hocuspocus
- ArgoCD v3.3.0, Traefik (LB 192.168.180.100), SOPS
- URL aktuell: https://openproject-dev-v2.eneg.de
- DB: CNPG-Cluster cnpg-erp in Namespace databases, DB und User "openproject"
- Attachments in Garage S3 (fog), Bucket openproject-assets
- Seeder laeuft als ArgoCD PreSync-Hook

WICHTIG: Beide Installationen benutzen denselben SECRET_KEY_BASE. Das ist
absichtlich so eingerichtet, damit die verschluesselten Spalten (LDAP-Bind-
Passwort, OAuth-Secrets) den Restore ueberleben. Diesen Wert in keiner der
beiden Umgebungen aendern, solange der Umzug nicht abgeschlossen ist.

ENTSCHEIDUNG, DIE SCHON GETROFFEN IST

Die Daten in k8s-dev werden VOLLSTAENDIG ERSETZT. Der bisherige Inhalt der
v2-Installation ist Testinhalt und darf verloren gehen. Zwei OpenProject-
Datenbanken zusammenzufuehren ist nicht vorgesehen.

AUFGABEN

1. BESTANDSAUFNAHME
   - Beide Installationen pruefen: Version, Pod-Status, DB-Gesundheit
   - Bestaetigen, dass beide exakt 17.7.2 laufen (sonst abbrechen und
     klaeren - ein Versionsunterschied macht den Restore unbrauchbar)
   - In k8s-dev die Struktur der Attachment-Ablage in Garage ansehen, damit
     klar ist, unter welchen Schluesseln die Dateien liegen muessen

2. BACKUPS
   - k8s-dev (Ziel): CNPG-Backup cnpg-erp, logisches pg_dumpall, Velero fuer
     Namespace openproject. Das ist der Rueckweg, falls der Umzug scheitert.
   - k8s-dev-microk8s (Quelle): frischer pg_dump der DB openproject
     (custom format) und tar der Assets. Der Dump muss NACH dem Upgrade
     erzeugt werden, damit er das 17.7.2-Schema enthaelt.
   - Achtung Namenskonflikt: "kubectl get backup" loest wegen des MariaDB-
     Operators falsch auf. Immer backups.postgresql.cnpg.io bzw.
     backups.velero.io vollqualifiziert schreiben.

3. DATENBANK UMZIEHEN
   - In k8s-dev die OpenProject-Pods stilllegen. Sauberster Weg ist ueber
     Git (replicas 0), alternativ ArgoCD-Auto-Sync temporaer abschalten und
     per kubectl skalieren. Beides ist zulaessig, aber der gewaehlte Weg
     muss dokumentiert und danach zurueckgesetzt werden.
   - Ziel-DB leeren und Dump einspielen. Vorgehen abstimmen: DROP SCHEMA
     public CASCADE + CREATE SCHEMA, oder DB neu anlegen.
   - KRITISCH - EIGENTUEMERSCHAFT: Wird der Dump als "postgres" eingespielt,
     gehoeren anschliessend ALLE Tabellen und Sequenzen "postgres" statt dem
     Anwendungsbenutzer "openproject". OpenProject kann dann lesen und
     schreiben, aber keine Migration mehr ausfuehren, die Eigentuemerschaft
     verlangt (z.B. add_index). Genau dieser Defekt hat in der MicroK8s-
     Installation das Upgrade blockiert - Fehlerbild:
     "PG::InsufficientPrivilege: ERROR: must be owner of table good_jobs".
     Nach dem Restore deshalb ZWINGEND die Eigentuemerschaft korrigieren und
     das Ergebnis pruefen (alle Tabellen, Sequenzen, Views, Typen im Schema
     public muessen "openproject" gehoeren). Der passende DO-Block steht in
     docs/guides/phase-6.3-openproject-update-guide-v2.md.
   - Alternativ pruefen, ob ein Restore direkt als "openproject" moeglich
     ist - das waere der bessere Weg und wuerde das Problem vermeiden.

4. ATTACHMENTS UMZIEHEN
   - Quelle: Dateisystem, /var/openproject/assets, darunter
     files/attachment/file/...
   - Ziel: Garage S3, Bucket openproject-assets
   - Die attachments-Tabelle speichert NICHT, welches Backend benutzt wird -
     das ist globale Konfiguration. Der Restore bringt also Datensaetze mit
     relativen Pfaden, und k8s-dev sucht dieselben Pfade in S3.
   - Erwartung, die zu VERIFIZIEREN ist: der Inhalt von assets/files/ muss
     unter demselben relativen Pfad im Bucket liegen. Vor dem Kopieren an
     einem bestehenden Attachment in k8s-dev nachsehen, wie der Schluessel
     dort tatsaechlich aussieht, und danach ausrichten.
   - Es sind nur 6 Dateien / 436 KB. Falls der pfadtreue Weg nicht sauber
     aufgeht, ist manuelles Neuhochladen der 6 Attachments eine akzeptable
     Rueckfallloesung - dann aber dokumentieren, dass die Verknuepfung zu den
     Work Packages neu gesetzt werden musste.

5. VERIFIKATION
   - Pods Running/Ready, keine Restarts, ArgoCD Synced/Healthy
   - PreSync-Seeder: da Quell- und Zielschema identisch sind, darf es KEINE
     ausstehenden Migrationen geben. Laufen doch Migrationen, stimmen die
     Versionen nicht ueberein - dann anhalten und klaeren.
   - Datenabgleich gegen die Quelle: 24 Projekte, 100 Work Packages,
     12 Benutzer, 6 Attachments
   - LDAP-Anmeldung muss funktionieren, OHNE dass das Bind-Passwort neu
     eingegeben wird. Falls nicht, ist der SECRET_KEY_BASE nicht identisch -
     das ist dann der erste Verdacht.
   - Ein Attachment im UI oeffnen (prueft den S3-Pfad)
   - good_jobs auf fehlgeschlagene Backfill-Jobs pruefen
   - Version unter Administration -> Information

6. URL UMSTELLEN
   Bisher:  k8s-dev-microk8s = https://openproject-dev.eneg.de
            k8s-dev          = https://openproject-dev-v2.eneg.de
   Ziel:    k8s-dev          = https://openproject-dev.eneg.de

   Zu klaeren und dann umzusetzen:
   - OPENPROJECT_HOST__NAME in k8s-dev von openproject-dev-v2.eneg.de auf
     openproject-dev.eneg.de aendern. Auch die Hocuspocus-URL
     (OPENPROJECT_COLLABORATIVE__EDITING__HOCUSPOCUS__URL) haengt daran.
   - Soll openproject-dev-v2.eneg.de parallel weiter erreichbar bleiben?
     Wenn ja, ueber OPENPROJECT_ADDITIONAL__HOST__NAMES und einen zweiten
     Traefik-Eintrag. Wenn nein, sauber entfernen.
   - Traefik: Certificate und IngressRoute in
     kubernetes/environments/dev/apps/openproject/ingress.yaml anpassen.
     Zertifikate laufen ueber cert-manager mit DNS-01 (IONOS), es gibt also
     keinen HTTP-Challenge-Konflikt mit der noch laufenden alten Instanz.
   - DNS: CNAME openproject-dev.eneg.de von der MicroK8s-Seite
     (nginx-ingress 192.168.180.50) auf traefik-dev.eneg.de
     (192.168.180.100) umstellen. Beide liegen im selben Netz 192.168.180.0/24.
   - Reihenfolge festlegen, damit es keine Zeit gibt, in der der Name auf
     beide Installationen zeigt.

7. ALTE INSTALLATION ABSCHALTEN
   - Zuerst nur stilllegen, nicht loeschen: den Ingress-Eintrag fuer
     openproject-dev.eneg.de entfernen und die Deployments auf 0 skalieren -
     ueber das Repo k8s-configs, damit ArgoCD es nicht zurueckdreht.
   - PVC openproject-data, die DB openproject-postgres und die Backups
     zunaechst BEHALTEN. Erst nach einer Bewaehrungszeit abbauen, die du mit
     mir abstimmst.
   - Vorschlag fuer das endgueltige Entfernen erstellen, aber nicht
     ausfuehren.

8. DOKUMENTATION
   - Projektplanung als neue Version (aktuell v2.43) mit Aenderungshistorie
   - Den Umzug als eigenes Dokument unter docs/phases/ oder docs/migration/
   - docs/guides/phase-6.3-openproject-update-guide-v2.md um den Abschnitt
     "Was am Ende offen blieb" ergaenzen, falls sich dort etwas erledigt

RAHMENBEDINGUNGEN

- Du fuehrst KEINE git commit/push aus und KEINE Befehle auf k8s-mgmt-10.
  Du gibst mir die Befehle, ich fuehre sie aus.
- Kubernetes-MCP nur lesend bzw. nach ausdruecklicher Freigabe.
- Alles ueber GitOps, keine direkten Cluster-Aenderungen ausser dort, wo es
  keinen GitOps-Weg gibt (Restore, einmalige Jobs) - und dann dokumentiert.
- Auf k8s-mgmt-10 zeigt der kubectl-Default-Context NICHT zuverlaessig auf
  die gewuenschte Umgebung, die argocd-CLI kann auf eine andere zeigen.
  Immer --context bzw. --kubecontext explizit setzen.
- Der Pfad ~/git/eneg-k8s-infrastructure-v2 existiert auf dem Mac UND auf
  k8s-mgmt-10. In Anleitungen absolute Pfade verwenden. Das k8s-configs-Repo
  liegt lokal unter /Users/danielhenke/git/k8s-configs.
- Einmalige "rails runner"-Laeufe gehoeren in einen eigenen Job mit eigenem
  Speicherlimit, NIE per kubectl exec in den laufenden Worker (dort fuehrt
  ein zweiter Rails-Prozess zu OOMKilled, Exit 137).
- Stabilitaet vor Geschwindigkeit. Zwischendurch Rueckfragen stellen und das
  weitere Vorgehen abstimmen. Wenn etwas getestet werden muss, um eine
  Entscheidung zu treffen: erst testen, dann weiterschreiben.
- Bitte starte mit Aufgabe 1 und berichte das Ergebnis, bevor du irgendeine
  Datei aenderst.
```

---

## Hintergrund fuer den naechsten Chat (nicht Teil des Prompts)

### Wie der aktuelle Stand entstanden ist

| Datum | Was |
|---|---|
| 17.08.2026 | k8s-dev von 17.1.2 auf 17.7.2, gestaffelt in sechs Etappen |
| 18.08.2026 | k8s-test und k8s-prod von 17.1.2 auf 17.7.2, je Direktsprung |
| 18.08.2026 | k8s-dev-microk8s von 16.6.1 auf 17.7.2 |

Vollstaendige Doku: `docs/guides/phase-6.3-openproject-update-guide-v2.md`,
Projektplanung v2.43.

### Stolpersteine, die im MicroK8s-Upgrade auftraten

1. **`SECRET_KEY_BASE=OVERWRITE_ME`** - der Image-Platzhalter war wirksam,
   ab 17.4.0 laesst das Image das nicht mehr zu (CVE-2026-46386). Geloest
   durch Uebernahme des k8s-dev-Schluessels in ein drittes
   `encryptedData`-Feld der bestehenden SealedSecret (`kubeseal --raw`,
   strict scope) - so ueberleben die verschluesselten Spalten den Umzug.
2. **Eigentuemerschaft der DB-Objekte** - 166 von 168 Tabellen gehoerten
   `postgres`. Die erste ausstehende Migration scheiterte mit
   `must be owner of table good_jobs`. Wichtig: **die Migration lief in
   Transaktionen, es gab keinen Teilzustand** - 0 von 150 Migrationen waren
   angewendet, die DB war unveraendert.
3. **Hook-only-Aenderungen loesen keinen ArgoCD-Sync aus**, und bei einem
   fehlgeschlagenen PreSync-Hook loescht `BeforeHookCreation` bei jedem
   Retry den Job samt Pod - die Logs sind dann weg. Vorgehen: Auto-Sync
   abschalten, eigenen Diagnose-Job mit `restartPolicy: Never` und
   `backoffLimit: 0` laufen lassen.
4. **Der cron-Pod** protokolliert einen Fehler in
   `redmine:email:receive_imap` und plant sich alle 600 s neu. Kein
   CrashLoop, vermutlich Altzustand (IMAP nicht konfiguriert).
5. **Memcached war nie vorhanden** - die ConfigMap zeigte auf
   `openproject-memcached:11211`, ein Service dieses Namens existiert in
   `apps-dev` nicht. Die beiden Cache-Variablen wurden entfernt.

### Sicherungen, die vorliegen (auf k8s-mgmt-10 im Home)

```
openproject-microk8s-pre-17.7.2-20260818-1517.dump   1.2M  vor Eigentuemer-Fix
openproject-microk8s-assets-20260818-1517.tar.gz     361K
openproject-microk8s-pre-17.7.2-20260818-1551.dump   1.1M  nach Eigentuemer-Fix
openproject-microk8s-assets-20260818-1551.tar.gz     361K
```

Der Dump von 1551 ist der bessere Rueckfallpunkt - der von 1517 wuerde den
Eigentuemer-Defekt wieder einspielen. Beide sind auf dem **16.6.1**-Schema
und damit fuer den Umzug NICHT geeignet. Fuer den Umzug wird ein frischer
Dump gebraucht.

Zusaetzlich im Cluster: CNPG-Backup `openproject-pre-17-7-2` (completed,
nach NAS10). Der Cluster hatte davor keinen Wiederherstellungspunkt -
WAL-Archivierung lief, aber `firstRecoverabilityPoint` war leer und der
ScheduledBackup produzierte seit Monaten keine Backups. Das ist ein offener
Punkt der v1-Umgebung, der sich mit der Abschaltung erledigt.
