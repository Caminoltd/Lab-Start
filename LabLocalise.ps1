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
    # Linux servers (e.g. A-DMZ in CPVS) and VyOS routers: time zone (+ console keymap on Linux) over SSH
    [string[]]$LinuxHosts    = @(),
    [string]$LinuxUser       = 'root',
    [string[]]$VyosHosts     = @(),
    [string]$VyosUser        = 'vyos',
    # VyOS routers that only accept SSH from their own side, as 'router@windowsVM' (e.g. C-GW via C-Host in CPVS):
    # plink is copied to that Windows VM for the run, used from there, then removed
    [string[]]$VyosViaHosts  = @(),
    [string]$PlinkPath       = 'C:\Program Files\PuTTY\plink.exe',
    [string]$StateDir        = 'C:\scripts\LabStart',
    [int]$RebootDelaySeconds = 60,
    [switch]$NoReboot,
    # 'localise' (keyboard + time zone) or 'optimise' (Windows VM clean-up, never restarts)
    [ValidateSet('localise', 'optimise')][string]$Mode = 'localise',
    [string[]]$KeepSmartConsole = @('R82'),
    # optimise: also switch off Defender definition/cloud updates (only where Defender runs and Check Point Endpoint is absent)
    [switch]$QuietDefender
)

$ErrorActionPreference = 'Stop'
$EngineVersion = '1.6.5'

$GaiaTzOverride = @{}; $VyosTzOverride = @{}; $TzOverrideNote = ''; $VyosTzNote = ''; $ClusterActive = $null
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
            'linuxHosts'         { $LinuxHosts = @($p.Value | ForEach-Object { [string]$_ }) }
            'vyosHosts'          { $VyosHosts = @($p.Value | ForEach-Object { [string]$_ }) }
            'vyosViaHosts'       { $VyosViaHosts = @($p.Value | ForEach-Object { [string]$_ }) }
            'gaiaLateHosts'      { $LateGaiaHosts = @($p.Value | ForEach-Object { [string]$_ }) }
            # Per-host time zones that must not follow the student's country (a lab step depends on them):
            # { "<ip>": "Region / Zone" } for Gaia, { "<ip>": "Area/City" } for VyOS
            'gaiaTimezoneOverrides' { foreach ($q in $p.Value.PSObject.Properties) { $GaiaTzOverride[[string]$q.Name] = [string]$q.Value } }
            'vyosTimezoneOverrides' { foreach ($q in $p.Value.PSObject.Properties) { $VyosTzOverride[[string]$q.Name] = [string]$q.Value } }
            'timezoneOverrideNote'  { $TzOverrideNote = [string]$p.Value }       # why the Gaia overrides exist
            'vyosTimezoneOverrideNote' { $VyosTzNote = [string]$p.Value }       # why the VyOS overrides exist
            # { "member": "<ip>", "peer": "<ip>", "note": "..." }: make that cluster member the Active one after Localise
            'clusterActive'      { $ClusterActive = $p.Value }
            'extraLanguages'     { $ExtraLanguages = @($p.Value | ForEach-Object { [string]$_ }) }
            'password'           { $Password = [string]$p.Value }
            'domainUser'         { $DomainUser = [string]$p.Value }
            'localUser'          { $LocalUser = [string]$p.Value }
            'rebootDelaySeconds' { $RebootDelaySeconds = [int]$p.Value }
            'noReboot'           { if ($p.Value) { $NoReboot = $true } }
            'mode'               { $Mode = [string]$p.Value }
            'keepSmartConsole'   { $KeepSmartConsole = @($p.Value | ForEach-Object { [string]$_ }) }
            'quietDefender'      { if ($p.Value) { $QuietDefender = $true } }
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
    $extra = ''
    # Logon screen and new profiles (engine 1.6.0): the images set German (0407) as the system default keyboard, and
    # the logon screen, new RDP sessions and new users start from that default (HKU\.DEFAULT and the Default profile),
    # not from the per-user list. Copy the chosen list there the same way as Region > Administrative > Copy settings.
    $defKb = ''
    try {
        $tips = @(Get-WinUserLanguageList | ForEach-Object { @($_.InputMethodTips) } | Where-Object { $_ -match '^[0-9A-Fa-f]{4}:[0-9A-Fa-f]{8}$' } | Select-Object -Unique)
        if ($tips.Count) {
            $inp = for ($i = 0; $i -lt $tips.Count; $i++) { '<gs:InputLanguageID Action="add" ID="' + $tips[$i] + '"' + $(if ($i -eq 0) { ' Default="true"' } else { '' }) + '/>' }
            $xml = '<gs:GlobalizationServices xmlns:gs="urn:longhornGlobalizationUnattend">' +
                   '<gs:UserList><gs:User UserID="Current" CopySettingsToDefaultUserAcct="true" CopySettingsToSystemAcct="true"/></gs:UserList>' +
                   '<gs:InputPreferences>' + ($inp -join '') + '</gs:InputPreferences></gs:GlobalizationServices>'
            $xf = 'C:\scripts\LabStart\copy_intl.xml'
            New-Item -ItemType Directory -Force -Path 'C:\scripts\LabStart' | Out-Null
            Set-Content -Path $xf -Value $xml -Encoding UTF8
            if (Get-Command Copy-UserInternationalSettingsToSystem -ErrorAction SilentlyContinue) {
                # Windows 11 22H2+ / Server 2025: the built-in command does the same copy
                Copy-UserInternationalSettingsToSystem -WelcomeScreen $true -NewUser $true
            } else {
                Start-Process -FilePath "$env:SystemRoot\System32\control.exe" -ArgumentList ('intl.cpl,,/f:"' + $xf + '"') -Wait -WindowStyle Hidden
            }
            Start-Sleep -Seconds 3
            $pre = $null; try { $pre = (Get-ItemProperty 'Registry::HKEY_USERS\.DEFAULT\Keyboard Layout\Preload' -Name '1' -ErrorAction Stop).'1' } catch {}
            $want = ($tips[0] -split ':')[1]
            # A layout that differs from its language (e.g. en-US with a UK keyboard) is stored as a substitute ID
            if ($pre) { try { $sub = (Get-ItemProperty 'Registry::HKEY_USERS\.DEFAULT\Keyboard Layout\Substitutes' -Name $pre -ErrorAction Stop).$pre; if ($sub) { $pre = $sub } } catch {} }
            $defKb = $(if ($pre -and ($pre -eq $want -or $pre -like ('*' + $want.Substring(4)))) { ", logon-screen keyboard $want" } elseif ($pre) { ", logon-screen keyboard still $pre (Copy settings did not apply)" } else { '' })
        }
    } catch { $defKb = ', logon-screen keyboard not changed' }
    $extra = $defKb
    # The session keyboard script (sets the list and switches the active keyboard of an open session). Written on
    # every run: used below for sessions already open, and by the reconnect task (engine 1.6.0) - a reconnected RDP
    # session does not log on again, so the logon script does not run and the session kept the old keyboard.
    try {
        $dir = 'C:\scripts\LabStart'
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        $logS = Join-Path $dir 'session_keyboard.log'
        $langList = ($Langs | ForEach-Object { "'$_'" }) -join ', '
        $sess = @(
            "`$ErrorActionPreference = 'SilentlyContinue'",
            "Set-WinUserLanguageList -LanguageList $langList -Force -WarningAction SilentlyContinue",
            "`$tip = @((Get-WinUserLanguageList)[0].InputMethodTips)[0]",
            "`$klid = (`$tip -split ':')[-1]",
            "Add-Type -Namespace LabStart -Name Kbd -MemberDefinition '[DllImport(""user32.dll"")] public static extern IntPtr LoadKeyboardLayout(string id, uint flags); [DllImport(""user32.dll"")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l); [DllImport(""user32.dll"")] public static extern bool SystemParametersInfo(uint a, uint b, ref IntPtr c, uint d); [DllImport(""user32.dll"")] public static extern IntPtr FindWindow(string c, string w); [DllImport(""user32.dll"")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint p); [DllImport(""user32.dll"")] public static extern IntPtr GetKeyboardLayout(uint t); [DllImport(""user32.dll"")] public static extern IntPtr GetForegroundWindow();'",
            "`$h = [LabStart.Kbd]::LoadKeyboardLayout(`$klid, 1)",
            "`$tray = [LabStart.Kbd]::FindWindow('Shell_TrayWnd', `$null)",
            "if (`$tray -ne [IntPtr]::Zero) { [void][LabStart.Kbd]::PostMessage(`$tray, 0x50, [IntPtr]::Zero, `$h) }",
            "`$fg = [LabStart.Kbd]::GetForegroundWindow(); if (`$fg -ne [IntPtr]::Zero -and `$fg -ne `$tray) { [void][LabStart.Kbd]::PostMessage(`$fg, 0x50, [IntPtr]::Zero, `$h) }",
            "`$want = [Convert]::ToInt32(`$klid.Substring(4), 16)",
            "function Get-TrayLang { `$t = [LabStart.Kbd]::FindWindow('Shell_TrayWnd', `$null); if (`$t -eq [IntPtr]::Zero) { return -1 }; `$p = 0; `$tid = [LabStart.Kbd]::GetWindowThreadProcessId(`$t, [ref]`$p); return ([LabStart.Kbd]::GetKeyboardLayout(`$tid).ToInt64() -band 0xFFFF) }",
            "Start-Sleep -Milliseconds 800",
            "`$how = 'switched'",
            "`$cur = Get-TrayLang",
            "if (`$cur -ne -1 -and `$cur -ne `$want) { if (`$tray -ne [IntPtr]::Zero) { [void][LabStart.Kbd]::PostMessage(`$tray, 0x50, [IntPtr]::Zero, `$h) }; Start-Sleep -Milliseconds 1500; `$cur = Get-TrayLang; `$how = 'taskbar (2nd try)' }",
            "if (`$cur -ne -1 -and `$cur -ne `$want) { `$how = 'not switched - applies at next log-on' }",
            "try { Add-Content -Path '$logS' -Value ((Get-Date -Format s) + ' ' + `$env:USERDOMAIN + '\' + `$env:USERNAME + ' ' + `$klid + ' ' + `$how) } catch {}"
        ) -join "`r`n"
        $sessFile = Join-Path $dir 'session_keyboard.ps1'
        Set-Content -Path $sessFile -Value $sess -Encoding Unicode
        $rcTask = 'LabStart-ReconnectKeyboard'
        $rcUsers = ([Security.Principal.SecurityIdentifier]'S-1-5-32-545').Translate([Security.Principal.NTAccount]).Value
        $cls = Get-CimClass -Namespace 'Root/Microsoft/Windows/TaskScheduler' -ClassName 'MSFT_TaskSessionStateChangeTrigger'
        $trg = @(foreach ($chg in 1, 3, 8) {   # 1 console connect, 3 remote (RDP) connect, 8 session unlock
            $t = New-CimInstance -CimClass $cls -ClientOnly; $t.StateChange = $chg; $t.Enabled = $true; $t })
        $rcAct = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$sessFile`""
        $rcPri = New-ScheduledTaskPrincipal -GroupId $rcUsers -RunLevel Limited
        $rcSet = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 2) -MultipleInstances IgnoreNew
        Register-ScheduledTask -TaskName $rcTask -Action $rcAct -Principal $rcPri -Trigger $trg -Settings $rcSet -Force | Out-Null
        $extra += ', keyboard re-applied on RDP reconnect'
    } catch { $extra += ', reconnect task not set' }
    if ($DoReboot) { & shutdown.exe /r /t $Delay /c 'Lab Start: applying keyboard and time zone' | Out-Null; $extra += ', restarting' }
    else {
        # No restart: run the logon script now inside every session that is already logged on (a task for the
        # Users group runs in each logged-on user's session), so the keyboard changes without logging off.
        # The script sets the language list and also switches the active keyboard of the open session (the same
        # as picking it from the taskbar), because an unchanged list does not refresh a session that is already open.
        try {
            $since = Get-Date
            $users = ([Security.Principal.SecurityIdentifier]'S-1-5-32-545').Translate([Security.Principal.NTAccount]).Value
            $tn = 'LabStart-UserLocale'
            $act = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$sessFile`""
            $pri = New-ScheduledTaskPrincipal -GroupId $users -RunLevel Limited
            Register-ScheduledTask -TaskName $tn -Action $act -Principal $pri -Force | Out-Null
            Start-ScheduledTask -TaskName $tn
            Start-Sleep -Seconds 12
            Unregister-ScheduledTask -TaskName $tn -Confirm:$false -ErrorAction SilentlyContinue
            $n = @(Get-Content $logS -ErrorAction SilentlyContinue | Where-Object { try { [datetime]($_.Substring(0, 19)) -ge $since.AddSeconds(-2) } catch { $false } }).Count
            $extra += $(if ($n) { ", keyboard switched in $n logged-on session(s)" } else { ', no logged-on session (keyboard applies at log-on)' })
        } catch { $extra += ', keyboard at next log-on' }
    }
    return "$env:COMPUTERNAME|time zone now $tzNow$extra"
}

# Optimise mode: runs on each Windows VM (and locally on RDP-HOST). Reversible clean-up, no restart.
$WindowsOptimise = {
    param([string[]]$KeepSC, [bool]$SkipSC = $false, [bool]$QuietDefender = $false)   # SkipSC: leave SmartConsole alone (RDP-HOST: slow, small VM, nobody uses it there)
    $ErrorActionPreference = 'Continue'
    $did = @()
    # 1. SmartConsole versions not in the keep list: delete folder, uninstall entry, Start menu / desktop shortcuts
    $removed = @(); $freed = 0
    # Safety: never remove the newest SmartConsole on the VM (an R81.20 lab must keep R81.20 even if the keep
    # list says R82), and never one that is running - it is skipped, not closed.
    $scRoot = 'C:\Program Files (x86)\CheckPoint\SmartConsole'
    $newest = @(Get-ChildItem $scRoot -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^R\d+(\.\d+)*$' } |
        Sort-Object { [version](($_.Name.Substring(1) + '.0.0') -replace '^(\d+\.\d+(\.\d+)?).*$', '$1') } | Select-Object -Last 1 | ForEach-Object { $_.Name })
    $KeepSC = @($KeepSC) + $newest
    $skipped = @()
    $uninstallKeys = $(if ($SkipSC) { @() } else { @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall') })
    foreach ($k in $uninstallKeys) {
        foreach ($e in @(Get-ChildItem $k -ErrorAction SilentlyContinue)) {
            $pr = Get-ItemProperty $e.PSPath -ErrorAction SilentlyContinue
            if (-not ("$($pr.DisplayName)" -match '^Check Point SmartConsole (R[\d.]+)')) { continue }
            $ver = $Matches[1]
            if ($KeepSC -contains $ver) { continue }
            $loc = "C:\Program Files (x86)\CheckPoint\SmartConsole\$ver"
            if (-not (Test-Path $loc) -and $pr.InstallLocation -and (Test-Path $pr.InstallLocation)) { $loc = $pr.InstallLocation }
            if ($loc -and (Test-Path $loc) -and ($loc -match 'CheckPoint')) {
                if (@(Get-Process -ErrorAction SilentlyContinue | Where-Object { try { $_.Path -like "$loc*" } catch { $false } }).Count) {
                    if ($skipped -notcontains $ver) { $skipped += $ver }
                    continue
                }
                $freed += [double](Get-ChildItem $loc -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
                $empty = Join-Path $env:TEMP ('ls_empty_' + [IO.Path]::GetRandomFileName())
                New-Item -ItemType Directory -Path $empty -Force | Out-Null
                & robocopy.exe $empty $loc /MIR /NFL /NDL /NJH /NJS /NC /NS /NP | Out-Null
                Remove-Item $empty -Force -ErrorAction SilentlyContinue
                Remove-Item -LiteralPath $loc -Recurse -Force -ErrorAction SilentlyContinue
            }
            Remove-Item $e.PSPath -Recurse -Force -ErrorAction SilentlyContinue
            if ($removed -notcontains $ver) { $removed += $ver }
        }
    }
    if ($removed.Count) {
        $places = @("$env:ProgramData\Microsoft\Windows\Start Menu\Programs", "$env:PUBLIC\Desktop") + @(Get-ChildItem 'C:\Users' -Directory -Force -ErrorAction SilentlyContinue | ForEach-Object { Join-Path $_.FullName 'Desktop'; Join-Path $_.FullName 'AppData\Roaming\Microsoft\Windows\Start Menu\Programs' })
        foreach ($v in $removed) {
            Get-ChildItem $places -Recurse -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "*SmartConsole*$v" -or $_.Name -like "*SmartConsole*$v.lnk" -or $_.Name -like "*SmartConsole*$v *" } |
                Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        }
        $did += ('SmartConsole ' + ($removed -join ', ') + ' removed (' + [math]::Round($freed / 1GB, 1) + ' GB)')
    }
    if ($skipped.Count) { $did += ('SmartConsole ' + ($skipped -join ', ') + ' left (open)') }
    # 2. Background services that only cost CPU and disk in a lab
    $off = @()
    foreach ($n in 'WSearch', 'SysMain', 'DiagTrack') {
        $sv = Get-Service $n -ErrorAction SilentlyContinue
        if ($sv -and ($sv.StartType -ne 'Disabled' -or $sv.Status -ne 'Stopped')) {
            Stop-Service $n -Force -ErrorAction SilentlyContinue; Set-Service $n -StartupType Disabled -ErrorAction SilentlyContinue; $off += $n
        }
    }
    # VMware Tools on Hyper-V VMs (left over from the VMware build)
    foreach ($n in 'VMTools', 'VGAuthService', 'vmvss') {
        $sv = Get-Service $n -ErrorAction SilentlyContinue
        if ($sv -and $sv.StartType -ne 'Disabled') { Stop-Service $n -Force -ErrorAction SilentlyContinue; Set-Service $n -StartupType Disabled -ErrorAction SilentlyContinue; $off += $n }
    }
    $run = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
    if ((Get-ItemProperty $run -ErrorAction SilentlyContinue).'VMware User Process') { Remove-ItemProperty $run 'VMware User Process' -ErrorAction SilentlyContinue; $off += 'VMware User Process (start-up)' }
    if ($off.Count) { $did += ('switched off: ' + ($off -join ', ')) }
    # 3. OneDrive setup start-up entries: loaded user hives, profiles not logged on, and the default profile
    $od = 0
    foreach ($h in @(Get-ChildItem 'Registry::HKEY_USERS' -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -notmatch '_Classes$' })) {
        $rk = "Registry::HKEY_USERS\$($h.PSChildName)\Software\Microsoft\Windows\CurrentVersion\Run"
        if ((Get-ItemProperty $rk -ErrorAction SilentlyContinue).OneDriveSetup) { Remove-ItemProperty $rk OneDriveSetup -ErrorAction SilentlyContinue; $od++ }
    }
    $hives = @(Get-CimInstance Win32_UserProfile -ErrorAction SilentlyContinue | Where-Object { -not $_.Loaded -and -not $_.Special } | ForEach-Object { Join-Path $_.LocalPath 'NTUSER.DAT' }) + @('C:\Users\Default\NTUSER.DAT')
    foreach ($f in $hives) {
        if (-not (Test-Path $f)) { continue }
        & reg.exe load 'HKU\LabStartTmp' $f 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { continue }
        & reg.exe query 'HKU\LabStartTmp\Software\Microsoft\Windows\CurrentVersion\Run' /v OneDriveSetup 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) { & reg.exe delete 'HKU\LabStartTmp\Software\Microsoft\Windows\CurrentVersion\Run' /v OneDriveSetup /f 2>$null | Out-Null; if ($LASTEXITCODE -eq 0) { $od++ } }
        [gc]::Collect(); Start-Sleep -Milliseconds 300
        & reg.exe unload 'HKU\LabStartTmp' 2>$null | Out-Null
    }
    if ($od) { $did += "OneDrive setup start-up x$od removed" }
    # 4. High performance power plan
    $hp = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'
    if ((& powercfg.exe /getactivescheme) -notmatch $hp) { & powercfg.exe /setactive $hp 2>$null | Out-Null; if ($LASTEXITCODE -eq 0) { $did += 'High performance power plan' } }
    # 4b. Microsoft Store app auto-updates: the Store updates its built-in apps over the lab's internet connection
    #     (Xbox, Maps, Photos, ...), each install scanned by Defender - hours of disk load on a fresh lab.
    #     The images switch Windows Update off, but the Store has its own installer, so set the Store policy.
    $sk = 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore'
    if ((Get-ItemProperty $sk -ErrorAction SilentlyContinue).AutoDownload -ne 2) {
        # reg.exe rather than New-Item: a Group Policy refresh can briefly mark the Policies key for deletion
        & reg.exe add 'HKLM\SOFTWARE\Policies\Microsoft\WindowsStore' /v AutoDownload /t REG_DWORD /d 2 /f 2>$null | Out-Null
        $st = Get-ScheduledTask -TaskPath '\Microsoft\Windows\WindowsUpdate\' -TaskName 'Automatic App Update' -ErrorAction SilentlyContinue
        if ($st -and $st.State -ne 'Disabled') { $st | Disable-ScheduledTask -ErrorAction SilentlyContinue | Out-Null }
        if ((Get-ItemProperty $sk -ErrorAction SilentlyContinue).AutoDownload -eq 2) { $did += 'Store app auto-updates off' }
    }
    # 4c. Update agents and Windows maintenance (engine 1.5.0, from the 25 Nov 2026 launch tests in CTPS and CCSA):
    #     browsers, OneDrive and Windows Update download and install on every launch and after every resume
    #     (about 1 GB per VM for Chrome/Edge/WebView2 alone), and Windows starts its idle maintenance about
    #     12 minutes after boot (disk clean-up, component clean-up, disk check, memory diagnostic). Policies are
    #     reversible; nothing on the Gaia VMs is touched. Windows protects a few update tasks and services - those
    #     are covered by the policies and reported, not fought.
    $pol = {
        param([string]$Key, [string]$Name, $Value, [string]$Type = 'REG_DWORD')
        $cur = $null; try { $cur = (Get-ItemProperty ('Registry::' + ($Key -replace '^HKLM\\', 'HKEY_LOCAL_MACHINE\')) -Name $Name -ErrorAction Stop).$Name } catch {}
        if ("$cur" -eq "$Value") { return $false }
        & reg.exe add $Key /v $Name /t $Type /d $Value /f 2>$null | Out-Null
        return ($LASTEXITCODE -eq 0)
    }
    $svcOff = {
        param([string[]]$Names)
        $n = 0
        foreach ($sv in @(Get-Service -Name $Names -ErrorAction SilentlyContinue)) {
            if ($sv.StartType -eq 'Disabled' -and $sv.Status -eq 'Stopped') { continue }
            Stop-Service $sv.Name -Force -ErrorAction SilentlyContinue
            Set-Service $sv.Name -StartupType Disabled -ErrorAction SilentlyContinue
            & sc.exe config $sv.Name start= disabled 2>$null | Out-Null
            if ((Get-Service $sv.Name -ErrorAction SilentlyContinue).StartType -eq 'Disabled') { $n++ }
        }
        $n
    }
    $taskOff = {
        param([scriptblock]$Match)
        $n = 0
        foreach ($st in @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object $Match)) {
            if ($st.State -eq 'Disabled') { continue }
            try { $st | Disable-ScheduledTask -ErrorAction Stop | Out-Null; $n++ } catch {}
        }
        $n
    }
    # Browser and OneDrive updaters
    $ch = 0
    $P = 'HKLM\SOFTWARE\Policies'
    foreach ($v in @(@("$P\Microsoft\EdgeUpdate", 'UpdateDefault', 0), @("$P\Microsoft\EdgeUpdate", 'AutoUpdateCheckPeriodMinutes', 0),
                     @("$P\Google\Update", 'UpdateDefault', 0), @("$P\Google\Update", 'AutoUpdateCheckPeriodMinutes', 0),
                     @("$P\Mozilla\Firefox", 'DisableAppUpdate', 1), @("$P\Mozilla\Firefox", 'BackgroundAppUpdate', 0))) {
        if (& $pol $v[0] $v[1] $v[2]) { $ch++ }
    }
    $ch += & $svcOff @('edgeupdate', 'edgeupdatem', 'gupdate', 'gupdatem', 'GoogleUpdater*', 'MozillaMaintenance')
    $ch += & $taskOff { $_.TaskName -like 'MicrosoftEdgeUpdateTask*' -or $_.TaskName -like 'GoogleUpdate*' -or $_.TaskPath -like '\GoogleSystem\*' -or
                        $_.TaskPath -like '\Mozilla\*' -or $_.TaskName -like 'OneDrive Standalone Update Task*' -or $_.TaskName -like 'OneDrive Reporting Task*' -or
                        $_.TaskName -like 'OneDrive Per-Machine Standalone Update*' }
    if ($ch) { $did += 'Edge, Chrome, Firefox and OneDrive updaters off' }
    # Windows Update and Delivery Optimization (peer-to-peer download) - the images try, but updates still came in CTPS
    $ch = 0
    $W = "$P\Microsoft\Windows\WindowsUpdate"
    foreach ($v in @(@($W, 'DoNotConnectToWindowsUpdateInternetLocations', 1), @($W, 'DisableWindowsUpdateAccess', 1),
                     @($W, 'WUServer', 'http://127.0.0.1:8530', 'REG_SZ'), @($W, 'WUStatusServer', 'http://127.0.0.1:8530', 'REG_SZ'),
                     @("$W\AU", 'UseWUServer', 1), @("$W\AU", 'NoAutoUpdate', 1), @("$W\AU", 'AUOptions', 1),
                     @("$P\Microsoft\Windows\DeliveryOptimization", 'DODownloadMode', 99))) {
        if ($v.Count -gt 3) { if (& $pol $v[0] $v[1] $v[2] $v[3]) { $ch++ } } elseif (& $pol $v[0] $v[1] $v[2]) { $ch++ }
    }
    $ch += & $svcOff @('wuauserv', 'UsoSvc', 'DoSvc', 'InstallService')
    # Their scheduled tasks too (engine 1.6.0). Windows protects some of them; those stay covered by the policies above.
    $ch += & $taskOff { $_.TaskPath -like '\Microsoft\Windows\WindowsUpdate\*' -or $_.TaskPath -like '\Microsoft\Windows\UpdateOrchestrator\*' -or
                        $_.TaskPath -like '\Microsoft\Windows\InstallService\*' }
    if ($ch) { $did += 'Windows Update and Delivery Optimization off' }
    # Telemetry and compatibility inventory at the minimum (the DiagTrack service is switched off in step 2)
    $ch = 0
    foreach ($v in @(@("$P\Microsoft\Windows\DataCollection", 'AllowTelemetry', 0), @("$P\Microsoft\Windows\DataCollection", 'DoNotShowFeedbackNotifications', 1),
                     @("$P\Microsoft\Windows\AppCompat", 'DisableInventory', 1), @("$P\Microsoft\Windows\AppCompat", 'AITEnable', 0),
                     @("$P\Microsoft\SQMClient\Windows", 'CEIPEnable', 0))) {
        if (& $pol $v[0] $v[1] $v[2]) { $ch++ }
    }
    if ($ch) { $did += 'telemetry policy at minimum' }
    # Windows automatic (idle) maintenance and its heavy tasks
    $ch = 0
    if (& $pol 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\Maintenance' 'MaintenanceDisabled' 1) { $ch++ }
    $mt = @('\Microsoft\Windows\DiskCleanup\SilentCleanup', '\Microsoft\Windows\Servicing\StartComponentCleanup', '\Microsoft\Windows\Chkdsk\ProactiveScan',
            '\Microsoft\Windows\DiskFootprint\StorageSense', '\Microsoft\Windows\DiskFootprint\Diagnostics', '\Microsoft\Windows\MemoryDiagnostic\RunFullMemoryDiagnostic',
            '\Microsoft\Windows\MemoryDiagnostic\ProcessMemoryDiagnosticEvents', '\Microsoft\Windows\Registry\RegIdleBackup',
            '\Microsoft\Windows\Power Efficiency Diagnostics\AnalyzeSystem', '\Microsoft\Windows\Diagnosis\Scheduled', '\Microsoft\Windows\Speech\SpeechModelDownloadTask',
            '\Microsoft\Windows\Device Setup\Metadata Refresh', '\Microsoft\Windows\Sysmain\WsSwapAssessmentTask', '\Microsoft\Windows\Sysmain\ResPriStaticDbSync')
    $ch += & $taskOff { $mt -contains ($_.TaskPath + $_.TaskName) }
    if ($ch) { $did += 'Windows automatic maintenance off (disk/component clean-up, disk check, memory diagnostic)' }
    # Optional (off unless the course asks for it): Defender definition and cloud updates - only where Defender is the
    # antivirus actually running, and never where Check Point Endpoint is installed. Real-time protection stays on.
    if ($QuietDefender) {
        $cpEp = @(Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like '*Check Point Endpoint*' -or $_.DisplayName -like '*Harmony Endpoint*' }).Count -gt 0 -or
                (Test-Path 'C:\Program Files (x86)\CheckPoint\Endpoint Security')
        $mp = $null; try { $mp = Get-MpComputerStatus -ErrorAction Stop } catch {}
        if ($cpEp) { $did += 'Defender left alone (Check Point Endpoint installed)' }
        elseif ($mp -and $mp.AMServiceEnabled) {
            try { Set-MpPreference -SignatureScheduleDay 8 -SignatureUpdateInterval 0 -MAPSReporting 0 -SubmitSamplesConsent 2 -SignatureDisableUpdateOnStartupWithoutEngine $true -ErrorAction Stop; $did += 'Defender definition and cloud updates off (real-time protection on)' } catch {}
        }
    }
    # 5. Windows Update download cache (updates are not used in the lab)
    $wu = Get-Service wuauserv -ErrorAction SilentlyContinue
    $dl = 'C:\Windows\SoftwareDistribution\Download'
    if ($wu -and $wu.Status -ne 'Running' -and (Test-Path $dl)) {
        $sz = [double](Get-ChildItem $dl -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
        if ($sz -gt 50MB) { Get-ChildItem $dl -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue; $did += ('update cache cleared (' + [math]::Round($sz / 1GB, 1) + ' GB)') }
    }
    # 5b. Delivery Optimization cache (engine 1.6.0; 1.3-1.8 GB found in the CTPS and CCSA images). DoSvc was stopped in 4c.
    $doSv = Get-Service DoSvc -ErrorAction SilentlyContinue
    $doc = 'C:\Windows\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache'
    if ((-not $doSv -or $doSv.Status -ne 'Running') -and (Test-Path $doc)) {
        $sz = [double](Get-ChildItem $doc -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
        if ($sz -gt 50MB) { Get-ChildItem $doc -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue; $did += ('Delivery Optimization cache cleared (' + [math]::Round($sz / 1GB, 1) + ' GB)') }
    }
    # 6. Scheduled tasks that only create background disk and CPU work in a lab (.NET image building is left alone;
    #    update agents and Windows maintenance are handled in 4c)
    $tasks = @(
        @('\Microsoft\Windows\Defrag\', 'ScheduledDefrag'),
        @('\Microsoft\Windows\Application Experience\', 'Microsoft Compatibility Appraiser'),
        @('\Microsoft\Windows\Application Experience\', 'ProgramDataUpdater'),
        @('\Microsoft\Windows\Application Experience\', 'StartupAppTask'),
        @('\Microsoft\Windows\Customer Experience Improvement Program\', 'Consolidator'),
        @('\Microsoft\Windows\Customer Experience Improvement Program\', 'UsbCeip'),
        @('\Microsoft\Windows\Customer Experience Improvement Program\', 'KernelCeipTask'),
        @('\Microsoft\Windows\DiskDiagnostic\', 'Microsoft-Windows-DiskDiagnosticDataCollector'),
        @('\Microsoft\Windows\Maintenance\', 'WinSAT'),
        @('\Microsoft\Windows\Windows Error Reporting\', 'QueueReporting'),
        @('\Microsoft\Windows\Feedback\Siuf\', 'DmClient'),
        @('\Microsoft\Windows\Feedback\Siuf\', 'DmClientOnScenarioDownload'),
        @('\Microsoft\Windows\Maps\', 'MapsUpdateTask'),
        @('\Microsoft\Windows\Maps\', 'MapsToastTask')
    )
    $tOff = 0
    foreach ($t in $tasks) {
        $st = Get-ScheduledTask -TaskPath $t[0] -TaskName $t[1] -ErrorAction SilentlyContinue
        if ($st -and $st.State -ne 'Disabled') { $st | Disable-ScheduledTask -ErrorAction SilentlyContinue | Out-Null; $tOff++ }
    }
    # The rest of the Application Experience folder (PcaPatchDbTask, MareBackup, AitAgent - names vary by build)
    foreach ($st in @(Get-ScheduledTask -TaskPath '\Microsoft\Windows\Application Experience\' -ErrorAction SilentlyContinue)) {
        if ($st.State -ne 'Disabled') { $st | Disable-ScheduledTask -ErrorAction SilentlyContinue | Out-Null; $tOff++ }
    }
    if ($tOff) { $did += "$tOff background tasks off (incl. weekly disk optimisation)" }
    # 6b. Stop runs already in progress (engine 1.6.0): disabling a task does not end a run that has started, and in the
    #     26 Nov CTPS test CompatTelRunner, Firefox's background update and OneDrive's updater kept going for minutes
    #     after the settings were in. Browser installers (setup.exe) are deliberately left to finish.
    $stopped = 0
    foreach ($st in @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object {
            $_.State -eq 'Running' -and ($_.TaskPath -like '\Microsoft\Windows\Application Experience\*' -or
            ($_.TaskPath -like '\Mozilla\*' -and $_.TaskName -like 'Firefox Background Update*') -or $_.TaskName -like 'OneDrive*Update*' -or $_.TaskName -like 'OneDrive Reporting Task*') })) {
        try { $st | Stop-ScheduledTask -ErrorAction Stop; $stopped++ } catch {}
    }
    foreach ($pr in @(Get-Process -Name CompatTelRunner -ErrorAction SilentlyContinue)) { try { $pr | Stop-Process -Force -ErrorAction Stop; $stopped++ } catch {} }
    if ($stopped) { $did += "$stopped background runs in progress stopped (compatibility appraiser, Firefox/OneDrive updaters)" }
    # 7. Hibernation (frees hiberfil.sys), Windows Error Reporting, Print Spooler on servers
    if (Test-Path 'C:\hiberfil.sys' -ErrorAction SilentlyContinue) { & powercfg.exe /hibernate off 2>$null | Out-Null; $did += 'hibernation off' }
    $wer = 'HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting'
    if ((Get-ItemProperty $wer -ErrorAction SilentlyContinue).Disabled -ne 1) {
        New-Item -Path $wer -Force -ErrorAction SilentlyContinue | Out-Null
        New-ItemProperty -Path $wer -Name Disabled -Value 1 -PropertyType DWord -Force -ErrorAction SilentlyContinue | Out-Null
        $sv = Get-Service WerSvc -ErrorAction SilentlyContinue
        if ($sv) { Stop-Service WerSvc -Force -ErrorAction SilentlyContinue; Set-Service WerSvc -StartupType Disabled -ErrorAction SilentlyContinue }
        $did += 'error reporting off'
    }
    if ((Get-CimInstance Win32_OperatingSystem).ProductType -ne 1) {
        $sv = Get-Service Spooler -ErrorAction SilentlyContinue
        if ($sv -and $sv.StartType -ne 'Disabled') { Stop-Service Spooler -Force -ErrorAction SilentlyContinue; Set-Service Spooler -StartupType Disabled -ErrorAction SilentlyContinue; $did += 'Print Spooler off (server)' }
    }
    # 8. Visual effects: best performance for every user (registry for loaded profiles, other profiles and the
    #    default profile), and switched off at once in the sessions that are logged on now.
    $vfx = {
        param([string]$Root)   # e.g. Registry::HKEY_USERS\S-1-5-21-...
        $set = {
            param($Path, $Name, $Value, $Type)
            if (-not (Test-Path $Path)) { New-Item -Path $Path -Force -ErrorAction SilentlyContinue | Out-Null }
            New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force -ErrorAction SilentlyContinue | Out-Null
        }
        & $set "$Root\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects" 'VisualFXSetting' 2 'DWord'
        & $set "$Root\Control Panel\Desktop" 'UserPreferencesMask' ([byte[]](0x90, 0x12, 0x03, 0x80, 0x10, 0x00, 0x00, 0x00)) 'Binary'
        & $set "$Root\Control Panel\Desktop" 'DragFullWindows' '0' 'String'
        & $set "$Root\Control Panel\Desktop\WindowMetrics" 'MinAnimate' '0' 'String'
        & $set "$Root\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" 'TaskbarAnimations' 0 'DWord'
        & $set "$Root\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" 'ListviewAlphaSelect' 0 'DWord'
        & $set "$Root\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize" 'EnableTransparency' 0 'DWord'
    }
    $vu = 0
    foreach ($h in @(Get-ChildItem 'Registry::HKEY_USERS' -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match '^S-1-5-21-[\d-]+$' })) { & $vfx "Registry::HKEY_USERS\$($h.PSChildName)"; $vu++ }
    $hives = @(Get-CimInstance Win32_UserProfile -ErrorAction SilentlyContinue | Where-Object { -not $_.Loaded -and -not $_.Special } | ForEach-Object { Join-Path $_.LocalPath 'NTUSER.DAT' }) + @('C:\Users\Default\NTUSER.DAT')
    foreach ($f in $hives) {
        if (-not (Test-Path $f)) { continue }
        & reg.exe load 'HKU\LabStartVfx' $f 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { continue }
        & $vfx 'Registry::HKEY_USERS\LabStartVfx'; $vu++
        [gc]::Collect(); Start-Sleep -Milliseconds 300
        & reg.exe unload 'HKU\LabStartVfx' 2>$null | Out-Null
    }
    try {
        $dir = 'C:\scripts\LabStart'; New-Item -ItemType Directory -Force -Path $dir | Out-Null
        $vs = @(
            "Add-Type -Namespace LabStart -Name Vfx -MemberDefinition '[DllImport(""user32.dll"")] public static extern bool SystemParametersInfo(uint a, uint b, IntPtr c, uint d);'",
            '[void][LabStart.Vfx]::SystemParametersInfo(0x103F, 0, [IntPtr]::Zero, 3)',
            '[void][LabStart.Vfx]::SystemParametersInfo(0x1043, 0, [IntPtr]::Zero, 3)',
            '[void][LabStart.Vfx]::SystemParametersInfo(0x0025, 0, [IntPtr]::Zero, 3)',
            '[void][LabStart.Vfx]::SystemParametersInfo(0x1005, 0, [IntPtr]::Zero, 3)',
            '[void][LabStart.Vfx]::SystemParametersInfo(0x1013, 0, [IntPtr]::Zero, 3)'
        ) -join "`r`n"
        $vf = Join-Path $dir 'session_visual.ps1'
        Set-Content -Path $vf -Value $vs -Encoding Unicode
        $users = ([Security.Principal.SecurityIdentifier]'S-1-5-32-545').Translate([Security.Principal.NTAccount]).Value
        $tn = 'LabStart-UserVisual'
        Register-ScheduledTask -TaskName $tn -Action (New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$vf`"") -Principal (New-ScheduledTaskPrincipal -GroupId $users -RunLevel Limited) -Force | Out-Null
        Start-ScheduledTask -TaskName $tn
        Start-Sleep -Seconds 6
        Unregister-ScheduledTask -TaskName $tn -Confirm:$false -ErrorAction SilentlyContinue
    } catch {}
    if ($vu) { $did += "visual effects set to best performance ($vu profiles)" }

    if (-not $did.Count) { $did = @('nothing to change') }
    return "$env:COMPUTERNAME|" + ($did -join '; ')
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
            $res.name = $parts[0]; $res.ok = $true; $res.result = "done as $u ($($parts[1]))"
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
        # Leave the login shell as found: a host that logged in to bash (e.g. CPVS Border-Router) stays on bash
        if ($isBash) { $ScriptLines = @($ScriptLines | Where-Object { $_ -notmatch 'set user admin shell /etc/cli\.sh' }) }
        [IO.File]::WriteAllText($f, (($ScriptLines -join "`n") + "`n"))
        $r = Run-Plink ("-batch $base -m " + (Q $f)) $null 150
        Remove-Item $f -Force -ErrorAction SilentlyContinue
        $clean = @($r.Out -split "`r?`n" | Where-Object { $_.Trim() -and $_ -notmatch 'Keyboard-interactive|Using username|banner' })
        $res.output = ($clean | Select-Object -First 20) -join ' | '
        if ($r.Out -match 'command not found|CLINFR\d+|NMS[A-Z]{3}\d+|Access denied') { $res.result = 'failed - see the log' }
        else { $res.ok = $true; $res.result = $(if ($ScriptLines -contains 'reboot') { 'done - restarting' } else { 'done' }) }
    } catch { $res.result = 'failed: ' + $_.Exception.Message }
    return [pscustomobject]$res
}

# Runs in a background runspace per Linux server or VyOS router: one plink command, no restart
$SshWorker = {
    param([string]$Ip, [string]$User, [string]$Pw, [string]$Plink, [string]$Command, [string]$Kind)
    $res = [ordered]@{ ip = $Ip; kind = $Kind; name = ''; ok = $false; result = ''; output = '' }
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
        try { $tcp = New-Object System.Net.Sockets.TcpClient; $ar = $tcp.BeginConnect($Ip, 22, $null, $null); $up = $ar.AsyncWaitHandle.WaitOne(2500) -and $tcp.Connected; $tcp.Close() } catch {}
        if (-not $up) { $res.result = 'skipped - not reachable on SSH (switched off?)'; return [pscustomobject]$res }
        $base = "-ssh -l $User -pw " + (Q $Pw) + " $Ip"
        $r = Run-Plink "$base exit" "y`n" 25
        if ($r.Out -match 'Access denied') { $res.result = 'failed: login refused'; return [pscustomobject]$res }
        $r = Run-Plink ("-batch $base " + (Q $Command)) $null 90
        if ($r.TimedOut) { $res.result = 'failed: no answer over SSH'; return [pscustomobject]$res }
        $lines = @($r.Out -split "`r?`n" | Where-Object { $_.Trim() -and $_ -notmatch 'Welcome to|authorized|banner|Using username|Keyboard-interactive' })
        if ($r.Out -match 'LSNAME_(\S+)') { $res.name = $Matches[1] }
        if ($r.Out -match 'LSDONE') { $res.ok = $true; $res.result = 'done' + $(if ($r.Out -match 'LSWARN_(\S+)') { " ($($Matches[1] -replace '_', ' '))" } else { '' }) }
        else { $res.result = 'failed - see the log'; $res.output = (($lines | Select-Object -Last 6) -join ' | ') }
    } catch { $res.result = 'failed: ' + $_.Exception.Message }
    return [pscustomobject]$res
}

# Runs in a background runspace per VyOS router reached through a Windows VM ('router@windowsVM')
$ViaWorker = {
    param([string]$Target, [string]$Via, [string[]]$Users, [string]$User, [string]$Pw, [string]$Plink, [string]$Command, [string]$SshText)
    $res = [ordered]@{ ip = $Target; kind = 'VyOS'; name = ''; ok = $false; result = ''; output = '' }
    try {
        $up = $false
        try { $tcp = New-Object System.Net.Sockets.TcpClient; $ar = $tcp.BeginConnect($Via, 5985, $null, $null); $up = $ar.AsyncWaitHandle.WaitOne(2500) -and $tcp.Connected; $tcp.Close() } catch {}
        if (-not $up) { $res.result = "skipped - $Via (the VM it is reached through) not reachable"; return [pscustomobject]$res }
        $sec = ConvertTo-SecureString $Pw -AsPlainText -Force
        $s = $null; $errs = @()
        foreach ($u in $Users) {
            try { $s = New-PSSession -ComputerName $Via -Credential (New-Object System.Management.Automation.PSCredential ($u, $sec)) -ErrorAction Stop; break }
            catch { $errs += "$u - " + ($_.Exception.Message -split "`n")[0] }
        }
        if (-not $s) { $res.result = "failed: no login to $Via (" + ($errs -join ' / ') + ')'; return [pscustomobject]$res }
        $remotePlink = 'C:\Windows\Temp\labstart_plink.exe'
        try {
            Copy-Item -Path $Plink -Destination $remotePlink -ToSession $s -Force -ErrorAction Stop
            $r = Invoke-Command -Session $s -ErrorAction Stop -ScriptBlock {
                param($T, $U, $P, $Pl, $C, $Txt)
                $w = [scriptblock]::Create($Txt)
                try { & $w $T $U $P $Pl $C 'VyOS' } finally { Remove-Item -Path $Pl -Force -ErrorAction SilentlyContinue }
            } -ArgumentList $Target, $User, $Pw, $remotePlink, $Command, $SshText
            $r = @($r)[0]
            $res.name = [string]$r.name; $res.ok = [bool]$r.ok; $res.output = [string]$r.output
            $res.result = ([string]$r.result -replace '^skipped - not reachable on SSH', "skipped - not reachable on SSH from $Via") + $(if ($r.ok) { " (via $Via)" } else { '' })
        } finally { Remove-PSSession $s -ErrorAction SilentlyContinue }
    } catch { $res.result = 'failed: ' + $_.Exception.Message }
    return [pscustomobject]$res
}

# ==== main ===================================================================================================
Set-Content -Path $LogFile -Value ("Camino lab localisation engine $EngineVersion on $env:COMPUTERNAME - started " + (Get-Date)) -Encoding UTF8
Write-Log "Settings: $Label"
if ($Mode -eq 'optimise') {
    Write-Log "  Optimise the Windows VMs: keep SmartConsole $($KeepSmartConsole -join ', '); update agents and maintenance off; Defender updates $(if ($QuietDefender) { 'off where safe' } else { 'left alone' }); no restarts"
    $GaiaHosts = @(); $LateGaiaHosts = @(); $LinuxHosts = @(); $VyosHosts = @(); $VyosViaHosts = @()
} else {
    Write-Log "  Windows: language list $($Languages -join ', '); time zone '$WindowsTimezone'"
    Write-Log "  Gaia:    keyboard '$GaiaKeyboard'; time zone '$GaiaRegion / $GaiaZone'" + $(if ($NoReboot) { '  (no restarts)' } else { '' })
    foreach ($k in $GaiaTzOverride.Keys) { Write-Log ("  Gaia $k keeps time zone '$($GaiaTzOverride[$k])'" + $(if ($TzOverrideNote) { " ($TzOverrideNote)" } else { '' })) }
    foreach ($k in $VyosTzOverride.Keys) { Write-Log ("  VyOS $k keeps time zone '$($VyosTzOverride[$k])'" + $(if ($VyosTzNote) { " ($VyosTzNote)" } else { '' })) }
    if ($LinuxHosts.Count -or $VyosHosts.Count -or $VyosViaHosts.Count) { Write-Log "  Linux/VyOS: time zone '$GaiaRegion/$GaiaZone' (console keyboard '$GaiaKeyboard'), no restarts" }
}
Set-Status 'running' 'Starting'

try {
    $doReboot = -not $NoReboot
    if ($Mode -eq 'optimise') { $applyBlock = $WindowsOptimise; $applyArgs = @([string[]]$KeepSmartConsole, $false, [bool]$QuietDefender) }
    else { $applyBlock = $WindowsApply; $applyArgs = @($WindowsTimezone, [string[]]$Languages, $UserScript, $doReboot, $RebootDelaySeconds) }

    # 1. RDP-HOST itself (local, never restarted). Localise: done first (quick). Optimise: runs alongside the other
    #    VMs below, without the SmartConsole clean-up, so the smallest VM in the lab does not hold the others up.
    if ($Mode -ne 'optimise') {
        Set-Status 'running' 'Applying to RDP-HOST'
        $local = & $WindowsApply $WindowsTimezone $Languages $UserScript $false 0
        $script:HostResults['local'] = [pscustomobject]@{ ip = 'local'; kind = 'Windows'; name = $env:COMPUTERNAME; ok = $true; result = 'done (' + ($local -split '\|', 2)[1] + ')' }
        Write-Log ("$env:COMPUTERNAME (this machine): " + $script:HostResults['local'].result)
    }

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
    if ($Mode -eq 'optimise') {
        $localWorker = {
            param([string]$Text, [string[]]$Keep, [bool]$Def)
            $r = [ordered]@{ ip = 'this machine'; kind = 'Windows'; name = $env:COMPUTERNAME; ok = $false; result = '' }
            try { $out = & ([scriptblock]::Create($Text)) $Keep $true $Def; $r.ok = $true; $r.result = 'done (' + (([string]$out) -split '\|', 2)[1] + ')' }
            catch { $r.result = 'failed: ' + $_.Exception.Message }
            [pscustomobject]$r
        }
        $ps = [powershell]::Create(); $ps.RunspacePool = $pool
        [void]$ps.AddScript($localWorker).AddArgument($WindowsOptimise.ToString()).AddArgument([string[]]$KeepSmartConsole).AddArgument([bool]$QuietDefender)
        $jobs += [pscustomobject]@{ Key = 'local'; Ip = 'this machine'; PS = $ps; Handle = $ps.BeginInvoke(); Done = $false }
        $script:HostResults['local'] = [pscustomobject]@{ ip = 'this machine'; kind = 'Windows'; name = $env:COMPUTERNAME; ok = $false; result = 'working' }
    }
    foreach ($ip in $WindowsHosts) {
        $ps = [powershell]::Create(); $ps.RunspacePool = $pool
        [void]$ps.AddScript($WindowsWorker).AddArgument($ip).AddArgument([string[]]@($DomainUser, $LocalUser, '.\admin')).AddArgument($Password).AddArgument($applyBlock).AddArgument([object[]]$applyArgs)
        $jobs += [pscustomobject]@{ Key = "win:$ip"; Ip = $ip; PS = $ps; Handle = $ps.BeginInvoke(); Done = $false }
        $script:HostResults["win:$ip"] = [pscustomobject]@{ ip = $ip; kind = 'Windows'; name = ''; ok = $false; result = 'working' }
    }
    $LateGaiaHosts = @($LateGaiaHosts | Where-Object { $_ -and ($GaiaHosts -notcontains $_) })
    if (-not (Test-Path $PlinkPath)) { $LateGaiaHosts = @() }
    $startGaia = {
        param([string]$ip, [string[]]$doneNames, [bool]$late)
        # A host with a time zone override keeps that zone (the keyboard and everything else still follow the choice)
        $lines = [string[]]$gaiaLines
        if ($GaiaTzOverride.ContainsKey($ip)) { $lines = [string[]]@($gaiaLines | ForEach-Object { if ($_ -like "clish -c 'set timezone *") { "clish -c 'set timezone $($GaiaTzOverride[$ip])'" } else { $_ } }) }
        $ps = [powershell]::Create(); $ps.RunspacePool = $pool
        [void]$ps.AddScript($GaiaWorker).AddArgument($ip).AddArgument($Password).AddArgument($PlinkPath).AddArgument($lines).AddArgument([string[]]$doneNames).AddArgument($late)
        $script:HostResults["gaia:$ip"] = [pscustomobject]@{ ip = $ip; kind = 'Gaia'; name = ''; ok = $false; result = 'working' }
        [pscustomobject]@{ Key = "gaia:$ip"; Ip = $ip; PS = $ps; Handle = $ps.BeginInvoke(); Done = $false; Late = $late }
    }
    foreach ($ip in $GaiaHosts) { $jobs += & $startGaia $ip @() $false }
    $lateStarted = ($LateGaiaHosts.Count -eq 0)
    # Linux servers and VyOS routers: time zone only (+ Linux console keymap); never restarted
    if (-not (Test-Path $PlinkPath)) { $LinuxHosts = @(); $VyosHosts = @(); $VyosViaHosts = @() }
    $ianaTz = "$GaiaRegion/$GaiaZone" -replace '\s', ''
    # Linux: systemd hosts (A-DMZ, CentOS) use timedatectl/localectl; Alpine (e.g. a Border-Router replaced by Router2Alpine)
    # has neither, so the time zone is linked from tzdata and the console keymap set the way setup-keymap does
    # (needs the kbd-bkeymaps package; without it the keymap is left and logged).
    $alpKbMap = @{ 'uk' = 'gb/gb'; 'us' = 'us/us'; 'de' = 'de/de'; 'fr' = 'fr/fr'; 'fr_CH' = 'ch/ch-fr'; 'sg' = 'ch/ch'; 'dk' = 'dk/dk'
                   'es' = 'es/es'; 'fi' = 'fi/fi'; 'it' = 'it/it'; 'no' = 'no/no'; 'pl' = 'pl/pl'; 'pt-latin1' = 'pt/pt'
                   'ru' = 'ru/ru'; 'se-latin1' = 'se/se'; 'trq' = 'tr/tr' }
    $alpKb = $(if ($alpKbMap.ContainsKey($GaiaKeyboard)) { $alpKbMap[$GaiaKeyboard] } else { "$GaiaKeyboard/$GaiaKeyboard" })
    $alpKbFile = ($alpKb -split '/')[1]
    $linuxCmd = "echo LSNAME_`$(hostname -s); " +
        "if command -v timedatectl >/dev/null 2>&1; then timedatectl set-timezone $ianaTz || exit 1; " +
        "elif [ -f /usr/share/zoneinfo/$ianaTz ]; then ln -sf /usr/share/zoneinfo/$ianaTz /etc/localtime && echo $ianaTz > /etc/timezone || exit 1; else echo LSWARN_no_tzdata; exit 1; fi; " +
        "if command -v localectl >/dev/null 2>&1; then localectl set-keymap $GaiaKeyboard 2>/dev/null || echo LSWARN_keymap_not_changed; " +
        "elif [ -f /usr/share/bkeymaps/$alpKb.bmap.gz ]; then mkdir -p /etc/keymap && cp /usr/share/bkeymaps/$alpKb.bmap.gz /etc/keymap/ && " +
        "sed -i 's|^#*KEYMAP=.*|KEYMAP=/etc/keymap/$alpKbFile.bmap.gz|' /etc/conf.d/loadkmap && (rc-update add loadkmap boot >/dev/null 2>&1; rc-service loadkmap restart >/dev/null 2>&1; true); " +
        "else echo LSWARN_keymap_not_installed_kbd-bkeymaps; fi; echo LSDONE"
    # VyOS only runs config commands from a script file (not vbash -c): write one, run it, remove it
    # VyOS console keyboard (system option keyboard-layout): the student's layout where VyOS has it. Set in its own
    # commit after the time zone, so a layout VyOS does not offer only gives a warning and never blocks the time zone.
    # Layouts VyOS 2026.03 offers (system/option/keyboard-layout): us uk fr de es fi it jp106 no dk se-latin1 dvorak.
    # Others (Swiss, Polish, Portuguese, Turkish, Russian, ...) are not guessed: the router keyboard is left and logged.
    $vyKbOk = @('us', 'uk', 'fr', 'de', 'es', 'fi', 'it', 'no', 'dk', 'se-latin1')
    $vyKb = $(if ($vyKbOk -contains $GaiaKeyboard) { $GaiaKeyboard } else { '' })
    function Get-VyosCmd([string]$Tz) {
        "echo LSNAME_`$(cat /etc/hostname); " +
        "printf '%s\n' '#!/bin/vbash' 'source /opt/vyatta/etc/functions/script-template' 'configure' 'set system time-zone $Tz' 'commit' 'save' 'exit' > /tmp/lstz.sh; /bin/vbash /tmp/lstz.sh; rc=`$?; rm -f /tmp/lstz.sh; " +
        $(if ($vyKb) { "printf '%s\n' '#!/bin/vbash' 'source /opt/vyatta/etc/functions/script-template' 'configure' 'set system option keyboard-layout $vyKb || exit 3' 'commit || exit 3' 'save' 'exit discard' > /tmp/lskb.sh; /bin/vbash /tmp/lskb.sh >/dev/null 2>&1 || echo LSWARN_keyboard_${vyKb}_not_set; rm -f /tmp/lskb.sh; " }
          else { "echo LSWARN_no_VyOS_keyboard_layout_for_$GaiaKeyboard; " }) +
        "[ `$rc -eq 0 ] && echo LSDONE"
    }
    $vyosCmd = Get-VyosCmd $ianaTz
    foreach ($ip in $LinuxHosts) {
        $ps = [powershell]::Create(); $ps.RunspacePool = $pool
        [void]$ps.AddScript($SshWorker).AddArgument($ip).AddArgument($LinuxUser).AddArgument($Password).AddArgument($PlinkPath).AddArgument($linuxCmd).AddArgument('Linux')
        $jobs += [pscustomobject]@{ Key = "linux:$ip"; Ip = $ip; PS = $ps; Handle = $ps.BeginInvoke(); Done = $false }
        $script:HostResults["linux:$ip"] = [pscustomobject]@{ ip = $ip; kind = 'Linux'; name = ''; ok = $false; result = 'working' }
    }
    foreach ($ip in $VyosHosts) {
        $ps = [powershell]::Create(); $ps.RunspacePool = $pool
        $cmd = $(if ($VyosTzOverride.ContainsKey($ip)) { Get-VyosCmd $VyosTzOverride[$ip] } else { $vyosCmd })
        [void]$ps.AddScript($SshWorker).AddArgument($ip).AddArgument($VyosUser).AddArgument($Password).AddArgument($PlinkPath).AddArgument($cmd).AddArgument('VyOS')
        $jobs += [pscustomobject]@{ Key = "vyos:$ip"; Ip = $ip; PS = $ps; Handle = $ps.BeginInvoke(); Done = $false }
        $script:HostResults["vyos:$ip"] = [pscustomobject]@{ ip = $ip; kind = 'VyOS'; name = ''; ok = $false; result = 'working' }
    }
    foreach ($pair in $VyosViaHosts) {
        $t, $v = ($pair -split '@', 2)
        if (-not $t -or -not $v) { continue }
        $ps = [powershell]::Create(); $ps.RunspacePool = $pool
        $cmd = $(if ($VyosTzOverride.ContainsKey($t)) { Get-VyosCmd $VyosTzOverride[$t] } else { $vyosCmd })
        [void]$ps.AddScript($ViaWorker).AddArgument($t).AddArgument($v).AddArgument([string[]]@($DomainUser, $LocalUser, '.\admin')).AddArgument($VyosUser).AddArgument($Password).AddArgument($PlinkPath).AddArgument($cmd).AddArgument($SshWorker.ToString())
        $jobs += [pscustomobject]@{ Key = "vyos:$t"; Ip = $t; PS = $ps; Handle = $ps.BeginInvoke(); Done = $false }
        $script:HostResults["vyos:$t"] = [pscustomobject]@{ ip = $t; kind = 'VyOS'; name = ''; ok = $false; result = 'working' }
    }
    $nSsh = $LinuxHosts.Count + $VyosHosts.Count + $VyosViaHosts.Count
    Set-Status 'running' ("Applying to $($WindowsHosts.Count) Windows VMs and $($GaiaHosts.Count + $LateGaiaHosts.Count) Gaia hosts" + $(if ($nSsh) { " and $nSsh Linux/VyOS" } else { '' }))

    $startedAt = Get-Date; $lastNote = $null
    $deadline = (Get-Date).AddMinutes($(if ($Mode -eq 'optimise') { 20 } else { 8 }))
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
            if ($j.Key -like 'gaia:*' -and "$($r.result)" -eq 'failed: login refused' -and -not $script:HostResults.Contains("linux:$($j.Ip)") -and (Test-Path $PlinkPath)) {
                Write-Log ("{0,-8} {1}: Gaia login refused - trying it as a Linux router (root)" -f 'Gaia', $j.Ip)
                $script:HostResults.Remove($j.Key)
                $ps = [powershell]::Create(); $ps.RunspacePool = $pool
                [void]$ps.AddScript($SshWorker).AddArgument($j.Ip).AddArgument($LinuxUser).AddArgument($Password).AddArgument($PlinkPath).AddArgument($linuxCmd).AddArgument('Linux')
                $jobs += [pscustomobject]@{ Key = "linux:$($j.Ip)"; Ip = $j.Ip; PS = $ps; Handle = $ps.BeginInvoke(); Done = $false }
                $script:HostResults["linux:$($j.Ip)"] = [pscustomobject]@{ ip = $j.Ip; kind = 'Linux'; name = ''; ok = $false; result = 'working' }
                continue
            }
            $script:HostResults[$j.Key] = $r
            $who = $(if ($r.name) { "$($r.name) ($($r.ip))" } else { $r.ip })
            $kept = $(if ($j.Key -like 'gaia:*') { $GaiaTzOverride[$j.Ip] } elseif ($j.Key -like 'vyos:*') { $VyosTzOverride[$j.Ip] } else { $null })
            $note = $(if ($j.Key -like 'vyos:*') { $VyosTzNote } else { $TzOverrideNote })
            if ($kept -and $r.ok) { $r.result = "$($r.result); time zone kept at $kept" + $(if ($note) { " ($note)" } else { '' }) }
            Write-Log ("{0,-8} {1}: {2}" -f $r.kind, $who, $r.result)
            if ($r.output) { Write-Log "         output: $($r.output)" }
            $done = @($jobs | Where-Object { $_.Done }).Count
            Set-Status 'running' "Applying ($done of $($jobs.Count) hosts finished)"
        }
        # Every 30 s, name the hosts still working, so a slow VM (1 GB RAM on some images) does not look like a hang
        if (-not $lastNote -or ((Get-Date) - $lastNote).TotalSeconds -ge 30) {
            $lastNote = Get-Date
            $left = @($jobs | Where-Object { -not $_.Done } | ForEach-Object { $_.Ip })
            if ($left.Count -and $left.Count -le 4) {
                $mins = [math]::Floor(((Get-Date) - $startedAt).TotalMinutes)
                Set-Status 'running' ("Applying ($($jobs.Count - $left.Count) of $($jobs.Count) finished; still working after $mins min: " + ($left -join ', ') + ')')
            }
        }
        Start-Sleep -Milliseconds 500
    }
    foreach ($j in ($jobs | Where-Object { -not $_.Done })) { try { $j.PS.Stop() } catch {}; $script:HostResults[$j.Key] = [pscustomobject]@{ ip = $j.Ip; kind = '?'; ok = $false; result = $(if ($Mode -eq 'optimise') { 'failed: timed out after 20 min (settings already made on that VM stay; run Optimise again later)' } else { 'failed: timed out' }) } }
    $pool.Close()

    # 3. Cluster: make the member the lab guide expects the Active one (e.g. CPVS: A-GW-01, Labs 2A-3, 2B-4, 3A-1, 3B-2).
    #    The peer is set to admin down so the member takes over, then straight back up; with the cluster's usual
    #    "maintain current active" setting the member stays Active. Gaia clish only; nothing is saved to the config.
    if ($Mode -eq 'localise' -and $ClusterActive -and $ClusterActive.member -and $ClusterActive.peer -and (Test-Path $PlinkPath)) {
        $cm = [string]$ClusterActive.member; $cp = [string]$ClusterActive.peer
        $why = $(if ($ClusterActive.note) { " ($($ClusterActive.note))" } else { '' })
        $nm = { param($ip) $h = $script:HostResults["gaia:$ip"]; if ($h -and $h.name) { "$($h.name) ($ip)" } else { $ip } }
        $mName = & $nm $cm; $pName = & $nm $cp
        function Invoke-Clish([string]$Ip, [string]$Cmd) {
            foreach ($c in @($Cmd, "clish -c `"$Cmd`"")) {      # clish login shell first, then a bash login shell
                $psi = New-Object System.Diagnostics.ProcessStartInfo
                $psi.FileName = $PlinkPath; $psi.Arguments = "-batch -ssh -l admin -pw `"$Password`" $Ip `"" + ($c -replace '"', '"') + '"'
                $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
                $pr = [System.Diagnostics.Process]::Start($psi); $o = $pr.StandardOutput.ReadToEndAsync(); $e = $pr.StandardError.ReadToEndAsync()
                if (-not $pr.WaitForExit(45000)) { try { $pr.Kill() } catch {} }
                $out = "$($o.Result)`n$($e.Result)"
                if ($out -notmatch 'command not found') { return $out }
            }
            return $out
        }
        function Get-LocalClusterState([string]$Ip) {
            $o = Invoke-Clish $Ip 'show cluster state'
            $l = @($o -split "`r?`n" | Where-Object { $_ -match '\(local\)' }) | Select-Object -First 1
            if ($l -match '\b(ACTIVE|STANDBY|DOWN|READY|INIT|LOST)\b') { return $Matches[1] }
            return '?'
        }
        if ($doReboot) { Write-Log "Cluster: $mName not made Active - the VMs are restarting (run Localise again without restart, or fail over by hand)" }
        elseif (-not ($script:HostResults["gaia:$cm"].ok -and $script:HostResults["gaia:$cp"].ok)) { Write-Log "Cluster: left as it is - $mName or $pName was not reachable" }
        else {
            Set-Status 'running' "Making $mName the Active cluster member"
            $sm = Get-LocalClusterState $cm
            if ($sm -eq 'ACTIVE') { Write-Log "Cluster: $mName is already the Active member$why" }
            elseif ((Get-LocalClusterState $cp) -ne 'ACTIVE') { Write-Log "Cluster: left as it is - $mName is $sm and $pName is not Active either (check: show cluster state)" }
            else {
                Write-Log "Cluster: $pName is Active - handing over to $mName$why"
                [void](Invoke-Clish $cp 'lock database override')
                [void](Invoke-Clish $cp 'set cluster member admin down')
                $deadline2 = (Get-Date).AddSeconds(60)
                do { Start-Sleep -Seconds 5; $sm = Get-LocalClusterState $cm } while ($sm -ne 'ACTIVE' -and (Get-Date) -lt $deadline2)
                [void](Invoke-Clish $cp 'lock database override')
                [void](Invoke-Clish $cp 'set cluster member admin up')      # always, so the peer never stays down
                Start-Sleep -Seconds 15
                $sm = Get-LocalClusterState $cm; $sp = Get-LocalClusterState $cp
                if ($sm -eq 'ACTIVE') { Write-Log "Cluster: $mName is now the Active member, $pName is $sp$why" }
                else { Write-Log "Cluster: WARNING - $mName is $sm and $pName is $sp after the handover (the cluster may prefer $pName; check: show cluster state)" }
            }
        }
    }

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
