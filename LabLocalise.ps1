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
    [switch]$NoReboot,
    # 'localise' (keyboard + time zone) or 'optimise' (Windows VM clean-up, never restarts)
    [ValidateSet('localise', 'optimise')][string]$Mode = 'localise',
    [string[]]$KeepSmartConsole = @('R82')
)

$ErrorActionPreference = 'Stop'
$EngineVersion = '1.2.0'

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
            'mode'               { $Mode = [string]$p.Value }
            'keepSmartConsole'   { $KeepSmartConsole = @($p.Value | ForEach-Object { [string]$_ }) }
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
    if ($DoReboot) { & shutdown.exe /r /t $Delay /c 'Lab Start: applying keyboard and time zone' | Out-Null; $extra = ', restarting' }
    else {
        # No restart: run the logon script now inside every session that is already logged on (a task for the
        # Users group runs in each logged-on user's session), so the keyboard changes without logging off.
        # The script sets the language list and also switches the active keyboard of the open session (the same
        # as picking it from the taskbar), because an unchanged list does not refresh a session that is already open.
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
                "Add-Type -Namespace LabStart -Name Kbd -MemberDefinition '[DllImport(""user32.dll"")] public static extern IntPtr LoadKeyboardLayout(string id, uint flags); [DllImport(""user32.dll"")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l); [DllImport(""user32.dll"")] public static extern bool SystemParametersInfo(uint a, uint b, ref IntPtr c, uint d); [DllImport(""user32.dll"")] public static extern IntPtr FindWindow(string c, string w); [DllImport(""user32.dll"")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint p); [DllImport(""user32.dll"")] public static extern IntPtr GetKeyboardLayout(uint t);'",
                "`$h = [LabStart.Kbd]::LoadKeyboardLayout(`$klid, 1)",
                "[void][LabStart.Kbd]::SystemParametersInfo(0x5A, 0, [ref]`$h, 2)",
                "[void][LabStart.Kbd]::PostMessage([IntPtr]0xffff, 0x50, [IntPtr]::Zero, `$h)",
                "`$want = [Convert]::ToInt32(`$klid.Substring(4), 16)",
                "function Get-TrayLang { `$t = [LabStart.Kbd]::FindWindow('Shell_TrayWnd', `$null); if (`$t -eq [IntPtr]::Zero) { return -1 }; `$p = 0; `$tid = [LabStart.Kbd]::GetWindowThreadProcessId(`$t, [ref]`$p); return ([LabStart.Kbd]::GetKeyboardLayout(`$tid).ToInt64() -band 0xFFFF) }",
                "Start-Sleep -Milliseconds 800",
                "`$how = 'switched'",
                "`$cur = Get-TrayLang",
                "if (`$cur -ne -1 -and `$cur -ne `$want) { [void][LabStart.Kbd]::PostMessage([LabStart.Kbd]::FindWindow('Shell_TrayWnd', `$null), 0x50, [IntPtr]::Zero, `$h); Start-Sleep -Milliseconds 800; `$cur = Get-TrayLang; `$how = 'taskbar' }",
                "if (`$cur -ne -1 -and `$cur -ne `$want) { Get-Process explorer -ErrorAction SilentlyContinue | Where-Object { `$_.SessionId -eq (Get-Process -Id `$PID).SessionId } | Stop-Process -Force; Start-Sleep -Seconds 2; if (-not (Get-Process explorer -ErrorAction SilentlyContinue | Where-Object { `$_.SessionId -eq (Get-Process -Id `$PID).SessionId })) { Start-Process explorer.exe }; `$how = 'explorer restarted' }",
                "try { Add-Content -Path '$logS' -Value ((Get-Date -Format s) + ' ' + `$env:USERDOMAIN + '\' + `$env:USERNAME + ' ' + `$klid + ' ' + `$how) } catch {}"
            ) -join "`r`n"
            $sessFile = Join-Path $dir 'session_keyboard.ps1'
            Set-Content -Path $sessFile -Value $sess -Encoding Unicode
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
            $extra = $(if ($n) { ", keyboard switched in $n logged-on session(s)" } else { ', no logged-on session (keyboard applies at log-on)' })
        } catch { $extra = ', keyboard at next log-on' }
    }
    return "$env:COMPUTERNAME|time zone now $tzNow$extra"
}

# Optimise mode: runs on each Windows VM (and locally on RDP-HOST). Reversible clean-up, no restart.
$WindowsOptimise = {
    param([string[]]$KeepSC)
    $ErrorActionPreference = 'Continue'
    $did = @()
    # 1. SmartConsole versions not in the keep list: delete folder, uninstall entry, Start menu / desktop shortcuts
    $removed = @(); $freed = 0
    foreach ($k in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall') {
        foreach ($e in @(Get-ChildItem $k -ErrorAction SilentlyContinue)) {
            $pr = Get-ItemProperty $e.PSPath -ErrorAction SilentlyContinue
            if (-not ("$($pr.DisplayName)" -match '^Check Point SmartConsole (R[\d.]+)')) { continue }
            $ver = $Matches[1]
            if ($KeepSC -contains $ver) { continue }
            $loc = "C:\Program Files (x86)\CheckPoint\SmartConsole\$ver"
            if (-not (Test-Path $loc) -and $pr.InstallLocation -and (Test-Path $pr.InstallLocation)) { $loc = $pr.InstallLocation }
            if ($loc -and (Test-Path $loc) -and ($loc -match 'CheckPoint')) {
                Get-Process -ErrorAction SilentlyContinue | Where-Object { try { $_.Path -like "$loc*" } catch { $false } } | Stop-Process -Force -ErrorAction SilentlyContinue
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
    # 5. Windows Update download cache (updates are not used in the lab)
    $wu = Get-Service wuauserv -ErrorAction SilentlyContinue
    $dl = 'C:\Windows\SoftwareDistribution\Download'
    if ($wu -and $wu.Status -ne 'Running' -and (Test-Path $dl)) {
        $sz = [double](Get-ChildItem $dl -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
        if ($sz -gt 50MB) { Get-ChildItem $dl -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue; $did += ('update cache cleared (' + [math]::Round($sz / 1GB, 1) + ' GB)') }
    }
    # 6. Scheduled tasks that only create background disk and CPU work in a lab (updates and .NET image building are left alone)
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
    if ($tOff) { $did += "$tOff background tasks off (incl. weekly disk optimisation)" }
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

# ==== main ===================================================================================================
Set-Content -Path $LogFile -Value ("Camino lab localisation engine $EngineVersion on $env:COMPUTERNAME - started " + (Get-Date)) -Encoding UTF8
Write-Log "Settings: $Label"
if ($Mode -eq 'optimise') {
    Write-Log "  Optimise the Windows VMs: keep SmartConsole $($KeepSmartConsole -join ', '); no restarts"
    $GaiaHosts = @(); $LateGaiaHosts = @()
} else {
    Write-Log "  Windows: language list $($Languages -join ', '); time zone '$WindowsTimezone'"
    Write-Log "  Gaia:    keyboard '$GaiaKeyboard'; time zone '$GaiaRegion / $GaiaZone'" + $(if ($NoReboot) { '  (no restarts)' } else { '' })
}
Set-Status 'running' 'Starting'

try {
    $doReboot = -not $NoReboot
    if ($Mode -eq 'optimise') { $applyBlock = $WindowsOptimise; $applyArgs = @(, [string[]]$KeepSmartConsole) }
    else { $applyBlock = $WindowsApply; $applyArgs = @($WindowsTimezone, [string[]]$Languages, $UserScript, $doReboot, $RebootDelaySeconds) }

    # 1. RDP-HOST itself (local, never restarted)
    Set-Status 'running' 'Applying to RDP-HOST'
    if ($Mode -eq 'optimise') { $local = & $WindowsOptimise $KeepSmartConsole } else { $local = & $WindowsApply $WindowsTimezone $Languages $UserScript $false 0 }
    $script:HostResults['local'] = [pscustomobject]@{ ip = 'local'; kind = 'Windows'; name = $env:COMPUTERNAME; ok = $true; result = 'done (' + ($local -split '\|', 2)[1] + ')' }
    Write-Log ("$env:COMPUTERNAME (this machine): " + $script:HostResults['local'].result)

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
        [void]$ps.AddScript($WindowsWorker).AddArgument($ip).AddArgument([string[]]@($DomainUser, $LocalUser)).AddArgument($Password).AddArgument($applyBlock).AddArgument([object[]]$applyArgs)
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
