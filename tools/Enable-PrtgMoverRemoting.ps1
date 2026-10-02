<#
    PRTG Mover is now PRTG Manager. This file is kept so that shortcuts and scheduled tasks made by
    earlier versions keep working: it runs Enable-PrtgManagerRemoting.ps1 with the same arguments.
#>
& (Join-Path $PSScriptRoot 'Enable-PrtgManagerRemoting.ps1') @args
exit $LASTEXITCODE