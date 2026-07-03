@echo off
REM tls-showcerts.cmd <host> <outfile>
set OSSL="C:\Program Files\Git\usr\bin\openssl.exe"
echo. | %OSSL% s_client -connect %1:443 -servername %1 -showcerts > %2 2>&1
echo DONE %1
