$src = 'C:\Users\dhenke\git\eneg-k8s-infrastructure-v2\scripts\_catmp\vcenter-ca-bundle.pem'
$dst = 'C:\Users\dhenke\git\eneg-k8s-infrastructure-v2\scripts\_catmp\vcenter-ca-bundle.b64'
$bytes = [System.IO.File]::ReadAllBytes($src)
$b64 = [System.Convert]::ToBase64String($bytes)
[System.IO.File]::WriteAllText($dst, $b64)
Write-Output ("B64-LEN: " + $b64.Length)
