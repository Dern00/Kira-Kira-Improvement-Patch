param([string]$GamePath,[switch]$Quiet)
$ErrorActionPreference='Stop'
try {
    . (Join-Path $PSScriptRoot 'Installer.Core.ps1')
    if(-not $GamePath) { $GamePath=Select-GameFolder }
    if(-not $GamePath) { Write-Output 'Cancelled. No files changed.';exit 0 }
    $result=Invoke-PatchInstall -GamePath $GamePath -PackageRoot $PSScriptRoot
    Write-Output $result
    if(-not $Quiet) { Add-Type -AssemblyName System.Windows.Forms;[void][Windows.Forms.MessageBox]::Show(($result -join "`r`n"),'Kira Kira Improvement Patch') }
} catch { Write-Output ('Error: '+$_.Exception.Message);if(-not $Quiet) { Add-Type -AssemblyName System.Windows.Forms;[void][Windows.Forms.MessageBox]::Show($_.Exception.Message,'Kira Kira Improvement Patch') };exit 1 }
