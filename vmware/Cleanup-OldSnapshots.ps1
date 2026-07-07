##############################################################################
#
# Löscht alle Snapshots älter als 3 Tage auf dem vcenter / Host
#
# Voraussetzung: vmWareCLI - Installation:
# # 1. TLS 1.2 sicherstellen (für PS Gallery)
# [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
# # 2. PSGallery als vertrauenswürdig setzen (einmalig, optional)
# Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
# # PowerCLI 13.3.0 installieren (höchster verfügbarer Build)
# Install-Module -Name VMware.PowerCLI -RequiredVersion 13.3.0.24145083 -Scope CurrentUser -AllowClobber
# # Version prüfen
# Get-Module -ListAvailable VMware.PowerCLI | Select-Object Name, Version
# # Import + Cmdlets prüfen
# Import-Module VMware.PowerCLI
# Get-Command Connect-VIServer, Get-Snapshot, Remove-Snapshot | Select-Object Name, Version
# # Konfiguration (jetzt sind die Cmdlets verfügbar)
# Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Scope User -Confirm:$false
# Set-PowerCLIConfiguration -ParticipateInCEIP $false -Scope User -Confirm:$false
#
#
# Aufruf mit Parameter:
#
# Dry-Run
# cd 'C:\Users\dhenke\git\eneg-k8s-infrastructure-v2\vmware'
# .\Cleanup-OldSnapshots.ps1 -VCenter 'vcenter-b.eneg.de' 
# .\Cleanup-OldSnapshots.ps1 -VCenter 'vcenter-b.eneg.de' -VMHost 's2850.eneg.de'
#
# Scharf
# cd 'C:\Users\dhenke\git\eneg-k8s-infrastructure-v2\vmware'
# .\Cleanup-OldSnapshots.ps1 -VCenter 'vcenter-b.eneg.de' -Execute
# .\Cleanup-OldSnapshots.ps1 -VCenter 'vcenter-b.eneg.de' -VMHost 's2850.eneg.de' -Execute
#
##############################################################################

#Requires -Modules VMware.PowerCLI
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $VCenter,
    [string] $VMHost,
    [int]    $AgeDays        = 3,
    [int]    $PauseSeconds   = 10,
    [string[]] $ExcludePatterns = @('VEEAM','Veeam','_replica','Replica','Replication','CBT','Consolidate helper'),
    [switch] $Execute
)

$ErrorActionPreference = 'Stop'
$cutoff = (Get-Date).AddDays(-$AgeDays)

Write-Host "=== Snapshot-Cleanup ===" -ForegroundColor Cyan
Write-Host "vCenter        : $VCenter"
Write-Host "Cutoff (älter) : $cutoff  ($AgeDays Tage)"
Write-Host "Pause          : $PauseSeconds s zwischen Löschungen"
Write-Host "Ausschluss     : $($ExcludePatterns -join ', ')"
Write-Host "Modus          : $(if($Execute){'EXECUTE (löscht!)'}else{'DRY-RUN (nur Anzeige)'})" -ForegroundColor $(if($Execute){'Red'}else{'Yellow'})
Write-Host ""

$cred = Get-Credential -Message "vCenter-Login für $VCenter"
$srv  = Connect-VIServer -Server $VCenter -Credential $cred

try {
    if ($VMHost) {
        Write-Host "Filter         : nur VMs auf Host '$VMHost'`n" -ForegroundColor Cyan
        $allVMs = Get-VM -Location (Get-VMHost -Name $VMHost -Server $srv) -Server $srv | Sort-Object Name
    } else {
        $allVMs = Get-VM -Server $srv | Sort-Object Name
    }
    $candidates = @()

    foreach ($vm in $allVMs) {
        $snaps = Get-Snapshot -VM $vm -Server $srv
        if (-not $snaps) { continue }

        # Tabu, wenn ein Snapshot einem Ausschlussmuster entspricht
        $excluded = $snaps | Where-Object {
            $s = $_
            $ExcludePatterns | Where-Object { $s.Name -match $_ -or $s.Description -match $_ }
        }
        if ($excluded) {
            Write-Host ("[TABU]  {0} – Veeam/Replikations-Snapshot vorhanden ({1} Snap(s)), übersprungen" -f $vm.Name, $snaps.Count) -ForegroundColor DarkYellow
            continue
        }

        $newest = ($snaps | Sort-Object Created -Descending | Select-Object -First 1)
        if ($newest.Created -lt $cutoff) {
            $sizeGB = [math]::Round(($snaps | Measure-Object SizeGB -Sum).Sum, 2)
            Write-Host ("[KAND.] {0} – {1} Snap(s), jüngster {2:yyyy-MM-dd HH:mm}, ~{3} GB" -f `
                $vm.Name, $snaps.Count, $newest.Created, $sizeGB) -ForegroundColor Green
            $candidates += [pscustomobject]@{
                VM         = $vm.Name
                SnapCount  = $snaps.Count
                NewestSnap = $newest.Created
                SizeGB     = $sizeGB
            }
        }
        else {
            Write-Host ("[SKIP]  {0} – jüngster Snap {1:yyyy-MM-dd HH:mm} zu neu" -f $vm.Name, $newest.Created) -ForegroundColor DarkGray
        }
    }

    Write-Host ""
    Write-Host "=== Zusammenfassung ===" -ForegroundColor Cyan
    if ($candidates) {
        $candidates | Format-Table -AutoSize
        Write-Host ("Kandidaten: {0} VM(s), gesamt ~{1} GB" -f `
            $candidates.Count, [math]::Round(($candidates | Measure-Object SizeGB -Sum).Sum,2)) -ForegroundColor Green
    } else {
        Write-Host "Keine Kandidaten gefunden." -ForegroundColor Yellow
    }

    if (-not $Execute) {
        Write-Host "`nDRY-RUN – es wurde nichts gelöscht. Zum Löschen mit -Execute erneut starten." -ForegroundColor Yellow
        return
    }

    if (-not $candidates) { return }

    # --- Scharf: strikt sequentiell, ein Snapshot-Merge nach dem anderen ---
    Write-Host "`n=== EXECUTE ===" -ForegroundColor Red
    $confirm = Read-Host "Wirklich alle Snapshots dieser $($candidates.Count) VM(s) löschen? Tippe 'JA' zum Fortfahren"
    if ($confirm -ne 'JA') {
        Write-Host "Abgebrochen – nichts gelöscht." -ForegroundColor Yellow
        return
    }

    $done = 0; $failed = 0
    foreach ($c in $candidates) {
        $vm = Get-VM -Name $c.VM -Server $srv

        # Sicherheits-Recheck unmittelbar vor dem Löschen (Zustand könnte sich geändert haben)
        $snaps = Get-Snapshot -VM $vm -Server $srv
        if (-not $snaps) {
            Write-Host ("[SKIP]  {0} – keine Snapshots mehr vorhanden" -f $vm.Name) -ForegroundColor DarkGray
            continue
        }
        $reExcluded = $snaps | Where-Object {
            $s = $_
            $ExcludePatterns | Where-Object { $s.Name -match $_ -or $s.Description -match $_ }
        }
        if ($reExcluded) {
            Write-Host ("[TABU]  {0} – inzwischen Veeam/Replikations-Snapshot vorhanden, übersprungen" -f $vm.Name) -ForegroundColor DarkYellow
            continue
        }

        # Wurzel-Snapshot(s) ermitteln und mit -RemoveChildren den gesamten Baum mergen
        $roots = $snaps | Where-Object { $null -eq $_.ParentSnapshotId -or $_.ParentSnapshot -eq $null }
        if (-not $roots) { $roots = $snaps | Sort-Object Created | Select-Object -First 1 }

        Write-Host ("[LÖSCHE] {0} – {1} Snap(s) ..." -f $vm.Name, $snaps.Count) -ForegroundColor Cyan
        try {
            foreach ($root in $roots) {
                # -RemoveChildren merged Kind-Snapshots mit; synchron (kein -RunAsync) => wartet auf Abschluss
                Remove-Snapshot -Snapshot $root -RemoveChildren -Confirm:$false -ErrorAction Stop
            }

            # Verifikation: sind wirklich keine Snapshots mehr da?
            $remain = Get-Snapshot -VM $vm -Server $srv
            if ($remain) {
                Write-Host ("[WARN]  {0} – es verbleiben {1} Snap(s)!" -f $vm.Name, $remain.Count) -ForegroundColor Yellow
                $failed++
            } else {
                Write-Host ("[OK]    {0} – alle Snapshots entfernt" -f $vm.Name) -ForegroundColor Green
                $done++
            }
        }
        catch {
            Write-Host ("[FEHLER] {0} – {1}" -f $vm.Name, $_.Exception.Message) -ForegroundColor Red
            $failed++
        }

        Write-Host ("        Pause {0}s ..." -f $PauseSeconds) -ForegroundColor DarkGray
        Start-Sleep -Seconds $PauseSeconds
    }

    Write-Host ""
    Write-Host ("=== Fertig: {0} OK, {1} mit Warnung/Fehler ===" -f $done, $failed) -ForegroundColor Cyan
}
finally {
    Disconnect-VIServer -Server $srv -Confirm:$false
    Write-Host "Verbindung getrennt." -ForegroundColor DarkGray
}
