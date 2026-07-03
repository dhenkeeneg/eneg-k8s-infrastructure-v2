$ProgressPreference = 'SilentlyContinue'
$y = (Invoke-WebRequest -Uri 'https://grafana.github.io/helm-charts/index.yaml' -UseBasicParsing).Content
$lines = $y -split "`n"
$inAlloy = $false
$count = 0
foreach ($l in $lines) {
    if ($l -match '^  alloy:') { $inAlloy = $true; continue }
    if ($inAlloy -and $l -match '^  [a-z]' -and $l -notmatch '^  alloy:') { break }
    if ($inAlloy -and $l -match '^\s+version:') {
        Write-Output $l.Trim()
        $count++
        if ($count -ge 12) { break }
    }
}
