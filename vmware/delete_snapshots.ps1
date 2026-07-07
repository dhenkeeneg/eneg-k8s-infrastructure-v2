##############################################################################
# Löscht alle Snapshots älter als 3 Tage auf dem vcenter / Host
# Aufruf mit Parameter:
# cd 'C:\Users\dhenke\git\eneg-k8s-infrastructure-v2\vmware'
# .\delete_snapshots.ps1 -VCenter 'vcenter-b.eneg.de' 
# .\delete_snapshots.ps1 -VCenter 'vcenter-b.eneg.de' -VMHost 's2850.eneg.de'
##############################################################################

@'
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
        Write-Host "`nDRY-RUN – es wurde nichts gelöscht." -ForegroundColor Yellow
    }
}
finally {
    Disconnect-VIServer -Server $srv -Confirm:$false
    Write-Host "Verbindung getrennt." -ForegroundColor DarkGray
}
'@ | Set-Content -Path .\Cleanup-OldSnapshots.ps1 -Encoding UTF8

# Ausführen (Dry-Run) – VCenter-FQDN eintragen:
.\Cleanup-OldSnapshots.ps1 -VCenter 'vcenter.eneg.de'