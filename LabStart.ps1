<#
.SYNOPSIS
    Camino Lab Start - student start tool for Skillable Check Point labs. Runs on A-GUI.

.DESCRIPTION
    One window with tabs:
      1. Localise          - applies keyboard + time zone to every lab VM: copies LabLocalise.ps1 (the
                             localisation engine in this repo) to RDP-HOST and runs it there as a one-off
                             scheduled task, so the student never has to go to RDP-HOST. The lab's own
                             C:\scripts\changes.cmd / changes.ps1 are not used.
      2. Lab checklist     - tick-off steps (ticks saved per user on this VM).
      3. Credentials & IPs - the lab logins, double-click a cell to copy it; 'Add browser bookmarks' puts the web portals in the browsers (optional).
      4. Check Point Tools - the course documents and main tools from the desktop "Check Point Tools" folder.
      5. Lab notes         - corrections and tips, links to the course pages.
      6. Extras            - optional tools (MobaXterm setup, SmartConsole cleanup, ...).
      7. Gaia commands     - run clish / expert commands on several Gaia hosts at once.

    Text content (checklist, credentials, tool descriptions, notes) comes from content.json in the repo,
    so it can be edited without touching this script.

    Keep this file plain ASCII: Windows PowerShell 5.1 misreads non-ASCII characters in scripts.

.NOTES
    Launch with go.ps1 (irm ... | iex). Needs -STA (WinForms + clipboard); go.ps1 starts it that way.
#>
[CmdletBinding()]
param(
    [switch]$NoContentDownload,
    [string]$Ref = 'main'
)

$ErrorActionPreference = 'Stop'

# When launched from PowerShell 7, this Windows PowerShell 5.1 process inherits PS7 module paths and
# then fails to load core modules (e.g. ConvertTo-SecureString). Keep only the 5.1 paths and reload.
if ($PSVersionTable.PSVersion.Major -lt 6) {
    $env:PSModulePath = (@($env:PSModulePath -split ';') | Where-Object { $_ -and $_ -notmatch '(^|\\)PowerShell\\' }) -join ';'
    $sysModules = Join-Path $PSHOME 'Modules'
    if (($env:PSModulePath -split ';') -notcontains $sysModules) { $env:PSModulePath = "$env:PSModulePath;$sysModules" }
    foreach ($m in 'Microsoft.PowerShell.Security', 'Microsoft.PowerShell.Utility', 'Microsoft.PowerShell.Management') {
        Import-Module $m -ErrorAction SilentlyContinue
    }
}
$Version         = '0.8.1'
$RepoRaw         = 'https://raw.githubusercontent.com/Caminoltd/Lab-Start/' + $(if ($Ref) { $Ref } else { 'main' })
$RdpHostName     = 'RDP-HOST'
$RdpHostFallback = '10.1.1.230'
$LabUser         = 'Admin'
$LabPassword     = 'Chkp!234'      # standard Skillable lab password, shown in every lab guide
$StateDir        = Join-Path $env:LOCALAPPDATA 'LabStart'
New-Item -ItemType Directory -Force -Path $StateDir | Out-Null

try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# ---------------------------------------------------------------------------
# Content (checklist, credentials, tools, notes)
# ---------------------------------------------------------------------------
$FallbackContentJson = @'
{
  "version": 0,
  "checklist": [ { "text": "Set keyboard and timezone (Localise tab)", "detail": "" } ],
  "credentials": [ { "system": "Windows VMs", "address": "", "username": "Admin", "password": "Chkp!234", "notes": "" } ],
  "tools": { },
  "notes": [ "The full content could not be downloaded. Check A-GUI's internet connection and click Refresh content." ]
}
'@

function Get-LabContent {
    $json  = $null
    $cache = Join-Path $StateDir 'content.json'
    if (-not $NoContentDownload) {
        for ($try = 1; $try -le 2 -and -not $json; $try++) {
            try {
                $url  = "$RepoRaw/content.json?" + (Get-Date -Format 'yyyyMMddHHmmss')
                $json = (Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 10).Content
                try { $null = $json | ConvertFrom-Json; Set-Content -Path $cache -Value $json -Encoding UTF8 } catch { $json = $null }
            } catch { $json = $null; if ($try -lt 2) { Start-Sleep -Seconds 3 } }
        }
    }
    $local = $(if ($PSScriptRoot) { Join-Path $PSScriptRoot 'content.json' } else { $null })
    # -NoContentDownload (testing): prefer the content.json next to the script
    if (-not $json -and $NoContentDownload -and $local -and (Test-Path $local)) { $json = Get-Content -Raw -Path $local }
    if (-not $json -and (Test-Path $cache)) { $json = Get-Content -Raw -Path $cache }
    if (-not $json -and $local -and (Test-Path $local)) { $json = Get-Content -Raw -Path $local }
    if (-not $json) { $json = $FallbackContentJson }
    return ($json | ConvertFrom-Json)
}

# Returns the entry for a course from a value that is either a plain list (all courses)
# or an object keyed by course code with an optional "default" entry.
function Get-CourseValue($Obj, [string]$Code) {
    if ($null -eq $Obj) { return @() }
    if ($Obj -is [array]) { return @($Obj) }
    if ($Code) { $p = $Obj.PSObject.Properties[$Code]; if ($p) { return @($p.Value) } }
    $d = $Obj.PSObject.Properties['default']; if ($d) { return @($d.Value) }
    return @()
}

# ---------------------------------------------------------------------------
# RDP-HOST remoting
# ---------------------------------------------------------------------------
function Get-RdpHostTarget {
    try {
        $ip = [Net.Dns]::GetHostAddresses($RdpHostName) | Where-Object { $_.AddressFamily -eq 'InterNetwork' } | Select-Object -First 1
        if ($ip) { return $ip.IPAddressToString }
    } catch {}
    return $RdpHostFallback
}

function New-LabCredential {
    $sec = ConvertTo-SecureString $LabPassword -AsPlainText -Force
    return (New-Object System.Management.Automation.PSCredential ($LabUser, $sec))
}

function Invoke-OnRdpHost {
    param([scriptblock]$ScriptBlock, [object[]]$Arguments = @())
    $target = Get-RdpHostTarget
    Invoke-Command -ComputerName $target -Credential (New-LabCredential) -ScriptBlock $ScriptBlock -ArgumentList $Arguments -ErrorAction Stop
}

# Runs ON RDP-HOST: saves the localisation engine (LabLocalise.ps1) and its settings, then starts it as a
# one-off scheduled task, so the work carries on when A-GUI restarts part-way through.
# Nothing from C:\scripts\changes.cmd / changes.ps1 is used.
$StartLocalise = {
    param([string]$EngineText, [string]$SettingsJson, [string]$Label, [string]$User, [string]$Password)

    $dir = 'C:\scripts\LabStart'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null

    $existing = Get-ScheduledTask -TaskName 'LabStart-Localise' -ErrorAction SilentlyContinue
    if ($existing -and "$($existing.State)" -eq 'Running') { return 'already-running' }

    Set-Content -Path (Join-Path $dir 'LabLocalise.ps1') -Value $EngineText -Encoding UTF8
    Set-Content -Path (Join-Path $dir 'settings.json') -Value $SettingsJson -Encoding UTF8
    [pscustomobject]@{ state = 'starting'; preset = $Label; detail = 'Starting on RDP-HOST'; time = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') } |
        ConvertTo-Json | Set-Content -Path (Join-Path $dir 'status.json') -Encoding UTF8

    $arg      = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -SettingsFile "{1}"' -f (Join-Path $dir 'LabLocalise.ps1'), (Join-Path $dir 'settings.json')
    $action   = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arg -WorkingDirectory $dir
    $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Hours 1) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    Register-ScheduledTask -TaskName 'LabStart-Localise' -Action $action -Settings $settings `
        -User "$env:COMPUTERNAME\$User" -Password $Password -RunLevel Highest -Force | Out-Null
    Start-ScheduledTask -TaskName 'LabStart-Localise'
    return 'started'
}

# The engine: from the repo (same commit as this script), or next to this script when testing (-NoContentDownload)
function Get-LocaliseEngine {
    $local = $(if ($PSScriptRoot) { Join-Path $PSScriptRoot 'LabLocalise.ps1' } else { $null })
    if ($NoContentDownload -and $local -and (Test-Path $local)) { return (Get-Content -Raw -Path $local) }
    $url = "$RepoRaw/LabLocalise.ps1?" + (Get-Date -Format 'yyyyMMddHHmmss')
    return (Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 30).Content
}

# Runs ON RDP-HOST: returns the status file, task state and the end of the log.
$GetLocaliseStatus = {
    $dir = 'C:\scripts\LabStart'
    $s = $null
    if (Test-Path (Join-Path $dir 'status.json')) { $s = Get-Content -Raw -Path (Join-Path $dir 'status.json') | ConvertFrom-Json }
    $t = Get-ScheduledTask -TaskName 'LabStart-Localise' -ErrorAction SilentlyContinue
    $tail = ''
    if (Test-Path (Join-Path $dir 'localise.log')) { $tail = (Get-Content -Path (Join-Path $dir 'localise.log') -Tail 80) -join "`r`n" }
    $taskState = 'none'
    if ($t) { $taskState = "$($t.State)" }
    [pscustomobject]@{
        State     = $(if ($s) { $s.state } else { 'never-run' })
        Preset    = $(if ($s) { $s.preset } else { '' })
        Detail    = $(if ($s) { $s.detail } else { '' })
        Time      = $(if ($s) { $s.time } else { '' })
        TaskState = $taskState
        Log       = $tail
    }
}

function Get-FriendlyRemoteError([System.Management.Automation.ErrorRecord]$Err) {
    $m = $Err.Exception.Message
    if ($m -match 'TrustedHosts') {
        return "A-GUI is not allowed to connect to RDP-HOST yet (TrustedHosts).`r`nAsk your trainer, or in an administrator PowerShell on A-GUI run:`r`n  Set-Item WSMan:\localhost\Client\TrustedHosts -Value '10.1.1.*' -Force"
    }
    if ($m -match 'Access is denied|logon failure|user name or password') {
        return "RDP-HOST refused the login. The lab password may differ from the standard one - check the Credentials tab and your lab guide."
    }
    if ($m -match 'cannot complete the operation|WinRM cannot|network path|connect to the destination') {
        return "RDP-HOST could not be reached. It may still be starting - wait a minute and try again."
    }
    return $m
}

# ---------------------------------------------------------------------------
# Checklist persistence
# ---------------------------------------------------------------------------
$ChecklistFile = Join-Path $StateDir 'checklist.json'
function Get-Ticks {
    if (Test-Path $ChecklistFile) { try { return @(Get-Content -Raw $ChecklistFile | ConvertFrom-Json) } catch {} }
    return @()
}
function Save-Ticks([string[]]$Texts) { ConvertTo-Json -InputObject @($Texts) | Set-Content -Path $ChecklistFile -Encoding UTF8 }

# ---------------------------------------------------------------------------
# UI helpers
# ---------------------------------------------------------------------------
$FontBody  = New-Object System.Drawing.Font('Segoe UI', 10)
$FontBold  = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
$FontTitle = New-Object System.Drawing.Font('Segoe UI', 14, [System.Drawing.FontStyle]::Bold)
$FontMono  = New-Object System.Drawing.Font('Consolas', 9)

function New-Label([string]$Text, [int]$X, [int]$Y, [int]$W, [int]$H, $Font = $FontBody) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $Text; $l.Location = New-Object System.Drawing.Point($X, $Y); $l.Size = New-Object System.Drawing.Size($W, $H); $l.Font = $Font
    return $l
}
function New-Button([string]$Text, [int]$X, [int]$Y, [int]$W = 170, [int]$H = 34) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $Text; $b.Location = New-Object System.Drawing.Point($X, $Y); $b.Size = New-Object System.Drawing.Size($W, $H); $b.Font = $FontBody
    return $b
}
function Set-Busy([bool]$Busy) {
    if ($Busy) { $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor } else { $form.Cursor = [System.Windows.Forms.Cursors]::Default }
    [System.Windows.Forms.Application]::DoEvents()
}

# ---------------------------------------------------------------------------
# Form
# ---------------------------------------------------------------------------
$Content = Get-LabContent

$form = New-Object System.Windows.Forms.Form
$form.Text = "Camino Lab Start $Version - $env:COMPUTERNAME"
$form.Size = New-Object System.Drawing.Size(1000, 700)
$form.MinimumSize = New-Object System.Drawing.Size(900, 600)
$form.StartPosition = 'CenterScreen'
$form.Font = $FontBody

$header = New-Label 'Camino Lab Start' 16 10 400 32 $FontTitle
$form.Controls.Add($header)
$sub = New-Label 'Your lab companion: set up the lab, then find the logins, IP addresses, course documents and lab notes for your course.' 18 42 960 22
$form.Controls.Add($sub)

$CourseFile = Join-Path $StateDir 'course.txt'
$lblCourse = New-Label 'Your course:' 540 12 134 28 $FontBold
$lblCourse.TextAlign = 'MiddleRight'
$lblCourse.Anchor = 'Top, Right'
$form.Controls.Add($lblCourse)
$cbCourse = New-Object System.Windows.Forms.ComboBox
$cbCourse.DropDownStyle = 'DropDownList'
$cbCourse.Location = New-Object System.Drawing.Point(680, 10)
$cbCourse.Size = New-Object System.Drawing.Size(292, 28)
$cbCourse.Anchor = 'Top, Right'
$form.Controls.Add($cbCourse)
$script:FillingCourses = $false

function Get-SelectedCourse {
    if ($cbCourse.SelectedIndex -lt 0) { return $null }
    return [string](@($Content.courses)[$cbCourse.SelectedIndex].code)
}
function Fill-Courses {
    $script:FillingCourses = $true
    $cbCourse.Items.Clear()
    $saved = $null
    if (Test-Path $CourseFile) { $saved = (Get-Content -Raw -Path $CourseFile).Trim() }
    $i = 0
    foreach ($c in @($Content.courses)) {
        [void]$cbCourse.Items.Add("$($c.code) - $($c.name)")
        if ($saved -and $c.code -eq $saved) { $cbCourse.SelectedIndex = $i }
        $i++
    }
    $script:FillingCourses = $false
}
if ($env:COMPUTERNAME -ne 'A-GUI') {
    $warn = New-Label "Note: this is $env:COMPUTERNAME. Lab Start is meant to run on A-GUI." 18 64 900 22 $FontBold
    $warn.ForeColor = [System.Drawing.Color]::DarkOrange
    $form.Controls.Add($warn)
}

$tabs = New-Object System.Windows.Forms.TabControl
$tabs.Location = New-Object System.Drawing.Point(12, 90)
$tabs.Size = New-Object System.Drawing.Size(960, 520)
$tabs.Anchor = 'Top, Bottom, Left, Right'
$form.Controls.Add($tabs)

$footer = New-Label "Lab Start $Version  |  github.com/Caminoltd/Lab-Start" 16 620 600 22
$footer.Anchor = 'Bottom, Left'
$footer.ForeColor = [System.Drawing.Color]::Gray
$form.Controls.Add($footer)
$btnRefresh = New-Button 'Refresh content' 820 614 150 30
$btnRefresh.Anchor = 'Bottom, Right'
$form.Controls.Add($btnRefresh)

# ---- Tab 1: Localise --------------------------------------------------------
$tabLoc = New-Object System.Windows.Forms.TabPage
$tabLoc.Text = '1. Localise'
$tabs.TabPages.Add($tabLoc)

$tabLoc.Controls.Add((New-Label 'Set the keyboard layout and timezone on every lab VM in one step. You do not need to go to RDP-HOST.' 16 16 900 22))
$tabLoc.Controls.Add((New-Label 'Country:' 16 56 80 24 $FontBold))
$cbCountry = New-Object System.Windows.Forms.ComboBox
$cbCountry.DropDownStyle = 'DropDownList'
$cbCountry.Location = New-Object System.Drawing.Point(100, 52)
$cbCountry.Size = New-Object System.Drawing.Size(320, 28)
$cbCountry.MaxDropDownItems = 20
$tabLoc.Controls.Add($cbCountry)
$tabLoc.Controls.Add((New-Label 'Keyboard:' 16 92 80 24 $FontBold))
$cbKeyboard = New-Object System.Windows.Forms.ComboBox
$cbKeyboard.DropDownStyle = 'DropDownList'
$cbKeyboard.Location = New-Object System.Drawing.Point(100, 88)
$cbKeyboard.Size = New-Object System.Drawing.Size(320, 28)
$cbKeyboard.MaxDropDownItems = 20
$tabLoc.Controls.Add($cbKeyboard)
$lblLocSummary = New-Label '' 100 122 840 22
$lblLocSummary.ForeColor = [System.Drawing.Color]::DimGray
$tabLoc.Controls.Add($lblLocSummary)

# Built-in UK values in case content.json has no country list
$LocDefault = @{ keyboards = @([pscustomobject]@{ name = 'English (United Kingdom)'; windows = 'en-GB'; gaia = 'uk' });
                 countries = @([pscustomobject]@{ name = 'United Kingdom'; keyboard = 'en-GB'; windowsTimezone = 'GMT Standard Time'; gaiaRegion = 'Europe'; gaiaZone = 'London' }) }
$CountryFile = Join-Path $StateDir 'country.txt'
function Get-LocKeyboards { if ($Content.localise -and $Content.localise.keyboards) { return @($Content.localise.keyboards) } else { return $LocDefault.keyboards } }
function Get-LocCountries { if ($Content.localise -and $Content.localise.countries) { return @($Content.localise.countries) } else { return $LocDefault.countries } }
function Fill-Localise {
    $cbCountry.Items.Clear(); $cbKeyboard.Items.Clear()
    foreach ($k in (Get-LocKeyboards)) { [void]$cbKeyboard.Items.Add($k.name) }
    $saved = $null
    if (Test-Path $CountryFile) { $saved = (Get-Content -Raw -Path $CountryFile).Trim() }
    $sel = 0; $i = 0
    foreach ($c in (Get-LocCountries)) {
        [void]$cbCountry.Items.Add($c.name)
        if ($saved -and $c.name -eq $saved) { $sel = $i } elseif (-not $saved -and $c.name -eq 'United Kingdom') { $sel = $i }
        $i++
    }
    if ($cbCountry.Items.Count -gt 0) { $cbCountry.SelectedIndex = $sel }
}
function Get-LocChoice {
    $c = @(Get-LocCountries)[$cbCountry.SelectedIndex]
    $k = @(Get-LocKeyboards)[$cbKeyboard.SelectedIndex]
    return [pscustomobject]@{ Country = $c; Keyboard = $k }
}
function Update-LocSummary {
    if ($cbCountry.SelectedIndex -lt 0 -or $cbKeyboard.SelectedIndex -lt 0) { $lblLocSummary.Text = ''; return }
    $ch = Get-LocChoice
    $lblLocSummary.Text = "Windows time zone: $($ch.Country.windowsTimezone)    |    Gaia time zone: $($ch.Country.gaiaRegion) / $($ch.Country.gaiaZone)"
}
$cbCountry.Add_SelectedIndexChanged({
    if ($cbCountry.SelectedIndex -lt 0) { return }
    $c = @(Get-LocCountries)[$cbCountry.SelectedIndex]
    $ks = @(Get-LocKeyboards)
    for ($i = 0; $i -lt $ks.Count; $i++) { if ($ks[$i].windows -eq $c.keyboard) { $cbKeyboard.SelectedIndex = $i; break } }
    Update-LocSummary
})
$cbKeyboard.Add_SelectedIndexChanged({ Update-LocSummary })

$chkRestart = New-Object System.Windows.Forms.CheckBox
$chkRestart.Text = 'Restart the VMs afterwards (not needed)'
$chkRestart.Location = New-Object System.Drawing.Point(440, 90); $chkRestart.Size = New-Object System.Drawing.Size(320, 24); $chkRestart.Font = $FontBody
$chkRestart.Checked = $false
$tabLoc.Controls.Add($chkRestart)

$btnApply  = New-Button 'Apply to all lab VMs' 100 150 200 36
$btnStatus = New-Button 'Check status' 312 150 150 36
$btnOptimise = New-Button 'Optimise lab VMs' 474 150 180 36
$tabLoc.Controls.Add($btnApply)
$tabLoc.Controls.Add($btnStatus)
$tabLoc.Controls.Add($btnOptimise)
$tipLoc = New-Object System.Windows.Forms.ToolTip
$tipLoc.SetToolTip($chkRestart, 'Not needed: time zones change at once, Gaia needs no restart, and Windows uses the new keyboard at the next log-on. Tick only if a VM does not pick up the change.')
$tipLoc.SetToolTip($btnOptimise, 'Removes old SmartConsole versions, switches off Windows Search, SysMain and telemetry, removes OneDrive set-up at log-on, sets High performance power. No restarts.')

$lblLocStatus = New-Label '' 16 198 920 44 $FontBold
$tabLoc.Controls.Add($lblLocStatus)

$txtLocLog = New-Object System.Windows.Forms.TextBox
$txtLocLog.Multiline = $true; $txtLocLog.ReadOnly = $true; $txtLocLog.ScrollBars = 'Vertical'; $txtLocLog.Font = $FontMono
$txtLocLog.Location = New-Object System.Drawing.Point(16, 246)
$txtLocLog.Size = New-Object System.Drawing.Size(920, 232)
$txtLocLog.Anchor = 'Top, Bottom, Left, Right'
$tabLoc.Controls.Add($txtLocLog)

$pollTimer = New-Object System.Windows.Forms.Timer
$pollTimer.Interval = 10000

function Show-LocaliseStatus([bool]$Quiet = $false) {
    Set-Busy $true
    try {
        $s = Invoke-OnRdpHost -ScriptBlock $GetLocaliseStatus
        $txtLocLog.Text = $s.Log
        $txtLocLog.SelectionStart = $txtLocLog.Text.Length; $txtLocLog.ScrollToCaret()
        switch ($s.State) {
            'never-run' { $lblLocStatus.ForeColor = [System.Drawing.Color]::Black;     $lblLocStatus.Text = 'Not applied yet in this lab. Choose your country and click Apply.' }
            'starting'  { $lblLocStatus.ForeColor = [System.Drawing.Color]::DarkBlue;  $lblLocStatus.Text = "Starting... ($($s.Time))" }
            'running'   { $lblLocStatus.ForeColor = [System.Drawing.Color]::DarkBlue;  $lblLocStatus.Text = "In progress: $($s.Detail)  (updated $($s.Time))" }
            'done'      {
                $lblLocStatus.ForeColor = [System.Drawing.Color]::DarkGreen
                $pre = @(([string]$s.Preset) -split '\|')[-1]
                if ($pre -like 'Optimise*') { $lblLocStatus.Text = "Done: lab VMs optimised. $($s.Detail). No restarts needed." }
                elseif ($pre -like '*(no restart)*') { $lblLocStatus.Text = "Done: $($pre -replace '\s*\(no restart\)', '') settings applied without restarts. $($s.Detail). On RDP-HOST, log off and on again for the new keyboard." }
                else { $lblLocStatus.Text = "Done: $pre settings applied. $($s.Detail). Wait until all VMs have restarted (3 to 5 minutes)." }
            }
            'failed'    { $lblLocStatus.ForeColor = [System.Drawing.Color]::DarkRed;   $lblLocStatus.Text = "Failed: $($s.Detail)  - see the log below and tell your trainer." }
            default     { $lblLocStatus.ForeColor = [System.Drawing.Color]::Black;     $lblLocStatus.Text = "State: $($s.State)" }
        }
        if ($s.State -in 'done', 'failed', 'never-run') { $pollTimer.Stop() }
    }
    catch {
        if (-not $Quiet) { $lblLocStatus.ForeColor = [System.Drawing.Color]::DarkRed; $lblLocStatus.Text = (Get-FriendlyRemoteError $_) }
        else { $lblLocStatus.ForeColor = [System.Drawing.Color]::Gray; $lblLocStatus.Text = 'Status not available yet (RDP-HOST did not answer). Click Check status to try again.' }
        $txtLocLog.Text = "Could not reach RDP-HOST ($(Get-RdpHostTarget)):`r`n`r`n" + (Get-FriendlyRemoteError $_) + "`r`n`r`nDetail: " + $_.Exception.Message
    }
    finally { Set-Busy $false }
}

$pollTimer.Add_Tick({ Show-LocaliseStatus -Quiet $true })
$btnStatus.Add_Click({ Show-LocaliseStatus })

$btnApply.Add_Click({
    if ($cbCountry.SelectedIndex -lt 0 -or $cbKeyboard.SelectedIndex -lt 0) { return }
    $ch = Get-LocChoice
    $noRestart = -not $chkRestart.Checked
    $msg = "This sets the keyboard to $($ch.Keyboard.name) and the time zone to $($ch.Country.name) ($($ch.Country.gaiaRegion)/$($ch.Country.gaiaZone)) on all the lab VMs.`r`n`r`n"
    if ($noRestart) { $msg += "No VM restarts. The time zones change at once; on RDP-HOST the new keyboard applies at your next log-on.`r`n`r`nContinue?" }
    else { $msg += "About a minute after it starts, the Windows VMs restart - including this one (A-GUI). Save anything you have open first.`r`n`r`n" +
           "Lab Start opens again by itself when you log back in to A-GUI, and shows the result.`r`n`r`nContinue?" }
    $ans = [System.Windows.Forms.MessageBox]::Show($msg, 'Apply keyboard and timezone', 'YesNo', 'Warning')
    if ($ans -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    Set-Busy $true
    try {
        $label = "$($ch.Country.name), $($ch.Keyboard.name) keyboard" + $(if ($noRestart) { ' (no restart)' } else { '' })
        $cfg = [ordered]@{
            noReboot = [bool]$noRestart
            windowsLanguage = [string]$ch.Keyboard.windows; windowsTimezone = [string]$ch.Country.windowsTimezone
            gaiaKeyboard = [string]$ch.Keyboard.gaia; gaiaRegion = [string]$ch.Country.gaiaRegion; gaiaZone = [string]$ch.Country.gaiaZone
            label = $label
        }
        # Optional per-course host lists in content.json: "localiseHosts": { "default": { "windows": [...], "gaia": [...] }, "CCSE": {...} }
        if ($Content.localiseHosts) {
            $code = Get-SelectedCourse
            $lh = $null
            if ($code) { $pp = $Content.localiseHosts.PSObject.Properties[$code]; if ($pp) { $lh = $pp.Value } }
            if (-not $lh) { $pp = $Content.localiseHosts.PSObject.Properties['default']; if ($pp) { $lh = $pp.Value } }
            if ($lh -and $lh.windows) { $cfg.windowsHosts = @($lh.windows) }
            if ($lh -and $lh.gaia) { $cfg.gaiaHosts = @($lh.gaia) }
        }
        $settingsJson = ConvertTo-Json -InputObject ([pscustomobject]$cfg) -Depth 4
        $engine = Get-LocaliseEngine
        if (-not $engine -or $engine -notmatch 'Camino lab localisation engine') { throw 'Could not download the localisation engine (LabLocalise.ps1). Check the internet connection and try again.' }
        try { Set-Content -Path $CountryFile -Value $ch.Country.name -Encoding ASCII } catch {}
        $r = Invoke-OnRdpHost -ScriptBlock $StartLocalise -Arguments @($engine, $settingsJson, $label, $LabUser, $LabPassword)
        if ("$r" -eq 'already-running') {
            $lblLocStatus.ForeColor = [System.Drawing.Color]::DarkBlue
            $lblLocStatus.Text = 'Already running on RDP-HOST - showing progress.'
        } else {
            $lblLocStatus.ForeColor = [System.Drawing.Color]::DarkBlue
            $lblLocStatus.Text = $(if ($noRestart) { 'Started on RDP-HOST - showing progress here.' } else { 'Started on RDP-HOST. A-GUI restarts shortly - Lab Start opens again by itself after you log back in.' })
        }
        # No restart: give this A-GUI session the new keyboard now (the engine changes the logon script for later sessions)
        if ($noRestart) {
            try { Set-WinUserLanguageList -LanguageList @(@([string]$ch.Keyboard.windows, 'en-US') | Select-Object -Unique) -Force -WarningAction SilentlyContinue } catch {}
        }
        # Reopen Lab Start once at the next logon (A-GUI restarts part-way through the run).
        if (-not $noRestart) { try {
            $self = if ($PSCommandPath) { $PSCommandPath } else { Join-Path $StateDir 'LabStart.ps1' }
            $cmd  = "`"$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe`" -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$self`" -Ref $Ref"
            if ($NoContentDownload) { $cmd += ' -NoContentDownload' }
            New-Item -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce' -Force | Out-Null
            New-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce' -Name 'LabStart' -Value $cmd -PropertyType String -Force | Out-Null
        } catch {} }
        $pollTimer.Start()
    }
    catch {
        $lblLocStatus.ForeColor = [System.Drawing.Color]::DarkRed
        $lblLocStatus.Text = (Get-FriendlyRemoteError $_)
    }
    finally { Set-Busy $false }
})

$btnOptimise.Add_Click({
    $code = Get-SelectedCourse
    $opt = @(Get-CourseValue $Content.optimise $code) | Select-Object -First 1
    $keep = @('R82'); if ($opt -and $opt.keepSmartConsole) { $keep = @($opt.keepSmartConsole | ForEach-Object { [string]$_ }) }
    $msg = "This tidies up the Windows lab VMs (no restarts):`r`n`r`n" +
           "- removes SmartConsole versions other than $($keep -join ', ')`r`n" +
           "- switches off Windows Search, SysMain and telemetry`r`n" +
           "- removes OneDrive set-up at log-on, and VMware Tools on the servers`r`n" +
           "- sets the High performance power plan and clears the update download cache`r`n`r`n" +
           "Close any old SmartConsole that is open. It takes a few minutes.`r`n`r`nContinue?"
    if ([System.Windows.Forms.MessageBox]::Show($msg, 'Optimise lab VMs', 'YesNo', 'Question') -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    Set-Busy $true
    try {
        $cfg = [ordered]@{ mode = 'optimise'; label = 'Optimise lab VMs'; keepSmartConsole = $keep }
        if ($Content.localiseHosts) {
            $lh = @(Get-CourseValue $Content.localiseHosts $code) | Select-Object -First 1
            if ($lh -and $lh.windows) { $cfg.windowsHosts = @($lh.windows) }
        }
        $settingsJson = ConvertTo-Json -InputObject ([pscustomobject]$cfg) -Depth 4
        $engine = Get-LocaliseEngine
        if (-not $engine -or $engine -notmatch 'Camino lab localisation engine') { throw 'Could not download the engine (LabLocalise.ps1). Check the internet connection and try again.' }
        if ($engine -notmatch 'WindowsOptimise') { throw 'The engine on GitHub is too old for Optimise. Click Refresh content or restart Lab Start.' }
        $r = Invoke-OnRdpHost -ScriptBlock $StartLocalise -Arguments @($engine, $settingsJson, 'Optimise lab VMs', $LabUser, $LabPassword)
        $lblLocStatus.ForeColor = [System.Drawing.Color]::DarkBlue
        $lblLocStatus.Text = $(if ("$r" -eq 'already-running') { 'A run is already in progress on RDP-HOST - showing progress.' } else { 'Optimising on RDP-HOST - showing progress here.' })
        $pollTimer.Start()
    }
    catch { $lblLocStatus.ForeColor = [System.Drawing.Color]::DarkRed; $lblLocStatus.Text = (Get-FriendlyRemoteError $_) }
    finally { Set-Busy $false }
})

# ---- Tab 2: Checklist -------------------------------------------------------
$tabChk = New-Object System.Windows.Forms.TabPage
$tabChk.Text = '2. Lab checklist'
$tabs.TabPages.Add($tabChk)
$tabChk.Controls.Add((New-Label 'Tick each step as you go. Your ticks are saved on this VM.' 16 16 900 22))

$clb = New-Object System.Windows.Forms.CheckedListBox
$clb.CheckOnClick = $true
$clb.Location = New-Object System.Drawing.Point(16, 46)
$clb.Size = New-Object System.Drawing.Size(560, 420)
$clb.Anchor = 'Top, Bottom, Left'
$clb.Font = New-Object System.Drawing.Font('Segoe UI', 11)
$tabChk.Controls.Add($clb)

$lblChkDetail = New-Label '' 596 46 340 420
$lblChkDetail.Anchor = 'Top, Bottom, Left, Right'
$tabChk.Controls.Add($lblChkDetail)

function Fill-Checklist {
    $clb.Items.Clear()
    $ticks = Get-Ticks
    foreach ($item in @($Content.checklist)) {
        $i = $clb.Items.Add($item.text)
        if ($ticks -contains $item.text) { $clb.SetItemChecked($i, $true) }
    }
}
$clb.Add_SelectedIndexChanged({
    $idx = $clb.SelectedIndex
    if ($idx -ge 0) { $lblChkDetail.Text = @($Content.checklist)[$idx].detail }
})
$clb.Add_ItemCheck({
    param($sender, $e)
    $texts = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $clb.Items.Count; $i++) {
        $checked = $clb.GetItemChecked($i)
        if ($i -eq $e.Index) { $checked = ($e.NewValue -eq [System.Windows.Forms.CheckState]::Checked) }
        if ($checked) { $texts.Add([string]$clb.Items[$i]) }
    }
    Save-Ticks $texts.ToArray()
})

# ---- Tab 3: Credentials -----------------------------------------------------
$tabCred = New-Object System.Windows.Forms.TabPage
$tabCred.Text = '3. Credentials & IPs'
$tabCred.Padding = New-Object System.Windows.Forms.Padding(12)
$tabs.TabPages.Add($tabCred)

$lblCredTop = New-Label 'Logins and IP addresses for your course. Double-click any cell to copy it. They are also on the 3rd page of every lab in your lab guide.' 0 0 10 44
$lblCredTop.Dock = 'Top'
$pnlCred = New-Object System.Windows.Forms.Panel
$pnlCred.Dock = 'Bottom'; $pnlCred.Height = 72
$btnCredPdf = New-Button 'Open the full list (PDF)' 0 8 200 32
$btnCredOpen = New-Button 'Open web address' 208 8 160 32
$btnBmAdd = New-Button 'Add browser bookmarks' 376 8 190 32
$btnBmRemove = New-Button 'Remove bookmarks' 574 8 160 32
$lblCopied = New-Label '' 0 46 940 22
$pnlCred.Controls.Add($btnCredPdf); $pnlCred.Controls.Add($btnCredOpen); $pnlCred.Controls.Add($btnBmAdd); $pnlCred.Controls.Add($btnBmRemove); $pnlCred.Controls.Add($lblCopied)

$grid = New-Object System.Windows.Forms.DataGridView
$grid.Dock = 'Fill'
$grid.ReadOnly = $true; $grid.AllowUserToAddRows = $false; $grid.AllowUserToDeleteRows = $false; $grid.AllowUserToResizeRows = $false
$grid.RowHeadersVisible = $false; $grid.SelectionMode = 'CellSelect'; $grid.AutoSizeColumnsMode = 'Fill'
$grid.BackgroundColor = [System.Drawing.SystemColors]::Window
foreach ($c in @(@('System', 34), @('Address', 26), @('Username', 22), @('Password', 18))) {
    $i = $grid.Columns.Add($c[0], $c[0]); $grid.Columns[$i].FillWeight = $c[1]
}
# Dock order: Top and Bottom first, Fill last
$tabCred.Controls.Add($grid); $tabCred.Controls.Add($pnlCred); $tabCred.Controls.Add($lblCredTop)
$grid.BringToFront()

# Web portals (https addresses for the course) as browser bookmarks - optional, only when the student clicks
# 'Add browser bookmarks' on tab 3 ('Remove bookmarks' takes them out again). Written as machine browser policies:
# Chrome and Edge show a managed folder on the bookmarks bar, Firefox a folder on the toolbar.
function Get-PortalLinks {
    $code = Get-SelectedCourse
    $links = @(); $seen = @{}
    foreach ($r in (Get-CourseValue $Content.credentials $code)) {
        $a = [string]$r.address
        if ($a -match '^https?://' -and -not $seen[$a]) {
            $seen[$a] = $true
            $n = ([string]$r.system) -replace '\s*\(Gaia Portal\)\s*', ''
            $links += [pscustomobject]@{ Name = "Gaia - $n"; Url = $a }
        }
    }
    foreach ($b in (Get-CourseValue $Content.bookmarks $code)) {
        if ($b.url -and -not $seen[[string]$b.url]) { $seen[[string]$b.url] = $true; $links += [pscustomobject]@{ Name = [string]$b.name; Url = [string]$b.url } }
    }
    return $links
}
# Browser policy keys are read-only for normal processes, so the bookmarks are written as machine policies
# through a WinRM session to A-GUI itself as the lab Admin (always elevated, no UAC prompt).
$SetBookmarkPolicies = {
    param([string]$Json, [object[]]$Links, [string]$Folder)
    function Set-RegValue([string]$Path, [string]$Name, $Value, [string]$Type) {
        if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
        New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
    }
    Set-RegValue 'HKLM:\SOFTWARE\Policies\Google\Chrome' 'ManagedBookmarks' $Json 'String'
    Set-RegValue 'HKLM:\SOFTWARE\Policies\Google\Chrome' 'BookmarkBarEnabled' 1 'DWord'
    Set-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' 'ManagedFavorites' $Json 'String'
    Set-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' 'FavoritesBarEnabled' 1 'DWord'
    $ff = 'HKLM:\SOFTWARE\Policies\Mozilla\Firefox'
    if (Test-Path "$ff\Bookmarks") { Remove-Item "$ff\Bookmarks" -Recurse -Force }
    $i = 1
    foreach ($l in $Links) {
        $k = "$ff\Bookmarks\$i"
        Set-RegValue $k 'Title' ([string]$l.Name) 'String'
        Set-RegValue $k 'URL' ([string]$l.Url) 'String'
        Set-RegValue $k 'Folder' $Folder 'String'
        Set-RegValue $k 'Placement' 'toolbar' 'String'
        $i++
    }
    Set-RegValue $ff 'DisplayBookmarksToolbar' 'always' 'String'
}
function Set-BrowserBookmarks {
    $code = Get-SelectedCourse
    if (-not $code) { return 0 }
    $links = @(Get-PortalLinks)
    if ($links.Count -eq 0) { return 0 }
    $folder = "Lab - $code"
    $items = @([pscustomobject]@{ toplevel_name = $folder })
    foreach ($l in $links) { $items += [pscustomobject]@{ name = $l.Name; url = $l.Url } }
    $json = ConvertTo-Json -InputObject $items -Compress -Depth 4
    $plain = @($links | ForEach-Object { @{ Name = $_.Name; Url = $_.Url } })
    Invoke-AsLabAdmin $SetBookmarkPolicies @($json, $plain, $folder)
    return $links.Count
}
$RemoveBookmarkPolicies = {
    foreach ($v in @(@('HKLM:\SOFTWARE\Policies\Google\Chrome', 'ManagedBookmarks'), @('HKLM:\SOFTWARE\Policies\Google\Chrome', 'BookmarkBarEnabled'),
                     @('HKLM:\SOFTWARE\Policies\Microsoft\Edge', 'ManagedFavorites'), @('HKLM:\SOFTWARE\Policies\Microsoft\Edge', 'FavoritesBarEnabled'),
                     @('HKLM:\SOFTWARE\Policies\Mozilla\Firefox', 'DisplayBookmarksToolbar'))) {
        Remove-ItemProperty -Path $v[0] -Name $v[1] -ErrorAction SilentlyContinue
    }
    if (Test-Path 'HKLM:\SOFTWARE\Policies\Mozilla\Firefox\Bookmarks') { Remove-Item 'HKLM:\SOFTWARE\Policies\Mozilla\Firefox\Bookmarks' -Recurse -Force }
    # tidy up policy keys left empty, so the browsers stop saying they are managed
    foreach ($k in 'HKLM:\SOFTWARE\Policies\Google\Chrome', 'HKLM:\SOFTWARE\Policies\Microsoft\Edge', 'HKLM:\SOFTWARE\Policies\Mozilla\Firefox') {
        $i = Get-Item $k -ErrorAction SilentlyContinue
        if ($i -and $i.ValueCount -eq 0 -and $i.SubKeyCount -eq 0) { Remove-Item $k -Force }
    }
}
# Policy keys need an elevated session on A-GUI. A-GUI refuses WinRM sessions to itself in some labs (CCSA, Nov 2026),
# so the session goes out to RDP-HOST and back in to A-GUI as its local Admin (elevated remotely: LocalAccountTokenFilterPolicy=1).
# Fallback: a WinRM session from A-GUI to itself as the lab domain admin (works in the CCSE lab).
$RunOnAGui = {
    param([string]$ScriptText, [object[]]$Arguments, [string]$Target, [string]$User, [string]$Password)
    $cred = New-Object System.Management.Automation.PSCredential ($User, (ConvertTo-SecureString $Password -AsPlainText -Force))
    Invoke-Command -ComputerName $Target -Credential $cred -ScriptBlock ([scriptblock]::Create($ScriptText)) -ArgumentList $Arguments -ErrorAction Stop
}
function Get-AGuiAddress {
    $ip = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -like '10.1.1.*' } | Select-Object -First 1
    if ($ip) { return $ip.IPAddress } else { return '10.1.1.201' }
}
function Invoke-AsLabAdmin([scriptblock]$Script, [object[]]$Arguments = @()) {
    $errs = @()
    try {
        Invoke-OnRdpHost -ScriptBlock $RunOnAGui -Arguments @($Script.ToString(), $Arguments, (Get-AGuiAddress), "$env:COMPUTERNAME\$LabUser", $LabPassword)
        return
    } catch { $errs += "via RDP-HOST: $($_.Exception.Message)" }
    $sec = ConvertTo-SecureString $LabPassword -AsPlainText -Force
    foreach ($u in 'ALPHA\Administrator', $LabUser) {
        try {
            $cred = New-Object System.Management.Automation.PSCredential ($u, $sec)
            Invoke-Command -ComputerName 'localhost' -Credential $cred -ScriptBlock $Script -ArgumentList $Arguments -ErrorAction Stop
            return
        } catch { $errs += "as ${u}: $($_.Exception.Message)" }
    }
    throw ($errs -join ' | ')
}
function Test-BookmarksAdded {
    try { return [bool](Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Google\Chrome' -Name ManagedBookmarks -ErrorAction Stop) } catch { return $false }
}
function Update-Bookmarks {
    try {
        $n = Set-BrowserBookmarks
        if ($n -gt 0) { $lblCopied.Text = "$n web portals are in the browser bookmarks (folder 'Lab - $(Get-SelectedCourse)'). Restart an open browser to see them." }
        else { $lblCopied.Text = 'This course has no web portals to add as bookmarks.' }
    } catch { $lblCopied.Text = "Could not add the browser bookmarks: $($_.Exception.Message)" }
}
$btnBmAdd.Add_Click({ Set-Busy $true; Update-Bookmarks; Set-Busy $false })
$btnBmRemove.Add_Click({
    Set-Busy $true
    try { Invoke-AsLabAdmin $RemoveBookmarkPolicies; $lblCopied.Text = 'Browser bookmarks removed. Restart an open browser to see the change.' }
    catch { $lblCopied.Text = "Could not remove the browser bookmarks: $($_.Exception.Message)" }
    Set-Busy $false
})
$btnCredOpen.Add_Click({
    $url = $null
    if ($grid.CurrentCell) { $url = [string]$grid.Rows[$grid.CurrentCell.RowIndex].Cells[1].Value }
    if ($url -match '^https?://') { try { Start-Process $url } catch {} }
    else { $lblCopied.Text = 'Click a row with an https:// address first (the Gaia Portal rows).' }
})

function Fill-Credentials {
    $grid.Rows.Clear()
    foreach ($r in (Get-CourseValue $Content.credentials (Get-SelectedCourse))) { [void]$grid.Rows.Add($r.system, $r.address, $r.username, $r.password) }
    $lblCopied.Text = ''
}
$grid.Add_CellDoubleClick({
    param($sender, $e)
    if ($e.RowIndex -lt 0 -or $e.ColumnIndex -lt 0) { return }
    $v = [string]$grid.Rows[$e.RowIndex].Cells[$e.ColumnIndex].Value
    if ($v) { [System.Windows.Forms.Clipboard]::SetText($v); $lblCopied.Text = "Copied: $v" }
})

# ---- Course folder helpers ----------------------------------------------------
function Get-ToolsFolder {
    $candidates = @(
        (Join-Path ([Environment]::GetFolderPath('Desktop')) 'Check Point Tools'),
        (Join-Path $env:PUBLIC 'Desktop\Check Point Tools')
    )
    foreach ($p in $candidates) { if (Test-Path $p) { return $p } }
    return $null
}
function Get-CourseFolder([string]$Code) {
    $tf = Get-ToolsFolder
    if (-not $tf -or -not $Code) { return $null }
    return (Get-ChildItem -Path $tf -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "$Code-*" } | Select-Object -First 1)
}
$btnCredPdf.Add_Click({
    $code = Get-SelectedCourse
    if (-not $code) { [void][System.Windows.Forms.MessageBox]::Show('Choose your course at the top right first.', 'Lab Start'); return }
    $cf = Get-CourseFolder $code
    $pdf = $null
    if ($cf) { $pdf = Get-ChildItem -Path $cf.FullName -Recurse -File -Filter '*Credentials*.pdf' -ErrorAction SilentlyContinue | Select-Object -First 1 }
    if ($pdf) { Start-Process -FilePath $pdf.FullName }
    else { [void][System.Windows.Forms.MessageBox]::Show("No credentials PDF found for $code in the Check Point Tools folder. Use the 3rd page of any lab in your lab guide.", 'Lab Start') }
})

# ---- Tab 4: Course documents and tools -------------------------------------
$tabTools = New-Object System.Windows.Forms.TabPage
$tabTools.Text = '4. Check Point Tools'
$tabTools.Padding = New-Object System.Windows.Forms.Padding(12)
$tabs.TabPages.Add($tabTools)

$lblToolsTop = New-Label 'Your course documents and the main tools from the "Check Point Tools" folder on the desktop. Double-click to open.' 0 0 10 32
$lblToolsTop.Dock = 'Top'
$pnlTools = New-Object System.Windows.Forms.Panel
$pnlTools.Dock = 'Bottom'; $pnlTools.Height = 36
$chkAllTools = New-Object System.Windows.Forms.CheckBox
$chkAllTools.Text = 'Show everything in the folder'; $chkAllTools.AutoSize = $true
$chkAllTools.Location = New-Object System.Drawing.Point(0, 10)
$pnlTools.Controls.Add($chkAllTools)

$lvTools = New-Object System.Windows.Forms.ListView
$lvTools.Dock = 'Fill'
$lvTools.View = 'Details'; $lvTools.FullRowSelect = $true; $lvTools.ShowGroups = $true
[void]$lvTools.Columns.Add('Item', 340)
[void]$lvTools.Columns.Add('What it is for', 560)
$tabTools.Controls.Add($lvTools); $tabTools.Controls.Add($pnlTools); $tabTools.Controls.Add($lblToolsTop)
$lvTools.BringToFront()

function Get-PatternList($Obj) {
    # Accepts a list of { "match": ..., "desc": ... } or an object of pattern -> description.
    $out = @()
    if ($null -eq $Obj) { return $out }
    if ($Obj -is [array]) { foreach ($e in $Obj) { $out += ,@([string]$e.match, [string]$e.desc) } }
    else { foreach ($p in $Obj.PSObject.Properties) { $out += ,@([string]$p.Name, [string]$p.Value) } }
    return ,$out
}
function Add-ToolItem($Group, [string]$Name, [string]$Desc, [string]$Path) {
    $it = New-Object System.Windows.Forms.ListViewItem($Name)
    [void]$it.SubItems.Add($Desc)
    $it.Tag = $Path; $it.Group = $Group
    [void]$lvTools.Items.Add($it)
}
function Fill-Tools {
    $lvTools.Items.Clear(); $lvTools.Groups.Clear()
    $folder = Get-ToolsFolder
    if (-not $folder) {
        $g = $lvTools.Groups.Add('none', 'Check Point Tools')
        Add-ToolItem $g '(folder not found)' 'No "Check Point Tools" folder on this desktop.' $null
        return
    }
    $code  = Get-SelectedCourse
    $shown = @{}

    # 1. The selected course's own folder: list its documents
    $gCourse = $lvTools.Groups.Add('course', $(if ($code) { "Your course documents ($code)" } else { 'Your course documents - choose your course at the top right' }))
    $cf = Get-CourseFolder $code
    if ($cf) {
        $shown[$cf.FullName] = $true
        $docPatterns = Get-PatternList $Content.courseDocs
        foreach ($f in (Get-ChildItem -Path $cf.FullName -Recurse -File -ErrorAction SilentlyContinue | Sort-Object Name | Select-Object -First 40)) {
            $desc = 'Course document'
            foreach ($pp in $docPatterns) { if ($f.Name -like $pp[0]) { $desc = $pp[1]; break } }
            Add-ToolItem $gCourse ([IO.Path]::GetFileNameWithoutExtension($f.Name)) $desc $f.FullName
        }
    } elseif ($code) {
        Add-ToolItem $gCourse "(no $code folder found)" 'Your course documents are not in this lab image.' $null
    }

    # 2. The main tools, in the order given in content.json
    $gTools = $lvTools.Groups.Add('tools', 'Tools')
    $items = @(Get-ChildItem -Path $folder -ErrorAction SilentlyContinue)
    foreach ($pp in (Get-PatternList $Content.tools)) {
        foreach ($f in ($items | Where-Object { $_.Name -like $pp[0] })) {
            if ($shown[$f.FullName]) { continue }
            $shown[$f.FullName] = $true
            Add-ToolItem $gTools ([IO.Path]::GetFileNameWithoutExtension($f.Name)) $pp[1] $f.FullName
        }
    }

    # 3. Everything else, only when asked for
    if ($chkAllTools.Checked) {
        $gAll = $lvTools.Groups.Add('all', 'Everything else in the folder')
        foreach ($f in ($items | Sort-Object Name)) {
            if ($shown[$f.FullName]) { continue }
            Add-ToolItem $gAll ([IO.Path]::GetFileNameWithoutExtension($f.Name)) '' $f.FullName
        }
    }
}
$chkAllTools.Add_CheckedChanged({ Fill-Tools })
$lvTools.Add_DoubleClick({
    if ($lvTools.SelectedItems.Count -gt 0 -and $lvTools.SelectedItems[0].Tag) {
        try { Start-Process -FilePath $lvTools.SelectedItems[0].Tag } catch { [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Could not open') | Out-Null }
    }
})

# ---- Tab 5: Lab notes -------------------------------------------------------
$tabNotes = New-Object System.Windows.Forms.TabPage
$tabNotes.Text = '5. Lab notes'
$tabNotes.Padding = New-Object System.Windows.Forms.Padding(12)
$tabs.TabPages.Add($tabNotes)

$pnlNotes = New-Object System.Windows.Forms.Panel
$pnlNotes.Dock = 'Top'; $pnlNotes.Height = 48
$btnCoursePage = New-Button 'Open the course page: lab notes and topology' 0 4 360 34
$btnPrepPage   = New-Button 'Open the lab preparation checklist' 372 4 290 34
$pnlNotes.Controls.Add($btnCoursePage); $pnlNotes.Controls.Add($btnPrepPage)

$txtNotes = New-Object System.Windows.Forms.TextBox
$txtNotes.Dock = 'Fill'
$txtNotes.Multiline = $true; $txtNotes.ReadOnly = $true; $txtNotes.ScrollBars = 'Vertical'
$txtNotes.Font = New-Object System.Drawing.Font('Segoe UI', 11)
$tabNotes.Controls.Add($txtNotes); $tabNotes.Controls.Add($pnlNotes)
$txtNotes.BringToFront()

function Get-SiteUrl { if ($Content.site) { return ([string]$Content.site).TrimEnd('/') } else { return 'https://caminoltd.github.io' } }
function Fill-Notes {
    $code = Get-SelectedCourse
    $btnCoursePage.Text = $(if ($code) { "Open the $code course page: lab notes and topology" } else { 'Open the course pages: lab notes and topology' })
    $lines = @(Get-CourseValue $Content.notes $code)
    $txtNotes.Text = ($lines | ForEach-Object { '- ' + $_ }) -join "`r`n`r`n"
}
$btnCoursePage.Add_Click({
    $code = Get-SelectedCourse
    $url = (Get-SiteUrl) + '/' + $(if ($code) { $code.ToLower() + '/' } else { '' })
    try { Start-Process $url } catch {}
})
$btnPrepPage.Add_Click({ try { Start-Process ((Get-SiteUrl) + '/lab-preparation/') } catch {} })

# ---- Tab 6: Extras ------------------------------------------------------------
$tabExtras = New-Object System.Windows.Forms.TabPage
$tabExtras.Text = '6. Extras'
$tabExtras.Padding = New-Object System.Windows.Forms.Padding(12)
$tabs.TabPages.Add($tabExtras)

$lblExtrasTop = New-Label 'Optional tools that install or tidy things on A-GUI. Each one opens in its own PowerShell window. Select a tool and click Run (or double-click it).' 0 0 10 44
$lblExtrasTop.Dock = 'Top'
$pnlExtras = New-Object System.Windows.Forms.Panel
$pnlExtras.Dock = 'Bottom'; $pnlExtras.Height = 44
$btnExtraRun = New-Button 'Run selected tool' 0 8 180 32
$lblExtraMsg = New-Label '' 194 14 700 22
$pnlExtras.Controls.Add($btnExtraRun); $pnlExtras.Controls.Add($lblExtraMsg)

$lvExtras = New-Object System.Windows.Forms.ListView
$lvExtras.Dock = 'Fill'
$lvExtras.View = 'Details'; $lvExtras.FullRowSelect = $true; $lvExtras.MultiSelect = $false
[void]$lvExtras.Columns.Add('Tool', 260)
[void]$lvExtras.Columns.Add('What it does', 640)
$tabExtras.Controls.Add($lvExtras); $tabExtras.Controls.Add($pnlExtras); $tabExtras.Controls.Add($lblExtrasTop)
$lvExtras.BringToFront()

function Fill-Extras {
    $lvExtras.Items.Clear()
    foreach ($x in (Get-CourseValue $Content.extras (Get-SelectedCourse))) {
        $it = New-Object System.Windows.Forms.ListViewItem([string]$x.name)
        [void]$it.SubItems.Add([string]$x.desc)
        $it.Tag = $x
        [void]$lvExtras.Items.Add($it)
    }
    if ($lvExtras.Items.Count -eq 0) {
        $it = New-Object System.Windows.Forms.ListViewItem('(none)')
        [void]$it.SubItems.Add('No extra tools are listed for this course.')
        [void]$lvExtras.Items.Add($it)
    }
}
function Invoke-Extra {
    if ($lvExtras.SelectedItems.Count -eq 0 -or -not $lvExtras.SelectedItems[0].Tag) { $lblExtraMsg.Text = 'Select a tool first.'; return }
    $x = $lvExtras.SelectedItems[0].Tag
    $q = "Run '$($x.name)'?`r`n`r`n$($x.desc)"
    if ($x.note) { $q += "`r`n`r`n$($x.note)" }
    if ([System.Windows.Forms.MessageBox]::Show($q, 'Lab Start - Extras', 'YesNo', 'Question') -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    $title = ([string]$x.name) -replace "'", ''
    $cmd = "`$Host.UI.RawUI.WindowTitle = 'Lab Start extra: $title'; try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}; " + [string]$x.command
    try {
        $exe = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
        if ($x.shell -eq 'pwsh') { $pw7 = Get-Command pwsh.exe -ErrorAction SilentlyContinue; if ($pw7) { $exe = $pw7.Source } }
        $sp = @{ FilePath = $exe; ArgumentList = @('-NoProfile', '-NoExit', '-ExecutionPolicy', 'Bypass', '-Command', $cmd) }
        if ($x.elevated) { $sp.Verb = 'RunAs' }   # one admin (UAC) prompt, unless Lab Start itself is already elevated
        Start-Process @sp | Out-Null
        $lblExtraMsg.Text = "Started: $($x.name) (see its PowerShell window)"
    } catch { $lblExtraMsg.Text = "Could not start: $($_.Exception.Message)" }
}
$btnExtraRun.Add_Click({ Invoke-Extra })
$lvExtras.Add_DoubleClick({ Invoke-Extra })

# ---- Tab 7: Gaia commands -------------------------------------------------------
$PlinkExe = 'C:\Program Files\PuTTY\plink.exe'

# Runs in a background runspace, one per host. Never blocks the window.
$GaiaHostWorker = {
    param([string]$Ip, [string]$Name, [string]$User, [string]$Pw, [string]$Plink, [object[]]$Cmds, $Sync)

    function Log([string]$t) { $Sync.Log.Enqueue("[$Name $Ip] $t") }
    function Set-HostState([string]$s, [string]$r) { $Sync.State[$Ip] = $s; if ($null -ne $r) { $Sync.Result[$Ip] = $r } }
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
        $out = ''
        try { $out = ($o.Result + "`n" + $e.Result).Trim() } catch {}
        return [pscustomobject]@{ Out = $out; TimedOut = (-not $done); Code = $(if ($done) { $p.ExitCode } else { -1 }) }
    }
    function Write-Out([string]$text) {
        if (-not $text) { return }
        $lines = @($text -split "`r?`n" | Where-Object { $_.Trim() -and $_ -notmatch 'Keyboard-interactive|Using username|Pre-authentication banner|End of banner' })
        foreach ($l in ($lines | Select-Object -First 80)) { Log ('    ' + $l.TrimEnd()) }
        if ($lines.Count -gt 80) { Log "    ... ($($lines.Count - 80) more lines)" }
    }

    try {
        Set-HostState 'Checking' ''
        # 1. Is SSH answering? (switched-off hosts are skipped quickly)
        $up = $false
        try {
            $tcp = New-Object System.Net.Sockets.TcpClient
            $ar = $tcp.BeginConnect($Ip, 22, $null, $null)
            $up = $ar.AsyncWaitHandle.WaitOne(2500) -and $tcp.Connected
            $tcp.Close()
        } catch {}
        if (-not $up) { Set-HostState 'Off' 'Not reachable on SSH - switched off?'; Log 'not reachable on SSH - skipped'; return }

        $base = "-ssh -l $User -pw " + (Q $Pw) + " $Ip"

        # 2. Accept the host key once (PuTTY 0.72: answer 'y' to the prompt, no -batch)
        $r = Run-Plink "$base exit" "y`n" 25
        if ($r.Out -match 'Access denied|password') { Set-HostState 'Failed' 'Login refused - check the password'; Log 'login refused'; return }

        # 3. Which login shell? bash prints the marker, clish rejects the command
        $r = Run-Plink ("-batch $base " + (Q 'echo LSMARK_$((6*7))')) $null 25
        if ($r.TimedOut) { Set-HostState 'Failed' 'No answer over SSH'; Log 'no answer over SSH'; return }
        if ($r.Out -match 'Access denied') { Set-HostState 'Failed' 'Login refused - check the password'; Log 'login refused'; return }
        $shell = $(if ($r.Out -match 'LSMARK_42') { 'bash' } else { 'clish' })
        Log "connected, login shell: $shell"
        if (@($Cmds).Count -eq 0) { Set-HostState "Up ($shell)" 'Ready'; return }

        Set-HostState "Running ($shell)" ''
        $ok = 0; $bad = 0; $skip = 0; $restarting = $false
        foreach ($c in $Cmds) {
            $type = [string]$c.Type; $text = [string]$c.Text

            if ($type -eq 'localise') {
                if ($shell -ne 'bash') {
                    foreach ($pre in 'lock database override', 'set user admin shell /bin/bash') { [void](Run-Plink ("-batch $base " + (Q $pre)) $null 45) }
                    $shell = 'bash'; Log 'switched the admin shell to bash for the keyboard change'
                }
                $f = [IO.Path]::GetTempFileName()
                [IO.File]::WriteAllText($f, ((@($c.Script) -join "`n") + "`n"))
                Log "RUN: $text"
                $r = Run-Plink ("-batch $base -m " + (Q $f)) $null 120
                Remove-Item $f -Force -ErrorAction SilentlyContinue
                Write-Out $r.Out
                if ($r.Out -match 'command not found|CLINFR\d+|NMS[A-Z]{3}\d+') { $bad++; Log 'FAIL: keyboard and time zone' }
                else { $ok++; Log 'OK: keyboard and time zone set' }
                $shell = 'clish'
                continue
            }
            if ($type -eq 'expert' -and $shell -ne 'bash') {
                $skip++; Log "SKIPPED (needs the bash shell - run 'set user admin shell /bin/bash' first): $text"; continue
            }
            $remote = $(if ($type -eq 'clish' -and $shell -eq 'bash') { "clish -c '" + ($text -replace "'", "'\''") + "'" } else { $text })
            $r = Run-Plink ("-batch $base " + (Q $remote)) $null 60
            $failed = $r.TimedOut -or ($r.Out -match 'CLINFR\d+|NMS[A-Z]{3}\d+|command not found|Invalid command|Error:')
            if ($failed) { $bad++; Log ("FAIL: $text" + $(if ($r.TimedOut) { ' (timed out)' } else { '' })) } else { $ok++; Log "OK: $text" }
            Write-Out $r.Out
            if (-not $failed -and $text -match '^\s*set user admin shell\s+(\S+)') { $shell = $(if ($matches[1] -match 'bash') { 'bash' } else { 'clish' }) }
        }
        $summary = "$ok OK" + $(if ($bad) { ", $bad failed" } else { '' }) + $(if ($skip) { ", $skip skipped" } else { '' }) + $(if ($restarting) { ' - restarting' } else { '' })
        Set-HostState $(if ($bad) { 'Done (errors)' } else { 'Done' }) $summary
    }
    catch { Set-HostState 'Failed' $_.Exception.Message; Log ('ERROR: ' + $_.Exception.Message) }
}

$tabGaia = New-Object System.Windows.Forms.TabPage
$tabGaia.Text = '7. Gaia commands'
$tabGaia.Padding = New-Object System.Windows.Forms.Padding(12)
$tabs.TabPages.Add($tabGaia)

$lblGaiaTop = New-Label 'Run Gaia clish or expert commands on several lab hosts at once. Hosts that are switched off are skipped. Commands run in the order shown.' 0 0 10 36
$lblGaiaTop.Dock = 'Top'

$pnlGaiaRun = New-Object System.Windows.Forms.Panel
$pnlGaiaRun.Dock = 'Bottom'; $pnlGaiaRun.Height = 44
$pnlGaiaRun.Controls.Add((New-Label 'Password:' 0 14 72 22))
$txtGaiaPw = New-Object System.Windows.Forms.TextBox
$txtGaiaPw.Location = New-Object System.Drawing.Point(74, 11); $txtGaiaPw.Size = New-Object System.Drawing.Size(140, 26)
$txtGaiaPw.UseSystemPasswordChar = $true; $txtGaiaPw.Text = $LabPassword
$btnGaiaCheck = New-Button 'Check hosts' 226 6 130 34
$btnGaiaRun   = New-Button 'Run on ticked hosts' 364 6 190 34
$lblGaiaMsg   = New-Label '' 566 14 380 22
foreach ($ctl in $txtGaiaPw, $btnGaiaCheck, $btnGaiaRun, $lblGaiaMsg) { $pnlGaiaRun.Controls.Add($ctl) }

$txtGaiaLog = New-Object System.Windows.Forms.TextBox
$txtGaiaLog.Dock = 'Bottom'; $txtGaiaLog.Height = 150
$txtGaiaLog.Multiline = $true; $txtGaiaLog.ReadOnly = $true; $txtGaiaLog.ScrollBars = 'Vertical'; $txtGaiaLog.Font = $FontMono

$splitGaia = New-Object System.Windows.Forms.SplitContainer
$splitGaia.Dock = 'Fill'

# Left: hosts
$lvGaiaHosts = New-Object System.Windows.Forms.ListView
$lvGaiaHosts.Dock = 'Fill'; $lvGaiaHosts.View = 'Details'; $lvGaiaHosts.CheckBoxes = $true; $lvGaiaHosts.FullRowSelect = $true
[void]$lvGaiaHosts.Columns.Add('Host', 130); [void]$lvGaiaHosts.Columns.Add('IP', 100)
[void]$lvGaiaHosts.Columns.Add('Status', 100); [void]$lvGaiaHosts.Columns.Add('Result', 160)
$pnlGaiaHostBtns = New-Object System.Windows.Forms.Panel
$pnlGaiaHostBtns.Dock = 'Bottom'; $pnlGaiaHostBtns.Height = 38
$btnGaiaAll  = New-Button 'All' 0 6 70 28
$btnGaiaNone = New-Button 'None' 76 6 70 28
$pnlGaiaHostBtns.Controls.Add($btnGaiaAll); $pnlGaiaHostBtns.Controls.Add($btnGaiaNone)
$splitGaia.Panel1.Controls.Add($lvGaiaHosts); $splitGaia.Panel1.Controls.Add($pnlGaiaHostBtns)
$lvGaiaHosts.BringToFront()

# Right: commands
$clbGaiaCmds = New-Object System.Windows.Forms.CheckedListBox
$clbGaiaCmds.Dock = 'Fill'; $clbGaiaCmds.CheckOnClick = $true; $clbGaiaCmds.HorizontalScrollbar = $true
$pnlGaiaAdd = New-Object System.Windows.Forms.Panel
$pnlGaiaAdd.Dock = 'Bottom'; $pnlGaiaAdd.Height = 38
$txtGaiaNew = New-Object System.Windows.Forms.TextBox
$txtGaiaNew.Location = New-Object System.Drawing.Point(0, 8); $txtGaiaNew.Size = New-Object System.Drawing.Size(250, 26)
$cbGaiaType = New-Object System.Windows.Forms.ComboBox
$cbGaiaType.DropDownStyle = 'DropDownList'; $cbGaiaType.Location = New-Object System.Drawing.Point(256, 8); $cbGaiaType.Size = New-Object System.Drawing.Size(80, 26)
[void]$cbGaiaType.Items.Add('clish'); [void]$cbGaiaType.Items.Add('expert'); $cbGaiaType.SelectedIndex = 0
$btnGaiaAdd = New-Button 'Add' 342 6 60 28
foreach ($ctl in $txtGaiaNew, $cbGaiaType, $btnGaiaAdd) { $pnlGaiaAdd.Controls.Add($ctl) }
$splitGaia.Panel2.Controls.Add($clbGaiaCmds); $splitGaia.Panel2.Controls.Add($pnlGaiaAdd)
$clbGaiaCmds.BringToFront()

$tabGaia.Controls.Add($splitGaia); $tabGaia.Controls.Add($txtGaiaLog); $tabGaia.Controls.Add($pnlGaiaRun); $tabGaia.Controls.Add($lblGaiaTop)
$splitGaia.BringToFront()

$script:GaiaCmdObjs = New-Object System.Collections.ArrayList
$script:GaiaJobs = @()
$script:GaiaPool = $null
$script:GaiaSync = $null

function Get-GaiaLocaliseItem {
    $script = @('clish -c ''set timezone Europe / London''', 'dbset keyboard:mapping uk')
    $label = 'Keyboard and time zone'
    if ($cbCountry.SelectedIndex -ge 0 -and $cbKeyboard.SelectedIndex -ge 0) {
        $ch = Get-LocChoice
        $label = "Keyboard and time zone: $($ch.Country.name), $($ch.Keyboard.name) (expert, no restart)"
        $tz = "$($ch.Country.gaiaRegion) / $($ch.Country.gaiaZone)"
        $script = @(
            "clish -c 'set timezone $tz'",
            "dbset keyboard:mapping $($ch.Keyboard.gaia)",
            'dbset :save',
            '/bin/kbd_map_xlate keyboard:mapping < /config/db/initial',
            "clish -c 'set user admin shell /etc/cli.sh'",
            "clish -c 'save config'",
            'rm -f /home/admin/.clish_history'
        )
    }
    return [pscustomobject]@{ Text = $label; Type = 'localise'; Script = $script }
}
function Fill-Gaia {
    $lvGaiaHosts.Items.Clear()
    foreach ($h in (Get-CourseValue $Content.gaiaHosts (Get-SelectedCourse))) {
        $it = New-Object System.Windows.Forms.ListViewItem([string]$h.name)
        [void]$it.SubItems.Add([string]$h.ip); [void]$it.SubItems.Add(''); [void]$it.SubItems.Add('')
        $it.Checked = -not ($h.PSObject.Properties['checked'] -and $h.checked -eq $false)
        [void]$lvGaiaHosts.Items.Add($it)
    }
    $clbGaiaCmds.Items.Clear(); $script:GaiaCmdObjs.Clear()
    $loc = Get-GaiaLocaliseItem
    [void]$script:GaiaCmdObjs.Add($loc); [void]$clbGaiaCmds.Items.Add($loc.Text)
    foreach ($c in (Get-CourseValue $Content.gaiaCommands (Get-SelectedCourse))) {
        $o = [pscustomobject]@{ Text = [string]$c.text; Type = $(if ($c.type) { [string]$c.type } else { 'clish' }); Script = $null }
        [void]$script:GaiaCmdObjs.Add($o)
        [void]$clbGaiaCmds.Items.Add($(if ($o.Type -eq 'expert') { "[expert] $($o.Text)" } else { $o.Text }))
    }
}
function Update-GaiaLocaliseItem {
    if ($script:GaiaCmdObjs.Count -eq 0) { return }
    $loc = Get-GaiaLocaliseItem
    $script:GaiaCmdObjs[0] = $loc
    $was = $clbGaiaCmds.GetItemChecked(0)
    $clbGaiaCmds.Items[0] = $loc.Text
    $clbGaiaCmds.SetItemChecked(0, $was)
}
$cbCountry.Add_SelectedIndexChanged({ Update-GaiaLocaliseItem })
$cbKeyboard.Add_SelectedIndexChanged({ Update-GaiaLocaliseItem })

$btnGaiaAll.Add_Click({ foreach ($it in $lvGaiaHosts.Items) { $it.Checked = $true } })
$btnGaiaNone.Add_Click({ foreach ($it in $lvGaiaHosts.Items) { $it.Checked = $false } })
$btnGaiaAdd.Add_Click({
    $v = $txtGaiaNew.Text.Trim()
    if (-not $v) { return }
    $o = [pscustomobject]@{ Text = $v; Type = [string]$cbGaiaType.SelectedItem; Script = $null }
    [void]$script:GaiaCmdObjs.Add($o)
    $i = $clbGaiaCmds.Items.Add($(if ($o.Type -eq 'expert') { "[expert] $v" } else { $v }))
    $clbGaiaCmds.SetItemChecked($i, $true)
    $txtGaiaNew.Clear()
})

$gaiaTimer = New-Object System.Windows.Forms.Timer
$gaiaTimer.Interval = 500
$gaiaTimer.Add_Tick({
    $s = $script:GaiaSync
    if (-not $s) { return }
    $line = $null
    $sb = New-Object System.Text.StringBuilder
    while ($s.Log.TryDequeue([ref]$line)) { [void]$sb.AppendLine($line) }
    if ($sb.Length -gt 0) { $txtGaiaLog.AppendText($sb.ToString()) }
    foreach ($it in $lvGaiaHosts.Items) {
        $ip = $it.SubItems[1].Text
        if ($s.State.ContainsKey($ip)) { $it.SubItems[2].Text = [string]$s.State[$ip] }
        if ($s.Result.ContainsKey($ip)) { $it.SubItems[3].Text = [string]$s.Result[$ip] }
    }
    if (@($script:GaiaJobs | Where-Object { -not $_.Handle.IsCompleted }).Count -eq 0) {
        $gaiaTimer.Stop()
        foreach ($j in $script:GaiaJobs) { try { [void]$j.PS.EndInvoke($j.Handle) } catch {}; $j.PS.Dispose() }
        $script:GaiaJobs = @()
        if ($script:GaiaPool) { $script:GaiaPool.Close(); $script:GaiaPool = $null }
        while ($s.Log.TryDequeue([ref]$line)) { $txtGaiaLog.AppendText($line + "`r`n") }
        $txtGaiaLog.AppendText("--- finished $(Get-Date -Format 'HH:mm:ss') ---`r`n")
        $lblGaiaMsg.Text = 'Finished. See the Result column and the log.'
        $btnGaiaRun.Enabled = $true; $btnGaiaCheck.Enabled = $true
    }
})

function Start-GaiaRun([bool]$CheckOnly) {
    if (-not (Test-Path $PlinkExe)) { [void][System.Windows.Forms.MessageBox]::Show("plink.exe was not found at $PlinkExe", 'Gaia commands'); return }
    $hosts = @($lvGaiaHosts.Items | Where-Object { $_.Checked })
    if ($hosts.Count -eq 0) { $lblGaiaMsg.Text = 'Tick at least one host.'; return }
    $cmds = @()
    if (-not $CheckOnly) {
        for ($i = 0; $i -lt $clbGaiaCmds.Items.Count; $i++) { if ($clbGaiaCmds.GetItemChecked($i)) { $cmds += $script:GaiaCmdObjs[$i] } }
        if ($cmds.Count -eq 0) { $lblGaiaMsg.Text = 'Tick at least one command.'; return }
        $msg = "Run on $($hosts.Count) host(s):`r`n`r`n" + (($cmds | ForEach-Object { '  ' + $_.Text }) -join "`r`n")
        if ([System.Windows.Forms.MessageBox]::Show($msg, 'Gaia commands', 'YesNo', 'Question') -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    }
    $script:GaiaSync = [hashtable]::Synchronized(@{
        Log = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
        State = [hashtable]::Synchronized(@{}); Result = [hashtable]::Synchronized(@{})
    })
    foreach ($it in $hosts) { $it.SubItems[2].Text = 'Queued'; $it.SubItems[3].Text = '' }
    $txtGaiaLog.AppendText("--- $(if ($CheckOnly) { 'checking' } else { 'running' }) on $($hosts.Count) host(s), $(Get-Date -Format 'HH:mm:ss') ---`r`n")
    $script:GaiaPool = [runspacefactory]::CreateRunspacePool(1, 6)
    $script:GaiaPool.Open()
    $script:GaiaJobs = @()
    foreach ($it in $hosts) {
        $ps = [powershell]::Create()
        $ps.RunspacePool = $script:GaiaPool
        [void]$ps.AddScript($GaiaHostWorker).AddArgument($it.SubItems[1].Text).AddArgument($it.Text).AddArgument('admin').AddArgument($txtGaiaPw.Text).AddArgument($PlinkExe).AddArgument([object[]]$cmds).AddArgument($script:GaiaSync)
        $script:GaiaJobs += [pscustomobject]@{ PS = $ps; Handle = $ps.BeginInvoke() }
    }
    $btnGaiaRun.Enabled = $false; $btnGaiaCheck.Enabled = $false
    $lblGaiaMsg.Text = 'Working... the window stays usable.'
    $gaiaTimer.Start()
}
$btnGaiaCheck.Add_Click({ Start-GaiaRun $true })
$btnGaiaRun.Add_Click({ Start-GaiaRun $false })
$form.Add_FormClosing({ $gaiaTimer.Stop(); foreach ($j in $script:GaiaJobs) { try { $j.PS.Stop() } catch {} } })

# ---- Wiring -----------------------------------------------------------------
function Fill-All { Fill-Courses; Fill-Localise; Fill-Checklist; Fill-Credentials; Fill-Tools; Fill-Notes; Fill-Extras; Fill-Gaia }
$cbCourse.Add_SelectedIndexChanged({
    if ($script:FillingCourses) { return }
    $code = Get-SelectedCourse
    if ($code) { try { Set-Content -Path $CourseFile -Value $code -Encoding ASCII } catch {} }
    Fill-Credentials; Fill-Tools; Fill-Notes; Fill-Extras; Fill-Gaia
    if (Test-BookmarksAdded) { Update-Bookmarks }   # keep bookmarks the student added in step with the course
})
$btnRefresh.Add_Click({ Set-Busy $true; $script:Content = Get-LabContent; Fill-All; Set-Busy $false })

# Size the fixed-layout controls on tabs 1 and 2 to the tab (keeps them inside the window at any DPI)
function Fit-Tabs {
    $w = $tabLoc.ClientSize.Width; $h = $tabLoc.ClientSize.Height
    if ($w -gt 200 -and $h -gt 300) {
        $lblLocStatus.Width = $w - 32
        $txtLocLog.SetBounds(16, $txtLocLog.Top, $w - 32, [Math]::Max(80, $h - $txtLocLog.Top - 12))
    }
    $w = $tabChk.ClientSize.Width; $h = $tabChk.ClientSize.Height
    if ($w -gt 200 -and $h -gt 200) {
        $clbW = [Math]::Min(560, [int](($w - 48) * 0.6))
        $clb.SetBounds(16, 46, $clbW, [Math]::Max(80, $h - 58))
        $lblChkDetail.SetBounds(16 + $clbW + 16, 46, [Math]::Max(80, $w - $clbW - 48), [Math]::Max(80, $h - 58))
    }
}
foreach ($c in @($txtLocLog, $lblLocStatus, $clb, $lblChkDetail)) { $c.Anchor = 'Top, Left' }
$tabLoc.Add_Resize({ Fit-Tabs }); $tabChk.Add_Resize({ Fit-Tabs }); $form.Add_Resize({ Fit-Tabs }); $tabs.Add_SelectedIndexChanged({ Fit-Tabs })

$form.Add_Shown({
    Fit-Tabs
    try { $splitGaia.SplitterDistance = [int]($splitGaia.Width * 0.52) } catch {}
    $form.TopMost = $true; $form.Activate(); $form.TopMost = $false
    Show-LocaliseStatus -Quiet $true
})
$form.Add_FormClosed({ $pollTimer.Stop() })

Fill-All
[void]$form.ShowDialog()
