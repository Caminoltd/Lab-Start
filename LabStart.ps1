<#
.SYNOPSIS
    Camino Lab Start - student start tool for Skillable Check Point labs. Runs on A-GUI.

.DESCRIPTION
    One window with tabs:
      1. Localise          - applies keyboard + timezone to every lab VM by running the lab's own
                             C:\scripts\changes.ps1 on RDP-HOST (via a one-off scheduled task there),
                             so the student never has to go to RDP-HOST.
      2. Lab checklist     - tick-off steps (ticks saved per user on this VM).
      3. Credentials & IPs - the lab logins, double-click a cell to copy it.
      4. Check Point Tools - what is in the desktop "Check Point Tools" folder and what each item is for.
      5. Lab notes         - corrections and tips for the labs.

    Text content (checklist, credentials, tool descriptions, notes) comes from content.json in the repo,
    so it can be edited without touching this script.

    Keep this file plain ASCII: Windows PowerShell 5.1 misreads non-ASCII characters in scripts.

.NOTES
    Launch with go.ps1 (irm ... | iex). Needs -STA (WinForms + clipboard); go.ps1 starts it that way.
#>
[CmdletBinding()]
param(
    [switch]$NoContentDownload
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
$Version         = '0.1.2'
$RepoRaw         = 'https://raw.githubusercontent.com/Caminoltd/Lab-Start/main'
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
    $json = $null
    if (-not $NoContentDownload) {
        try {
            $url  = "$RepoRaw/content.json?" + (Get-Date -Format 'yyyyMMddHHmmss')
            $json = (Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 15).Content
        } catch { $json = $null }
    }
    if (-not $json) {
        $local = Join-Path $PSScriptRoot 'content.json'
        if ($PSScriptRoot -and (Test-Path $local)) { $json = Get-Content -Raw -Path $local }
    }
    if (-not $json) { $json = $FallbackContentJson }
    return ($json | ConvertFrom-Json)
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

# Runs ON RDP-HOST: writes the runner script and starts it as a one-off scheduled task, so the work
# carries on when A-GUI restarts part-way through.
$StartLocalise = {
    param([string]$Preset, [string]$User, [string]$Password)

    $dir = 'C:\scripts\LabStart'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null

    $existing = Get-ScheduledTask -TaskName 'LabStart-Localise' -ErrorAction SilentlyContinue
    if ($existing -and "$($existing.State)" -eq 'Running') { return 'already-running' }

    $runner = @'
param([string]$Preset)
$dir    = 'C:\scripts\LabStart'
$log    = Join-Path $dir 'localise.log'
$status = Join-Path $dir 'status.json'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}

function Set-Status([string]$State, [string]$Detail) {
    [pscustomobject]@{ state = $State; preset = $Preset; detail = $Detail; time = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') } |
        ConvertTo-Json | Set-Content -Path $status -Encoding UTF8
}
function Write-Log([string]$Text) { Add-Content -Path $log -Value $Text -Encoding UTF8 }

Set-Content -Path $log -Value ("Lab Start - localise run, preset '{0}', started {1}" -f $Preset, (Get-Date)) -Encoding UTF8
try {
    Set-Status 'running' 'Patching the lab scripts'
    $patcher = Join-Path $dir 'change-lab-uk-v5.ps1'
    $url = 'https://raw.githubusercontent.com/Don-Paterson/SkillableMods/main/change-lab-uk-v5.ps1?' + (Get-Date -Format 'yyyyMMddHHmmss')
    (Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 60).Content | Set-Content -Path $patcher -Encoding UTF8
    & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $patcher -Path 'C:\scripts' 2>&1 | ForEach-Object { Write-Log "$_" }
    if ($LASTEXITCODE -ne 0) { throw "The patcher stopped with exit code $LASTEXITCODE" }

    Set-Status 'running' 'Applying keyboard and timezone to all lab VMs (the Windows VMs restart)'
    & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "& 'C:\scripts\changes.ps1' 'RDP-HOST' '$Preset'" 2>&1 | ForEach-Object { Write-Log "$_" }
    Set-Status 'done' ('Finished at ' + (Get-Date -Format 'HH:mm'))
}
catch {
    Write-Log ('ERROR: ' + $_.Exception.Message)
    Set-Status 'failed' $_.Exception.Message
}
'@
    Set-Content -Path (Join-Path $dir 'run-localise.ps1') -Value $runner -Encoding UTF8

    [pscustomobject]@{ state = 'starting'; preset = $Preset; detail = 'Starting on RDP-HOST'; time = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') } |
        ConvertTo-Json | Set-Content -Path (Join-Path $dir 'status.json') -Encoding UTF8

    $arg      = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -Preset {1}' -f (Join-Path $dir 'run-localise.ps1'), $Preset
    $action   = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arg -WorkingDirectory 'C:\scripts'
    $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Hours 1) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    Register-ScheduledTask -TaskName 'LabStart-Localise' -Action $action -Settings $settings `
        -User "$env:COMPUTERNAME\$User" -Password $Password -RunLevel Highest -Force | Out-Null
    Start-ScheduledTask -TaskName 'LabStart-Localise'
    return 'started'
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

$header = New-Label 'Camino Lab Start' 16 10 600 32 $FontTitle
$form.Controls.Add($header)
$sub = New-Label 'Everything you need before Lab 1A, in one place. Work through the tabs from left to right.' 18 42 900 22
$form.Controls.Add($sub)
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
$cbCountry.Size = New-Object System.Drawing.Size(420, 28)
[void]$cbCountry.Items.Add('United Kingdom - UK keyboard, London time')
$cbCountry.SelectedIndex = 0
$tabLoc.Controls.Add($cbCountry)
$tabLoc.Controls.Add((New-Label 'More countries are coming. Until then, other countries use C:\scripts\changes.cmd on RDP-HOST.' 100 84 840 22))

$btnApply  = New-Button 'Apply to all lab VMs' 100 116 200 36
$btnStatus = New-Button 'Check status' 312 116 150 36
$tabLoc.Controls.Add($btnApply)
$tabLoc.Controls.Add($btnStatus)

$lblLocStatus = New-Label '' 16 164 920 44 $FontBold
$tabLoc.Controls.Add($lblLocStatus)

$txtLocLog = New-Object System.Windows.Forms.TextBox
$txtLocLog.Multiline = $true; $txtLocLog.ReadOnly = $true; $txtLocLog.ScrollBars = 'Vertical'; $txtLocLog.Font = $FontMono
$txtLocLog.Location = New-Object System.Drawing.Point(16, 212)
$txtLocLog.Size = New-Object System.Drawing.Size(920, 266)
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
            'done'      { $lblLocStatus.ForeColor = [System.Drawing.Color]::DarkGreen; $lblLocStatus.Text = "Done: settings '$($s.Preset)' applied. $($s.Detail). Wait until all VMs have restarted (3 to 5 minutes)." }
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
    $msg = "This sets a UK keyboard and London time on all the lab VMs.`r`n`r`n" +
           "About a minute after it starts, the Windows VMs restart - including this one (A-GUI). Save anything you have open first.`r`n`r`n" +
           "When you have logged back in to A-GUI, open Lab Start again (desktop shortcut) and click 'Check status'.`r`n`r`nContinue?"
    $ans = [System.Windows.Forms.MessageBox]::Show($msg, 'Apply keyboard and timezone', 'YesNo', 'Warning')
    if ($ans -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    Set-Busy $true
    try {
        $r = Invoke-OnRdpHost -ScriptBlock $StartLocalise -Arguments @('uk', $LabUser, $LabPassword)
        if ("$r" -eq 'already-running') {
            $lblLocStatus.ForeColor = [System.Drawing.Color]::DarkBlue
            $lblLocStatus.Text = 'Already running on RDP-HOST - showing progress.'
        } else {
            $lblLocStatus.ForeColor = [System.Drawing.Color]::DarkBlue
            $lblLocStatus.Text = 'Started on RDP-HOST. A-GUI will restart shortly - log back in and reopen Lab Start.'
        }
        $pollTimer.Start()
    }
    catch {
        $lblLocStatus.ForeColor = [System.Drawing.Color]::DarkRed
        $lblLocStatus.Text = (Get-FriendlyRemoteError $_)
    }
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
$tabs.TabPages.Add($tabCred)
$tabCred.Controls.Add((New-Label 'Logins for the lab VMs. Double-click any cell to copy it. The full list is on page 3 of each lab guide.' 16 16 900 22))

$grid = New-Object System.Windows.Forms.DataGridView
$grid.Location = New-Object System.Drawing.Point(16, 46)
$grid.Size = New-Object System.Drawing.Size(920, 400)
$grid.Anchor = 'Top, Bottom, Left, Right'
$grid.ReadOnly = $true; $grid.AllowUserToAddRows = $false; $grid.AllowUserToDeleteRows = $false
$grid.RowHeadersVisible = $false; $grid.SelectionMode = 'CellSelect'; $grid.AutoSizeColumnsMode = 'Fill'
foreach ($c in 'System', 'Address', 'Username', 'Password', 'Notes') { [void]$grid.Columns.Add($c, $c) }
$tabCred.Controls.Add($grid)
$lblCopied = New-Label '' 16 452 900 22
$lblCopied.Anchor = 'Bottom, Left'
$tabCred.Controls.Add($lblCopied)

function Fill-Credentials {
    $grid.Rows.Clear()
    foreach ($r in @($Content.credentials)) { [void]$grid.Rows.Add($r.system, $r.address, $r.username, $r.password, $r.notes) }
}
$grid.Add_CellDoubleClick({
    param($sender, $e)
    if ($e.RowIndex -lt 0 -or $e.ColumnIndex -lt 0) { return }
    $v = [string]$grid.Rows[$e.RowIndex].Cells[$e.ColumnIndex].Value
    if ($v) { [System.Windows.Forms.Clipboard]::SetText($v); $lblCopied.Text = "Copied: $v" }
})

# ---- Tab 4: Check Point Tools ----------------------------------------------
$tabTools = New-Object System.Windows.Forms.TabPage
$tabTools.Text = '4. Check Point Tools'
$tabs.TabPages.Add($tabTools)
$tabTools.Controls.Add((New-Label 'What is in the "Check Point Tools" folder on the desktop, and what each item is for. Double-click to open.' 16 16 900 22))

$lvTools = New-Object System.Windows.Forms.ListView
$lvTools.View = 'Details'; $lvTools.FullRowSelect = $true
$lvTools.Location = New-Object System.Drawing.Point(16, 46)
$lvTools.Size = New-Object System.Drawing.Size(920, 420)
$lvTools.Anchor = 'Top, Bottom, Left, Right'
[void]$lvTools.Columns.Add('Item', 280)
[void]$lvTools.Columns.Add('What it is for', 620)
$tabTools.Controls.Add($lvTools)

function Get-ToolsFolder {
    $candidates = @(
        (Join-Path ([Environment]::GetFolderPath('Desktop')) 'Check Point Tools'),
        (Join-Path $env:PUBLIC 'Desktop\Check Point Tools')
    )
    foreach ($p in $candidates) { if (Test-Path $p) { return $p } }
    return $null
}
function Fill-Tools {
    $lvTools.Items.Clear()
    $folder = Get-ToolsFolder
    if (-not $folder) {
        $it = New-Object System.Windows.Forms.ListViewItem('(folder not found)')
        [void]$it.SubItems.Add('No "Check Point Tools" folder on this desktop.')
        [void]$lvTools.Items.Add($it); return
    }
    $descs = @{}
    if ($Content.tools) { foreach ($p in $Content.tools.PSObject.Properties) { $descs[$p.Name] = $p.Value } }
    foreach ($f in Get-ChildItem -Path $folder | Sort-Object Name) {
        $name = [IO.Path]::GetFileNameWithoutExtension($f.Name)
        $desc = ''
        foreach ($k in $descs.Keys) { if ($f.Name -like $k) { $desc = $descs[$k]; break } }
        $it = New-Object System.Windows.Forms.ListViewItem($name)
        [void]$it.SubItems.Add($desc)
        $it.Tag = $f.FullName
        [void]$lvTools.Items.Add($it)
    }
}
$lvTools.Add_DoubleClick({
    if ($lvTools.SelectedItems.Count -gt 0 -and $lvTools.SelectedItems[0].Tag) {
        try { Start-Process -FilePath $lvTools.SelectedItems[0].Tag } catch { [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Could not open') | Out-Null }
    }
})

# ---- Tab 5: Lab notes -------------------------------------------------------
$tabNotes = New-Object System.Windows.Forms.TabPage
$tabNotes.Text = '5. Lab notes'
$tabs.TabPages.Add($tabNotes)
$txtNotes = New-Object System.Windows.Forms.TextBox
$txtNotes.Multiline = $true; $txtNotes.ReadOnly = $true; $txtNotes.ScrollBars = 'Vertical'
$txtNotes.Font = New-Object System.Drawing.Font('Segoe UI', 11)
$txtNotes.Location = New-Object System.Drawing.Point(16, 16)
$txtNotes.Size = New-Object System.Drawing.Size(920, 450)
$txtNotes.Anchor = 'Top, Bottom, Left, Right'
$tabNotes.Controls.Add($txtNotes)
function Fill-Notes { $txtNotes.Text = (@($Content.notes) | ForEach-Object { '- ' + $_ }) -join "`r`n`r`n" }

# ---- Wiring -----------------------------------------------------------------
function Fill-All { Fill-Checklist; Fill-Credentials; Fill-Tools; Fill-Notes }
$btnRefresh.Add_Click({ Set-Busy $true; $script:Content = Get-LabContent; Fill-All; Set-Busy $false })

$form.Add_Shown({
    $form.TopMost = $true; $form.Activate(); $form.TopMost = $false
    Show-LocaliseStatus -Quiet $true
})
$form.Add_FormClosed({ $pollTimer.Stop() })

Fill-All
[void]$form.ShowDialog()
