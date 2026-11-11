<#
.SYNOPSIS
    Camino lab localisation engine. Sets keyboard and time zone on every lab VM.
    Replaces C:\scripts\changes.cmd / changes.ps1: nothing from those scripts is used.

.DESCRIPTION
    Runs on RDP-HOST, which is on every lab network. Lab Start (on A-GUI) copies this script and a settings
    file to RDP-HOST and runs it as a scheduled task, so it carries on when A-GUI restarts. It can also be run
    by hand on RDP-HOST:

        .\LabLocalise.ps1 -WindowsLanguage en-GB -WindowsTimezone 'GMT Standard Time' `
                          -GaiaKeyboard uk -GaiaRegion Europe -GaiaZone London

    Windows VMs (WinRM, as ALPHA\Administrator, else the local admin):
      - time zone (tzutil) and keyboard / language list for the remote account
      - C:\scripts\local_changes.ps1 rewritten with the same settings. The lab images run that file at every
        logon (All Users Startup\local_changes.cmd); its default content sets German / W. Europe, so it must
        be rewritten or the settings revert at the next logon. The Startup entry is created if missing.
      - restart (as the original did), unless -NoReboot
    RDP-HOST itself: the same settings, applied locally (no restart).
    Gaia hosts (plink over SSH): time zone, keyboard (dbset + kbd_map_xlate), admin shell back to clish,
      save config, reboot - the same sequence as the original. Hosts that are switched off are skipped.

    Progress: <StateDir>\status.json (state, detail, per-host results) and <StateDir>\localise.log.
    Windows PowerShell 5.1, ASCII only.
#>
[CmdletBinding()]
param(
    [string]$SettingsFile,
    [string]$WindowsLanguage = 'en-GB',
    [string]$WindowsTimezone = 'GMT Standard Time',
    [string]$GaiaKeyboard    = 'uk',
    [string]$GaiaRegion      = 'Europe',
    [string]$GaiaZone        = 'London',
    [string]$Label           = '',
    [string[]]$WindowsHosts  = @('10.1.1.201', '192.168.11.101', '192.168.11.201', '192.168.12.101', '192.168.21.201', '172.31.1.1'),
    [string[]]$GaiaHosts     = @('10.1.1.2', '10.1.1.3', '10.1.1.4', '10.1.1.101', '10.1.1.111', '10.1.1.103', '10.1.1.130', '198.51.100.1'),
    # cluster addresses (VIPs): done last, and skipped when they answer as a member that is already done
    [string[]]$LateGaiaHosts = @('10.1.1.1'),
    [string[]]$ExtraLanguages = @('en-US'),
    [string]$Password        = 'Chkp!234',
    [string]$DomainUser      = 'ALPHA\Administrator',
    [string]$LocalUser       = 'admin',
    [string]$PlinkPath       = 'C:\Program Files\PuTTY\plink.exe',
    [string]$StateDir        = 'C:\scripts\LabStart',
    [int]$RebootDelaySeconds = 60,
    [switch]$NoReboot
)

$ErrorActionPreference = 'Stop'
$EngineVersion = '1.0.1'

# ---- settings file overrides the parameters --------------------------------------------------------------
if ($SettingsFile) {
    $s = Get-Content -Raw -Path $SettingsFile | ConvertFrom-Json
    foreach ($p in $s.PSObject.Properties) {
        if ($null -eq $p.Value) { continue }
        switch ($p.Name) {
            'windowsLanguage'    { $WindowsLanguage = [string]$p.Value }
            'windowsTimezone'    { $WindowsTimezone = [string]$p.Value }
            'gaiaKeyboard'       { $GaiaKeyboard = [string]$p.Value }
            'gaiaRegion'         { $GaiaRegion = [string]$p.Value }
            'gaiaZone'           { $GaiaZone = [string]$p.Value }
            'label'              { $Label = [string]$p.Value }
            'windowsHosts'       { $WindowsHosts = @($p.Value | ForEach-Object { [string]$_ }) }
            'gaiaHosts'          { $GaiaHosts = @($p.Value | ForEach-Object { [string]$_ }) }
            'gaiaLateHosts'      { $LateGaiaHosts = @($p.Value | ForEach-Object { [string]$_ }) }
            'extraLanguages'     { $ExtraLanguages = @($p.Value | ForEach-Object { [string]$_ }) }
            'password'           { $Password = [string]$p.Value }
            'domainUser'         { $DomainUser = [string]$p.Value }
            'localUser'          { $LocalUser = [string]$p.Value }
            'rebootDelaySeconds' { $RebootDelaySeconds = [int]$p.Value }
            'noReboot'           { if ($p.Value) { $NoReboot = $true } }
        }
    }
}
if (-not $Label) { $Label = "$WindowsLanguage keyboard, $GaiaRegion/$GaiaZone" }
$Languages = @(@($WindowsLanguage) + @($ExtraLanguages) | Where-Object { $_ } | Select-Object -Unique)

New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
$LogFile    = Join-Path $StateDir 'localise.log'
$StatusFile = Join-Path $StateDir 'status.json'
$script:HostResults = [ordered]@{}

function Write-Log([string]$Text) {
    $line = (Get-Date -Format 'HH:mm:ss') + '  ' + $Text
    Add-Content -Path $LogFile -Value $line -Encoding UTF8
    Write-Host $line
}
function Set-Status([string]$State, [string]$Detail) {
    $hosts = @($script:HostResults.Values)
    [pscustomobject]@{
        state = $State; preset = $Label; detail = $Detail; engine = $EngineVersion
        time = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); hosts = $hosts
    } | ConvertTo-Json -Depth 4 | Set-Content -Path $StatusFile -Encoding UTF8
}

# ---- the per-user logon script written to C:\scripts\local_changes.ps1 ------------------------------------
$langArg = ($Languages | ForEach-Object { "'$_'" }) -join ', '
$UserScript = @"
# Written by Camino Lab Start localisation $(Get-Date -Format 'yyyy-MM-dd HH:mm') - runs at every logon
tzutil /s "$WindowsTimezone"
Set-WinUserLanguageList -LanguageList $langArg -Force
if (Test-Path 'C:\scripts\title_bars.reg') { reg import 'C:\scripts\title_bars.reg' 2>`$null | Out-Null }
"@

# Runs on each Windows VM (and locally on RDP-HOST)
$WindowsApply = {
    param([string]$Tz, [string[]]$Langs, [string]$UserScriptText, [bool]$DoReboot, [int]$Delay)
    $ErrorActionPreference = 'Stop'
    tzutil /s "$Tz"
    Set-WinUserLanguageList -LanguageList $Langs -Force -WarningAction SilentlyContinue
    New-Item -ItemType Directory -Force -Path 'C:\scripts' | Out-Null
    Set-Content -Path 'C:\scripts\local_changes.ps1' -Value $UserScriptText -Encoding Unicode
    # Make sure the logon hook exists (the lab images have it; create our own if not)
    $startup = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\StartUp'
    if (-not (Test-Path (Join-Path $startup 'local_changes.cmd')) -and -not (Test-Path (Join-Path $startup 'LabStart-locale.cmd'))) {
        Set-Content -Path (Join-Path $startup 'LabStart-locale.cmd') -Encoding ASCII -Value '@echo off
if exist c:\scripts\local_changes.ps1 start /MIN PowerShell.exe -NoProfile -ExecutionPolicy Bypass -Command "& c:\scripts\local_changes.ps1"'
    }
    $tzNow = (Get-TimeZone).Id
    if ($DoReboot) { & shutdown.exe /r /t $Delay /c 'Lab Start: applying keyboard and time zone' | Out-Null }
    return "$env:COMPUTERNAME|$tzNow"
}

# Runs in a background runspace per Windows VM
$WindowsWorker = {
    param([string]$Ip, [string[]]$Users, [string]$Pw, [scriptblock]$Apply, [object[]]$ApplyArgs)
    $res = [ordered]@{ ip = $Ip; kind = 'Windows'; name = ''; ok = $false; result = '' }
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $ar = $tcp.BeginConnect($Ip, 5985, $null, $null)
        $up = $ar.AsyncWaitHandle.WaitOne(2500) -and $tcp.Connected
        $tcp.Close()
    } catch { $up = $false }
    if (-not $up) { $res.result = 'skipped - not reachable (switched off?)'; return [pscustomobject]$res }
    $sec = ConvertTo-SecureString $Pw -AsPlainText -Force
    $errs = @()
    foreach ($u in $Users) {
        try {
            $cred = New-Object System.Management.Automation.PSCredential ($u, $sec)
            $out = Invoke-Command -ComputerName $Ip -Credential $cred -ScriptBlock ([scriptblock]::Create($Apply.ToString())) -ArgumentList $ApplyArgs -ErrorAction Stop
            $parts = ([string]$out) -split '\|'
            $res.name = $parts[0]; $res.ok = $true; $res.result = "done as $u (time zone now $($parts[1]))"
            return [pscustomobject]$res
        } catch { $errs += "$u - " + ($_.Exception.Message -split "`n")[0] }
    }
    $res.result = 'failed: ' + ($errs -join ' / ')
    return [pscustomobject]$res
}

# Runs in a background runspace per Gaia host
$GaiaWorker = {
    param([string]$Ip, [string]$Pw, [string]$Plink, [string[]]$ScriptLines, [string[]]$DoneNames, [bool]$IsLate)
    $res = [ordered]@{ ip = $Ip; kind = 'Gaia'; name = ''; ok = $false; result = ''; output = '' }
    function Q([string]$s) { '"' + ($s -replace '"', '\"') + '"' }
    function Run-Plink([string]$ArgLine, [string]$Stdin, [int]$TimeoutSec) {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $Plink; $psi.Arguments = $ArgLine
        $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
        $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
        $p = [System.Diagnostics.Process]::Start($psi)
        $o = $p.StandardOutput.ReadToEndAsync(); $e = $p.StandardError.ReadToEndAsync()
        try { if ($Stdin) { $p.StandardInput.Write($Stdin) }; $p.StandardInput.Close() } catch {}
        $done = $p.WaitForExit($TimeoutSec * 1000)
        if (-not $done) { try { $p.Kill() } catch {}; [void]$p.WaitForExit(3000) }
        $out = ''; try { $out = ($o.Result + "`n" + $e.Result).Trim() } catch {}
        return [pscustomobject]@{ Out = $out; TimedOut = (-not $done) }
    }
    try {
        $up = $false
        try {
            $tcp = New-Object System.Net.Sockets.TcpClient
            $ar = $tcp.BeginConnect($Ip, 22, $null, $null)
            $up = $ar.AsyncWaitHandle.WaitOne(2500) -and $tcp.Connected
            $tcp.Close()
        } catch {}
        if (-not $up) {
            if ($IsLate -and @($DoneNames).Count -gt 0) { $res.result = 'not needed - cluster address, not answering while the members restart' }
            else { $res.result = 'skipped - not reachable on SSH (switched off?)' }
            return [pscustomobject]$res
        }
        $base = "-ssh -l admin -pw " + (Q $Pw) + " $Ip"
        # accept the host key (PuTTY 0.72 reads the answer from stdin when not run with -batch)
        $r = Run-Plink "$base exit" "y`n" 25
        if ($r.Out -match 'Access denied') { $res.result = 'failed: login refused'; return [pscustomobject]$res }
        # which login shell?
        $r = Run-Plink ("-batch $base " + (Q 'echo LSMARK_$((6*7)) HN_$(hostname)')) $null 25
        if ($r.TimedOut) { $res.result = 'failed: no answer over SSH'; return [pscustomobject]$res }
        $isBash = $r.Out -match 'LSMARK_42'
        if ($isBash) { if ($r.Out -match 'HN_(\S+)') { $res.name = $Matches[1] } }
        else {
            $h = Run-Plink ("-batch $base " + (Q 'show hostname')) $null 25
            $line = @($h.Out -split "`r?`n" | Where-Object { $_.Trim() -and $_ -notmatch 'Keyboard-interactive|Using username|banner|CLINFR' } | Select-Object -Last 1)
            if ($line) { $res.name = "$($line[0])".Trim() }
        }
        if ($IsLate -and $res.name -and (@($DoneNames) -contains $res.name)) {
            $res.result = "not needed - cluster address, answered as $($res.name) (already done)"; return [pscustomobject]$res
        }
        if (-not $isBash) {
            # clish login shell: unlock the database and switch to bash for the expert-mode keyboard commands
            [void](Run-Plink ("-batch $base " + (Q 'lock database override')) $null 45)
            [void](Run-Plink ("-batch $base " + (Q 'set user admin shell /bin/bash')) $null 45)
        }
        $f = [IO.Path]::GetTempFileName()
        [IO.File]::WriteAllText($f, (($ScriptLines -join "`n") + "`n"))
        $r = Run-Plink ("-batch $base -m " + (Q $f)) $null 150
        Remove-Item $f -Force -ErrorAction SilentlyContinue
        $clean = @($r.Out -split "`r?`n" | Where-Object { $_.Trim() -and $_ -notmatch 'Keyboard-interactive|Using username|banner' })
        $res.output = ($clean | Select-Object -First 20) -join ' | '
        if ($r.Out -match 'command not found|CLINFR\d+|NMS[A-Z]{3}\d+|Access denied') { $res.result = 'failed - see the log' }
        else { $res.ok = $true; $res.result = 'done - restarting' }
    } catch { $res.result = 'failed: ' + $_.Exception.Message }
    return [pscustomobject]$res
}

# ==== main ===================================================================================================
Set-Content -Path $LogFile -Value ("Camino lab localisation engine $EngineVersion on $env:COMPUTERNAME - started " + (Get-Date)) -Encoding UTF8
Write-Log "Settings: $Label"
Write-Log "  Windows: language list $($Languages -join ', '); time zone '$WindowsTimezone'"
Write-Log "  Gaia:    keyboard '$GaiaKeyboard'; time zone '$GaiaRegion / $GaiaZone'"
Set-Status 'running' 'Starting'

try {
    $doReboot = -not $NoReboot
    $applyArgs = @($WindowsTimezone, [string[]]$Languages, $UserScript, $doReboot, $RebootDelaySeconds)

    # 1. RDP-HOST itself (local, never restarted)
    Set-Status 'running' 'Applying to RDP-HOST'
    $local = & $WindowsApply $WindowsTimezone $Languages $UserScript $false 0
    $script:HostResults['local'] = [pscustomobject]@{ ip = 'local'; kind = 'Windows'; name = $env:COMPUTERNAME; ok = $true; result = 'done (time zone now ' + ($local -split '\|')[1] + ')' }
    Write-Log "$env:COMPUTERNAME (this machine): done"

    # 2. Windows VMs and Gaia hosts in parallel
    $gaiaLines = @(
        "clish -c 'set timezone $GaiaRegion / $GaiaZone'",
        "dbset keyboard:mapping $GaiaKeyboard",
        'dbset :save',
        '/bin/kbd_map_xlate keyboard:mapping < /config/db/initial',
        "clish -c 'set user admin shell /etc/cli.sh'",
        "clish -c 'save config'",
        'rm -f /home/admin/.clish_history'
    )
    if ($doReboot) { $gaiaLines += 'reboot' }
    if (-not (Test-Path $PlinkPath)) { Write-Log "WARNING: plink.exe not found at $PlinkPath - Gaia hosts skipped"; $GaiaHosts = @() }

    $pool = [runspacefactory]::CreateRunspacePool(1, 10)
    $pool.Open()
    $jobs = @()
    foreach ($ip in $WindowsHosts) {
        $ps = [powershell]::Create(); $ps.RunspacePool = $pool
        [void]$ps.AddScript($WindowsWorker).AddArgument($ip).AddArgument([string[]]@($DomainUser, $LocalUser)).AddArgument($Password).AddArgument($WindowsApply).AddArgument([object[]]$applyArgs)
        $jobs += [pscustomobject]@{ Key = "win:$ip"; Ip = $ip; PS = $ps; Handle = $ps.BeginInvoke(); Done = $false }
        $script:HostResults["win:$ip"] = [pscustomobject]@{ ip = $ip; kind = 'Windows'; name = ''; ok = $false; result = 'working' }
    }
    $LateGaiaHosts = @($LateGaiaHosts | Where-Object { $_ -and ($GaiaHosts -notcontains $_) })
    if (-not (Test-Path $PlinkPath)) { $LateGaiaHosts = @() }
    $startGaia = {
        param([string]$ip, [string[]]$doneNames, [bool]$late)
        $ps = [powershell]::Create(); $ps.RunspacePool = $pool
        [void]$ps.AddScript($GaiaWorker).AddArgument($ip).AddArgument($Password).AddArgument($PlinkPath).AddArgument([string[]]$gaiaLines).AddArgument([string[]]$doneNames).AddArgument($late)
        $script:HostResults["gaia:$ip"] = [pscustomobject]@{ ip = $ip; kind = 'Gaia'; name = ''; ok = $false; result = 'working' }
        [pscustomobject]@{ Key = "gaia:$ip"; Ip = $ip; PS = $ps; Handle = $ps.BeginInvoke(); Done = $false; Late = $late }
    }
    foreach ($ip in $GaiaHosts) { $jobs += & $startGaia $ip @() $false }
    $lateStarted = ($LateGaiaHosts.Count -eq 0)
    Set-Status 'running' "Applying to $($WindowsHosts.Count) Windows VMs and $($GaiaHosts.Count + $LateGaiaHosts.Count) Gaia hosts"

    $deadline = (Get-Date).AddMinutes(8)
    while ((-not $lateStarted -or @($jobs | Where-Object { -not $_.Done }).Count -gt 0) -and (Get-Date) -lt $deadline) {
        if (-not $lateStarted -and @($jobs | Where-Object { $_.Key -like 'gaia:*' -and -not $_.Done }).Count -eq 0) {
            $lateStarted = $true
            $doneNames = @($script:HostResults.Values | Where-Object { $_.kind -eq 'Gaia' -and $_.ok -and $_.name } | ForEach-Object { [string]$_.name })
            foreach ($ip in $LateGaiaHosts) { $jobs += & $startGaia $ip $doneNames $true }
        }
        foreach ($j in ($jobs | Where-Object { -not $_.Done -and $_.Handle.IsCompleted })) {
            $j.Done = $true
            try { $r = @($j.PS.EndInvoke($j.Handle))[0] } catch { $r = [pscustomobject]@{ ip = $j.Ip; kind = '?'; ok = $false; result = 'failed: ' + $_.Exception.Message } }
            $j.PS.Dispose()
            $script:HostResults[$j.Key] = $r
            $who = $(if ($r.name) { "$($r.name) ($($r.ip))" } else { $r.ip })
            Write-Log ("{0,-8} {1}: {2}" -f $r.kind, $who, $r.result)
            if ($r.output) { Write-Log "         output: $($r.output)" }
            $done = @($jobs | Where-Object { $_.Done }).Count
            Set-Status 'running' "Applying ($done of $($jobs.Count) hosts finished)"
        }
        Start-Sleep -Milliseconds 500
    }
    foreach ($j in ($jobs | Where-Object { -not $_.Done })) { try { $j.PS.Stop() } catch {}; $script:HostResults[$j.Key] = [pscustomobject]@{ ip = $j.Ip; kind = '?'; ok = $false; result = 'failed: timed out' } }
    $pool.Close()

    $all = @($script:HostResults.Values)
    $ok = @($all | Where-Object { $_.ok }).Count
    $skipped = @($all | Where-Object { $_.result -like 'skipped*' }).Count
    $notNeeded = @($all | Where-Object { $_.result -like 'not needed*' }).Count
    $failed = $all.Count - $ok - $skipped - $notNeeded
    $summary = "$ok done, $skipped switched off" + $(if ($failed) { ", $failed failed" } else { '' })
    Write-Log "Finished: $summary"
    if ($skipped) {
        Write-Log ('Switched off (run Localise again, or use the Gaia commands tab, if a lab starts them): ' + ((@($all | Where-Object { $_.result -like 'skipped*' }) | ForEach-Object { $_.ip }) -join ', '))
    }
    Set-Status $(if ($failed) { 'failed' } else { 'done' }) ("Finished at " + (Get-Date -Format 'HH:mm') + ": $summary")
}
catch {
    Write-Log ('ERROR: ' + $_.Exception.Message)
    Set-Status 'failed' $_.Exception.Message
}
