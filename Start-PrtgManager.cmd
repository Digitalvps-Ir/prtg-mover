@echo off
rem Double-click launcher for the PRTG Manager dashboard. A dashboard that already runs is opened in the browser.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-PrtgManager.ps1" %*
if errorlevel 1 pause
