@echo off
rem Double-click launcher for the PRTG Mover dashboard.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-PrtgMover.ps1" %*
pause
