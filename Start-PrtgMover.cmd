@echo off
rem Double-click launcher for the PRTG Mover dashboard. A dashboard that already runs is opened in the browser.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-PrtgMover.ps1" %*
if errorlevel 1 pause
