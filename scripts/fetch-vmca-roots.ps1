# fetch-vmca-roots.ps1  (PowerShell 7 / pwsh)
# Laedt die VMCA Root-CA(s) beider vCenter rein lesend herunter.
# Endpoint /afd/vecs/ca liefert je nach Version ein ZIP mit .0/.crt-Dateien
# oder direkt PEM. Skript erkennt beides und legt die Rohdaten ab.
# KEINE Anmeldung noetig (CA-Download ist anonym).

param(
    [Parameter(Mandatory=$true)][string]$VCenter,
    [Parameter(Mandatory=$true)][string]$OutDir
)

$ProgressPreference = 'SilentlyContinue'
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir | Out-Null }

$raw = Join-Path $OutDir ("_ca_" + $VCenter + ".bin")

Write-Output "=== CA-Download: $VCenter ==="
try {
    Invoke-WebRequest -Uri "https://$VCenter/afd/vecs/ca" -SkipCertificateCheck -OutFile $raw -ErrorAction Stop
} catch {
    Write-Output "FEHLER Download: $($_.Exception.Message)"
    exit 1
}

$size = (Get-Item $raw).Length
Write-Output "Heruntergeladen: $size Bytes -> $raw"

# ZIP erkennen (PK-Header 0x50 0x4B)
$bytes = [System.IO.File]::ReadAllBytes($raw)
$isZip = ($bytes.Length -ge 2 -and $bytes[0] -eq 0x50 -and $bytes[1] -eq 0x4B)

if ($isZip) {
    Write-Output "Format: ZIP -> entpacke"
    $extractDir = Join-Path $OutDir ("_ca_" + $VCenter + "_x")
    if (Test-Path $extractDir) { Remove-Item $extractDir -Recurse -Force }
    Expand-Archive -Path $raw -DestinationPath $extractDir -Force
    Write-Output "Entpackte Dateien:"
    Get-ChildItem $extractDir -Recurse -File | ForEach-Object { Write-Output ("  " + $_.FullName + "  (" + $_.Length + " B)") }
} else {
    $head = [System.Text.Encoding]::ASCII.GetString($bytes[0..([Math]::Min(40,$bytes.Length-1))])
    Write-Output "Format: nicht-ZIP. Kopf: $head"
    if ($head -match 'BEGIN CERTIFICATE') {
        $pem = Join-Path $OutDir ("_ca_" + $VCenter + ".pem")
        Copy-Item $raw $pem -Force
        Write-Output "PEM erkannt -> $pem"
    } else {
        Write-Output "WARN: unbekanntes Format, bitte manuell pruefen."
    }
}
Write-Output "=== Ende $VCenter ==="
