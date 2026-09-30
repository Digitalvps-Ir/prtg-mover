<#
    PRTG Mover is now PRTG Manager. This file is kept so that shortcuts and scheduled tasks made by
    earlier versions keep working: it runs Start-PrtgManager.ps1 with the same arguments.
#>
& (Join-Path $PSScriptRoot 'Start-PrtgManager.ps1') @args
exit $LASTEXITCODE