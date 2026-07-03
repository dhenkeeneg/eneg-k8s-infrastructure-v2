@echo off
REM convert-ca.cmd - DER->PEM Konvertierung + Info-Ausgabe
set OSSL="C:\Program Files\Git\usr\bin\openssl.exe"
set D=C:\Users\dhenke\git\eneg-k8s-infrastructure-v2\scripts\_catmp

%OSSL% x509 -inform DER -in "%D%\_ca_vcenter-a.eneg.de.bin" -out "%D%\vcenter-a-ca.pem" 2>&1
%OSSL% x509 -inform DER -in "%D%\_ca_vcenter-b.eneg.de.bin" -out "%D%\vcenter-b-ca.pem" 2>&1

echo ===== VCENTER-A CA =====
%OSSL% x509 -in "%D%\vcenter-a-ca.pem" -noout -subject -issuer -dates 2>&1
echo(
echo ===== VCENTER-B CA =====
%OSSL% x509 -in "%D%\vcenter-b-ca.pem" -noout -subject -issuer -dates 2>&1
echo(
echo DONE
