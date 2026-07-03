# verify-vcenter-user.ps1  (PowerShell 7 / pwsh)
# Rein lesende Verifikation des Monitoring-Users gegen ein vCenter.
# Passwort wird NUR aus Umgebungsvariable VC_PASS gelesen, niemals geloggt.
# Nutzt vSphere REST-API: Login (POST /api/session) + Read (host, datastore).
# KEINE Schreiboperationen.

param(
    [Parameter(Mandatory=$true)][string]$VCenter,
    [Parameter(Mandatory=$true)][string]$UserUpn
)

$pass = $env:VC_PASS
if ([string]::IsNullOrWhiteSpace($pass)) {
    Write-Output "FEHLER: Umgebungsvariable VC_PASS ist leer. Bitte zuerst setzen."
    exit 2
}

$base = "https://$VCenter"

# Self-signed vCenter (VMCA): fuer diesen lesenden Test Zert-Check umgehen.
# PS7-Weg: -SkipCertificateCheck (kein ICertificatePolicy noetig).
$secpass = ConvertTo-SecureString $pass -AsPlainText -Force
$cred    = New-Object System.Management.Automation.PSCredential($UserUpn, $secpass)

Write-Output "=== Verifikation: $VCenter (User: $UserUpn) ==="

# --- 1) Login ---
try {
    $token = Invoke-RestMethod -Method Post -Uri "$base/api/session" `
        -Authentication Basic -Credential $cred `
        -SkipCertificateCheck -ErrorAction Stop
} catch {
    Write-Output "LOGIN FEHLGESCHLAGEN: $($_.Exception.Message)"
    if ($_.ErrorDetails) { Write-Output ("Server-Antwort: " + $_.ErrorDetails.Message) }
    exit 1
}
Write-Output "LOGIN OK (Session-Token erhalten)"

$sessHeaders = @{ "vmware-api-session-id" = $token }

# --- 2) Hosts lesen ---
try {
    $hosts = Invoke-RestMethod -Method Get -Uri "$base/api/vcenter/host" `
        -Headers $sessHeaders -SkipCertificateCheck -ErrorAction Stop
    Write-Output "SICHTBARE HOSTS: $($hosts.Count)"
    foreach ($h in $hosts) { Write-Output ("  - " + $h.name + "  [" + $h.connection_state + "/" + $h.power_state + "]") }
} catch {
    Write-Output "HOST-READ FEHLGESCHLAGEN: $($_.Exception.Message)"
}

# --- 3) Datastores lesen ---
try {
    $ds = Invoke-RestMethod -Method Get -Uri "$base/api/vcenter/datastore" `
        -Headers $sessHeaders -SkipCertificateCheck -ErrorAction Stop
    Write-Output "SICHTBARE DATASTORES: $($ds.Count)"
    foreach ($d in $ds) {
        $freeGB = [math]::Round($d.free_space/1GB,1)
        $capGB  = [math]::Round($d.capacity/1GB,1)
        Write-Output ("  - " + $d.name + "  (" + $freeGB + " GB frei / " + $capGB + " GB)")
    }
} catch {
    Write-Output "DATASTORE-READ FEHLGESCHLAGEN: $($_.Exception.Message)"
}

# --- 4) Logout (Session sauber schliessen) ---
try {
    Invoke-RestMethod -Method Delete -Uri "$base/api/session" `
        -Headers $sessHeaders -SkipCertificateCheck -ErrorAction SilentlyContinue | Out-Null
    Write-Output "LOGOUT OK (Session geschlossen)"
} catch { }

Write-Output "=== Ende $VCenter ==="
