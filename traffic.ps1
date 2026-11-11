<#
.SYNOPSIS
    Camino Lab Start - traffic generator in one step (Lab-Traffic-Gen by Don Paterson).
.DESCRIPTION
    Runs on A-GUI (from the Lab Start Extras tab, elevated).
      Start  : starts the server on A-Host through RDP-HOST (WinRM), waits until it listens,
               then starts the client here on A-GUI.
      Stop   : stops the client here and the server on A-Host.
      Status : shows both.
    The server is started by a one-off scheduled task on A-Host (as SYSTEM), so it keeps
    running after the remote session ends. The Check Point policy rules are still needed:
    A-GUI -> A-Host TCP/UDP 5201-5202 and A-GUI -> A-DMZ http, Track None.
    Windows PowerShell 5.1, ASCII only.
#>
[CmdletBinding()]
param(
    [ValidateSet('Start', 'Stop', 'Status')][string]$Action = 'Start',
    [ValidateSet('Light', 'Medium', 'Heavy')][string]$Load = 'Light',
    [string]$ServerHost = '192.168.11.201',
    [string]$RdpHost    = '10.1.1.230',
    [string]$Password   = 'Chkp!234'
)

$ErrorActionPreference = 'Stop'
# PowerShell 7 module paths break Windows PowerShell cmdlets when started from pwsh
$env:PSModulePath = "$env:SystemRoot\system32\WindowsPowerShell\v1.0\Modules;$env:ProgramFiles\WindowsPowerShell\Modules"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Url       = 'https://raw.githubusercontent.com/Don-Paterson/Lab-Traffic-Gen/main/LabTraffic.ps1'
$LocalCopy = 'C:\LabTraffic\LabTraffic.ps1'

function Say([string]$Text, [string]$Colour = 'Cyan') { Write-Host $Text -ForegroundColor $Colour }

# Runs on RDP-HOST, which runs the inner block on A-Host
$OnServer = {
    param([string]$Act, [string]$Srv, [string]$Url, [string]$Pw)
    $dc = New-Object System.Management.Automation.PSCredential ('ALPHA\Administrator', (ConvertTo-SecureString $Pw -AsPlainText -Force))
    Invoke-Command -ComputerName $Srv -Credential $dc -ArgumentList $Act, $Url -ErrorAction Stop -ScriptBlock {
        param([string]$Act, [string]$Url)
        $listening = { [bool](Get-NetTCPConnection -LocalPort 5201 -State Listen -ErrorAction SilentlyContinue) }
        switch ($Act) {
            'Start' {
                if (& $listening) { return 'Server already running on A-Host.' }
                [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
                Invoke-WebRequest -Uri $Url -OutFile 'C:\LabTraffic.ps1' -UseBasicParsing
                $tn = 'LabTraffic-ServerStart'
                $taskAction = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -ExecutionPolicy Bypass -File C:\LabTraffic.ps1 -Role Server -Action Start'
                Register-ScheduledTask -TaskName $tn -Action $taskAction -User 'SYSTEM' -RunLevel Highest -Force | Out-Null
                Start-ScheduledTask -TaskName $tn
                $deadline = (Get-Date).AddSeconds(150)
                do { Start-Sleep -Seconds 3 } until ((& $listening) -or (Get-Date) -gt $deadline)
                Start-Sleep -Seconds 2
                Unregister-ScheduledTask -TaskName $tn -Confirm:$false -ErrorAction SilentlyContinue
                if (& $listening) { 'Server started on A-Host (iperf3 listening on 5201 and 5202).' }
                else { throw 'The server on A-Host did not start listening within 150 seconds (check its internet access).' }
            }
            'Stop' {
                if (Test-Path 'C:\LabTraffic.ps1') { (& powershell.exe -NoProfile -ExecutionPolicy Bypass -File 'C:\LabTraffic.ps1' -Action Stop 2>&1 | Out-String).Trim() }
                else { 'Nothing to stop on A-Host.' }
            }
            'Status' {
                if (Test-Path 'C:\LabTraffic.ps1') { (& powershell.exe -NoProfile -ExecutionPolicy Bypass -File 'C:\LabTraffic.ps1' -Action Status 2>&1 | Out-String).Trim() }
                else { 'Not installed on A-Host.' }
            }
        }
    }
}

function Invoke-Server([string]$Act) {
    $rc = New-Object System.Management.Automation.PSCredential ('Admin', (ConvertTo-SecureString $Password -AsPlainText -Force))
    Invoke-Command -ComputerName $RdpHost -Credential $rc -ScriptBlock $OnServer -ArgumentList $Act, $ServerHost, $Url, $Password -ErrorAction Stop
}

Say ''
Say "Camino Lab Start - traffic generator: $Action" 'White'
Say ('-' * 50) 'DarkGray'

switch ($Action) {
    'Start' {
        Say "1. Server on A-Host ($ServerHost), via RDP-HOST - this can take a minute the first time..."
        try { Say ('   ' + (Invoke-Server 'Start')) 'Green' }
        catch { Say "   Could not start the server on A-Host: $($_.Exception.Message)" 'Red'; Say '   The client is not started.' 'Yellow'; return }
        Say '2. Client here on A-GUI...'
        New-Item -ItemType Directory -Force -Path (Split-Path $LocalCopy) | Out-Null
        Invoke-WebRequest -Uri $Url -OutFile $LocalCopy -UseBasicParsing
        try { & $LocalCopy -Role Client -Action Start -Load $Load -Target $ServerHost }
        catch {
            Say ''
            Say "The server on A-Host is ready, but A-GUI cannot reach it: $($_.Exception.Message)" 'Red'
            Say 'Add these rules to the Access Control policy above the cleanup rule, install policy, then run "Traffic generator - start" again:' 'Yellow'
            Say '   A-GUI -> A-Host   TCP 5201-5202 and UDP 5201-5202   Accept   Track: None' 'Yellow'
            Say '   A-GUI -> A-DMZ    http                              Accept   Track: None' 'Yellow'
            return
        }
        Say ''
        Say 'Traffic is running for 15 minutes. Use "Traffic generator - stop" to end it early.' 'Green'
        Say 'If a load exits at once, check the policy rules: A-GUI -> A-Host TCP/UDP 5201-5202 and A-GUI -> A-DMZ http (Track None).' 'Yellow'
    }
    'Stop' {
        Say '1. Client here on A-GUI...'
        if (Test-Path $LocalCopy) { & $LocalCopy -Action Stop } else { Say '   Nothing to stop here.' }
        Say '2. Server on A-Host...'
        try { Say ('   ' + (Invoke-Server 'Stop')) 'Green' } catch { Say "   Could not reach A-Host: $($_.Exception.Message)" 'Red' }
    }
    'Status' {
        Say 'A-GUI (client):'
        if (Test-Path $LocalCopy) { & $LocalCopy -Action Status } else { Say '   Not started here.' }
        Say 'A-Host (server):'
        try { Say (Invoke-Server 'Status') 'Gray' } catch { Say "   Could not reach A-Host: $($_.Exception.Message)" 'Red' }
    }
}
