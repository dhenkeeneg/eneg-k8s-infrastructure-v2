@echo off
REM tls-san.cmd <host> <outfile>
set OSSL="C:\Program Files\Git\usr\bin\openssl.exe"
echo. | %OSSL% s_client -connect %1:443 -servername %1 2>nul | %OSSL% x509 -noout -text > %2 2>&1
echo DONE %1
