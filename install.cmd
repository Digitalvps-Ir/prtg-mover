@echo off
rem Double-click installer for PRTG Mover. Options are passed on, for example: install.cmd -InstallPath D:\PrtgMover
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" %*
echo.
pause
