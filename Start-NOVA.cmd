@echo off
cd /d "%~dp0"
set "NOVA_URL=http://127.0.0.1:24808/"
rem Start the visible backend CMD first. The frontend opens only after the API responds.
start "NOVA Backend" cmd.exe /d /k "cd /d ""%~dp0"" && powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File ""%~dp0NOVA.ps1"" -Server -Port 24808"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "$url='%NOVA_URL%'; for($i=0;$i -lt 60;$i++){try{Invoke-WebRequest -UseBasicParsing -Uri $url -TimeoutSec 1 | Out-Null; Start-Process $url; exit 0}catch{Start-Sleep -Milliseconds 250}}; Write-Host 'NOVA backend did not respond within 15 seconds.' -ForegroundColor Yellow; Start-Process $url"
echo.
echo NOVA backend has stopped. Press any key to close this window.
pause >nul
