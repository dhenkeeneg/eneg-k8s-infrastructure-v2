$base = "C:\Users\dhenke\git\eneg-k8s-infrastructure-v2\kubernetes"
$apps = @("n8n", "keycloak", "idoit", "it-info-versand", "openproject", "odoo")

foreach ($app in $apps) {
    $src = Join-Path $base "base\apps\$app\secrets"
    $dst = Join-Path $base "environments\dev\apps\$app\secrets"
    
    if (Test-Path $src) {
        New-Item -ItemType Directory -Path $dst -Force | Out-Null
        Copy-Item -Path "$src\*" -Destination $dst -Force
        $count = (Get-ChildItem $dst).Count
        Write-Host "OK: $app ($count files copied)"
    } else {
        Write-Host "MISSING: $src"
    }
}
