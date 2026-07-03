# check-tls-chain.ps1
# Rein lesende TLS-Handshake-Pruefung gegen einen Host:Port.
# Liest das ausgelieferte Server-Zertifikat + Kette aus und prueft Trust-Validierung.
# KEINE Anmeldung, KEINE Datenuebertragung - nur TLS-Handshake.

param(
    [Parameter(Mandatory=$true)][string]$TargetHost,
    [int]$Port = 443
)

Write-Output "=== TLS-Pruefung: $TargetHost`:$Port ==="

try {
    $tcp = New-Object System.Net.Sockets.TcpClient
    $tcp.Connect($TargetHost, $Port)
} catch {
    Write-Output "FEHLER: TCP-Verbindung fehlgeschlagen: $($_.Exception.Message)"
    exit 1
}

$collected = New-Object System.Collections.Generic.List[object]

$sslStream = New-Object System.Net.Security.SslStream(
    $tcp.GetStream(),
    $false,
    ([System.Net.Security.RemoteCertificateValidationCallback]{
        param($sndr, $cert, $chain, $errors)
        $script:policyErrors = $errors
        if ($chain -ne $null) {
            foreach ($el in $chain.ChainElements) {
                $script:collected.Add($el.Certificate)
            }
        }
        return $true  # akzeptieren, damit wir die Kette lesen koennen
    })
)

try {
    $sslStream.AuthenticateAsClient($TargetHost)
} catch {
    Write-Output "FEHLER: TLS-Handshake fehlgeschlagen: $($_.Exception.Message)"
    $tcp.Close()
    exit 1
}

Write-Output ""
Write-Output "Protokoll : $($sslStream.SslProtocol)"
Write-Output "Trust-Status (Policy-Errors): $script:policyErrors"
Write-Output ""
Write-Output "--- Zertifikatskette (Server -> Root) ---"

$i = 0
foreach ($c in $collected) {
    Write-Output ""
    Write-Output "[$i] Subject     : $($c.Subject)"
    Write-Output "    Issuer      : $($c.Issuer)"
    Write-Output "    Thumbprint  : $($c.Thumbprint)"
    Write-Output "    Gueltig von : $($c.NotBefore)"
    Write-Output "    Gueltig bis : $($c.NotAfter)"
    $selfSigned = ($c.Subject -eq $c.Issuer)
    Write-Output "    Self-Signed : $selfSigned"
    $i++
}

Write-Output ""
Write-Output "--- SAN (Subject Alternative Names) des Leaf-Zertifikats ---"
$leaf = $collected[0]
$sanExt = $leaf.Extensions | Where-Object { $_.Oid.FriendlyName -eq "Subject Alternative Name" }
if ($sanExt) {
    Write-Output $sanExt.Format($true)
} else {
    Write-Output "  (kein SAN gefunden)"
}

$sslStream.Close()
$tcp.Close()
Write-Output ""
Write-Output "=== Ende $TargetHost ==="
