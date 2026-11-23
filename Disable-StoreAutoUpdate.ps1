<#
.SYNOPSIS
    Stops the Microsoft Store from updating its apps automatically (or turns it back on with -Undo).

.DESCRIPTION
    On a lab VM with internet access the Store keeps downloading and installing updates for its built-in
    apps (Xbox, Maps, Photos, Weather, ...). Defender scans every installed file, so on a small lab VM this
    keeps the disk busy for hours. Switching Windows Update off does not stop it: the Store has its own
    installer.

    This sets the machine policy "Turn off Automatic Download and Install of updates"
    (HKLM\SOFTWARE\Policies\Microsoft\WindowsStore, AutoDownload = 2) and disables the scheduled task
    \Microsoft\Windows\WindowsUpdate\Automatic App Update. Apps can still be updated by hand from the Store.
    No restart needed. Safe to run more than once.

    Run in an administrator PowerShell window on each Windows VM (or on the image before it is captured).

.EXAMPLE
    .\Disable-StoreAutoUpdate.ps1
.EXAMPLE
    .\Disable-StoreAutoUpdate.ps1 -Undo
#>
[CmdletBinding()]
param([switch]$Undo)

$ErrorActionPreference = 'Stop'
$id = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $id.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Run this in an administrator PowerShell window.' }

$key  = 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore'
$task = Get-ScheduledTask -TaskPath '\Microsoft\Windows\WindowsUpdate\' -TaskName 'Automatic App Update' -ErrorAction SilentlyContinue

if ($Undo) {
    & reg.exe delete 'HKLM\SOFTWARE\Policies\Microsoft\WindowsStore' /v AutoDownload /f 2>$null | Out-Null
    if ($task) { $task | Enable-ScheduledTask | Out-Null }
    Write-Host "${env:COMPUTERNAME}: Store app auto-updates are back on." -ForegroundColor Yellow
} else {
    # reg.exe rather than New-Item: a Group Policy refresh can briefly mark the Policies key for deletion
    & reg.exe add 'HKLM\SOFTWARE\Policies\Microsoft\WindowsStore' /v AutoDownload /t REG_DWORD /d 2 /f | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Could not set the Store policy (reg.exe add failed).' }
    if ($task) { $task | Disable-ScheduledTask | Out-Null }
    Write-Host "${env:COMPUTERNAME}: Store app auto-updates are off." -ForegroundColor Green
}
"  AutoDownload policy : " + $(if ($v = (Get-ItemProperty $key -ErrorAction SilentlyContinue).AutoDownload) { $v } else { '(not set)' })
"  Automatic App Update: " + $(if ($task) { (Get-ScheduledTask -TaskPath '\Microsoft\Windows\WindowsUpdate\' -TaskName 'Automatic App Update').State } else { '(task not on this Windows version)' })
