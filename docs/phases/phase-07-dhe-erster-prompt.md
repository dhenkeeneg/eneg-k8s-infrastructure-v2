
Wir arbeiten gemeinsam an diesem Projekt "eNeG K8s Infrastruktur OpenTofuAnsible". Es gibt drei verschiedenen Arbeitsumgebungen auf denen ich die Konfigurationen für die Server anpasse:
* Einen Windows-Laptop mit Windows 11
* Einen MacMini
* Ein MacBook
 
Auf allen drei Umgebungen ist der Desktop-Commander eingerichtet und du hast Terminalzugriff und Dateizugriff direkt auf mein geclontes Git Repository. 
Pfad bei Windows ist: "C:\Users\dhenke\git\eneg-k8s-infrastructure-v2" Der Pfad bei MacBook und MacMini ist jeweils: "/Users/danielhenke/git/eneg-k8s-infrastructure-v2" 
Erstelle nötige Dateien und Änderungen eigenständig über Desktop-Commander aber in Absprache mit mir.
Wir arbeiten an der DEV Umgebung mit den folgenden Servern: k8s-dev-21, k8s-dev-22, k8s-dev-23 
Die Server der Testumgebung heißen: k8s-test-21, k8s-test-22, k8s-test23 
Du hast keinen direkten SSH Zugriff auf die Server. Dafür arbeiten wir per DevOps über GitHub und das lokale Repository auf dem Windows-Laptop oder den MacBook und MacMini. 
Du führst keine Commit und Push Befehle selbst aus. Du gibst mir die entsprechenden Anweisungen und ich führe diese in einem gesonderten Terminal dann selbst aus.
Du führst keine Befehle auf dem Management-Server (k8s-mgmt-10 - 192.168.180.10) selbst aus. Wenn nötig, gibst du mir die entsprechenden Anweisungen und ich führe diese in einem gesonderten Terminal dann selbst aus. 
Immer wenn es möglich ist sollen die Anpassungen über GitOps laufen und nicht direkt auf den Servern. Der Pfad zum Repository auf dem Managementserver (k8s-mgmt-10) ist: "~/git/eneg-k8s-infrastructure-v2" 
Im Repository gibt es den /docs-Pfad mit Unterverzeichnissen. Darin sind alle Entscheidungen, die Projektplanung und der Projektfortschritt dokumentiert. 
Lies die Dokumentation zu beginn des Chats und merke sie dir wenn möglich im Projektwissen bzw. aktualisiere das Projektwissen. 
Nach erfolgreichem Abschluss einer Phase wirst Du die Dokumentation entsprechend anpassen und erweitern.
Wir arbeiten jetzt auf dem Windows-Laptop und die aktuelle Projektplanung ist in "C:\Users\dhenke\git\eneg-k8s-infrastructure-v2\docs\K8s-GitOps-Infrastruktur-Projektplanung_v2.13.md"
Phase-8e führen wir zu einem späteren Zeitpunkt durch. Jetzt möchte ich Phase 7 beginnen "Monitoring-Stack (inkl. Backup-Health, WAL-Volume, S3-Endpoint Alerting)"
Los geht's. lies die Infos und mache einen Plan, stelle benötigten Fragen und dokumentiere den Plan dann im Ordner phases als pahse 7 - dann gehen wir gemeinsam Schritt für Schritt vor