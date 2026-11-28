<#
.SYNOPSIS
    Camino Lab Start - lab inventory (for the trainer).
.DESCRIPTION
    Finds every VM in the running lab and writes the exact host list for Lab Start's content.json
    ("localiseHosts"), so Localise and Optimise act on the VMs this course's lab really has.

    Runs on A-GUI. The scan itself runs on RDP-HOST, which reaches every lab network:
      1. Sweeps RDP-HOST's own networks, its routes and the known lab networks for WinRM (5985) and SSH (22).
      2. Logs in to each one read-only to learn what it is and its name:
           WinRM -> Windows (ALPHA\Administrator, admin, .\admin)
           SSH   -> Gaia (admin), VyOS (vyos) or Linux (root); anything else is listed but left out
      3. One entry per VM: a VM answering on several addresses keeps its main lab address; a cluster address
         (10.1.1.1 answering as a member) goes in "gaiaLate".
    Nothing on any VM is changed.
    Prints a table and a block to paste into content.json under "localiseHosts".
    Windows PowerShell 5.1, ASCII only.
.PARAMETER Course
    Course code for the block (default: the course chosen in Lab Start).
#>
[CmdletBinding()]
param(
    [string]$Course,
    [string]$RdpHost  = '10.1.1.230',
    [string]$Password = 'Chkp!234',
    # Lab networks seen across the courses; RDP-HOST's own networks and routes are added to these
    [string[]]$Networks = @('10.1.1', '192.168.11', '192.168.12', '192.168.13', '192.168.21', '192.168.22', '192.168.31', '172.31.1',
                            '192.168.110', '192.168.111', '192.168.112', '192.168.120', '192.168.130',
                            '192.0.2', '198.51.100', '203.0.113')
)
$ErrorActionPreference = 'Stop'
function Say([string]$t, [string]$c = 'Gray') { Write-Host $t -ForegroundColor $c }
if (-not $Course) { try { $Course = (Get-Content (Join-Path $env:LOCALAPPDATA 'LabStart\course.txt') -ErrorAction Stop).Trim() } catch { $Course = 'COURSE' } }

$scan = {
    param([string[]]$Known, [string]$Pw)
    $ErrorActionPreference = 'Continue'
    $plink = 'C:\Program Files\PuTTY\plink.exe'

    # --- networks to sweep: known + RDP-HOST's own + its routes (never the Skillable NAT / internet side) ---
    $own = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -notmatch '^(127|169\.254)\.' } | ForEach-Object { $_.IPAddress })
    $nets = New-Object System.Collections.Generic.List[string]
    foreach ($n in @($Known) + @($own | ForEach-Object { ($_ -split '\.')[0..2] -join '.' }) +
                   @(Get-NetRoute -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.DestinationPrefix -match '/(2[4-9]|3[0-2])$' -and $_.DestinationPrefix -notmatch '^(0\.|127\.|224\.|255\.)' } |
                     ForEach-Object { (($_.DestinationPrefix -split '/')[0] -split '\.')[0..2] -join '.' })) {
        if ($n -and $n -notmatch '^192\.168\.100$' -and -not $nets.Contains($n)) { $nets.Add($n) }
    }

    # --- TCP sweep, one network at a time (254 connects in parallel, 1.5 s wait) ---
    function Sweep([string]$Net, [int]$Port) {
        $t = @{}
        foreach ($i in 1..254) { $ip = "$Net.$i"; $c = New-Object Net.Sockets.TcpClient; try { $t[$ip] = @($c, $c.ConnectAsync($ip, $Port)) } catch { $c.Close() } }
        Start-Sleep -Milliseconds 1500
        foreach ($k in @($t.Keys)) { $c = $t[$k][0]; $a = $t[$k][1]; if ($a.IsCompleted -and -not $a.IsFaulted -and $c.Connected) { $k }; try { $c.Close() } catch {} }
    }
    $win = @(); $ssh = @()
    foreach ($n in $nets) { $win += @(Sweep $n 5985); $ssh += @(Sweep $n 22) }
    $win = @($win | Where-Object { $own -notcontains $_ } | Sort-Object { [version]$_ } -Unique)
    $ssh = @($ssh | Where-Object { $own -notcontains $_ -and $win -notcontains $_ } | Sort-Object { [version]$_ } -Unique)

    $found = New-Object System.Collections.Generic.List[object]
    $found.Add([pscustomobject]@{ Ip = 'this machine'; Kind = 'Windows'; Name = $env:COMPUTERNAME; How = 'RDP-HOST (local)' })

    # --- Windows: read the computer name ---
    $sec = ConvertTo-SecureString $Pw -AsPlainText -Force
    foreach ($ip in $win) {
        $name = $null; $how = ''
        foreach ($u in 'ALPHA\Administrator', 'admin', '.\admin') {
            try {
                $name = Invoke-Command -ComputerName $ip -Credential (New-Object PSCredential($u, $sec)) -ErrorAction Stop `
                        -SessionOption (New-PSSessionOption -OpenTimeout 15000 -OperationTimeout 30000) -ScriptBlock { $env:COMPUTERNAME }
                $how = $u; break
            } catch {}
        }
        $found.Add([pscustomobject]@{ Ip = $ip; Kind = $(if ($name) { 'Windows' } else { 'Windows?' }); Name = "$name"; How = $(if ($name) { "as $how" } else { 'WinRM open, no lab login' }) })
    }

    # --- SSH: Gaia (admin), VyOS (vyos), Linux (root) ---
    function Plink([string]$Ip, [string]$User, [string]$Cmd) {
        $psi = New-Object Diagnostics.ProcessStartInfo $plink, ("-batch -ssh -l $User -pw `"$Pw`" $Ip " + '"' + ($Cmd -replace '"', '\"') + '"')
        $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.CreateNoWindow = $true
        $p = [Diagnostics.Process]::Start($psi); $o = $p.StandardOutput.ReadToEndAsync(); $e = $p.StandardError.ReadToEndAsync()
        if (-not $p.WaitForExit(20000)) { try { $p.Kill() } catch {} }
        return ($o.Result + "`n" + $e.Result)
    }
    function OneName([string]$Out) {
        if ($Out -match 'not found|Invalid|denied|error|incomplete') { return $null }
        $l = @($Out -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_ -notmatch 'authorized|banner|Using username|Keyboard-interactive|Pre-authentication|^\*' })
        if ($l.Count -eq 1 -and $l[0] -match '^[A-Za-z0-9][\w.-]*$') { return $l[0] }
        return $null
    }
    if (Test-Path $plink) {
        foreach ($ip in $ssh) {
            $null = "y`n" | & $plink -ssh -l admin -pw $Pw $ip exit 2>&1      # accept the host key once
            $kind = 'SSH'; $name = ''; $how = 'SSH open, no lab login'
            $o = Plink $ip 'admin' 'show hostname'                                  # Gaia, clish login shell
            if ($o -notmatch 'denied') {
                $n = OneName $o
                if ($n) { $kind = 'Gaia'; $name = $n; $how = 'admin' }
                else {
                    $n = OneName (Plink $ip 'admin' "clish -c 'show hostname'")     # Gaia, bash login shell
                    if ($n) { $kind = 'Gaia'; $name = $n; $how = 'admin (bash shell)' }
                }
            }
            if ($kind -eq 'SSH') {
                $o = Plink $ip 'vyos' 'cat /etc/hostname; test -d /opt/vyatta && echo ISVYOS'
                if ($o -match 'ISVYOS') { $n = OneName (($o -split "`r?`n" | Where-Object { $_ -notmatch 'ISVYOS' }) -join "`n"); if ($n) { $kind = 'VyOS'; $name = $n; $how = 'vyos' } }
            }
            if ($kind -eq 'SSH') {
                $o = Plink $ip 'root' 'echo LSNAME_$(hostname -s)'
                if ($o -match 'LSNAME_(\S+)') { $kind = 'Linux'; $name = $Matches[1]; $how = 'root' }
            }
            $found.Add([pscustomobject]@{ Ip = $ip; Kind = $kind; Name = $name; How = $how })
        }
    } else {
        foreach ($ip in $ssh) { $found.Add([pscustomobject]@{ Ip = $ip; Kind = 'SSH'; Name = ''; How = 'plink not on RDP-HOST' }) }
    }
    [pscustomobject]@{ Networks = @($nets); Found = @($found) }
}

Say ''
Say "Camino Lab Start - lab inventory for $Course (read-only; takes 1-3 minutes)" 'White'
Say ('-' * 70) 'DarkGray'
$rc = New-Object PSCredential('Admin', (ConvertTo-SecureString $Password -AsPlainText -Force))
$r = Invoke-Command -ComputerName $RdpHost -Credential $rc -ScriptBlock $scan -ArgumentList (, $Networks), $Password
Say ("Networks swept: " + ($r.Networks -join ', ')) 'DarkGray'

# --- one entry per VM: keep its main address (10.1.1.x first, then the order of -Networks; .1 last) ---
$rank = { param($ip) if ($ip -eq 'this machine') { return -1 }; $o = $ip -split '\.'; $net = $o[0..2] -join '.'
          $i = [array]::IndexOf($Networks, $net); if ($i -lt 0) { $i = 99 }; return ($i * 1000) + $(if ($o[3] -eq '1') { 500 } else { 0 }) + [int]$o[3] }
$all = @($r.Found)
$named = @($all | Where-Object { $_.Name })
$keep = @(); $late = @()
foreach ($g in ($named | Group-Object { "$($_.Kind)|$($_.Name.ToUpper())" })) {
    $ips = @($g.Group | Sort-Object { & $rank $_.Ip })
    $keep += $ips[0]
    if ($ips[0].Kind -eq 'Gaia' -and @($ips | Where-Object { $_.Ip -eq '10.1.1.1' }) -and $ips[0].Ip -ne '10.1.1.1') { $late += '10.1.1.1' }
}
$unknown = @($all | Where-Object { -not $_.Name })

Say ''
Say ("{0,-16} {1,-9} {2,-18} {3}" -f 'Address', 'Kind', 'Name', 'Login') 'Cyan'
foreach ($h in ($keep | Sort-Object Kind, { & $rank $_.Ip })) { Say ("{0,-16} {1,-9} {2,-18} {3}" -f $h.Ip, $h.Kind, $h.Name, $h.How) }
if ($late) { Say ("{0,-16} {1,-9} {2,-18} {3}" -f '10.1.1.1', 'Gaia', '(cluster address)', 'done last, skipped if its member is done') }
foreach ($h in $unknown) { Say ("{0,-16} {1,-9} {2,-18} {3}" -f $h.Ip, $h.Kind, '-', $h.How) 'DarkYellow' }
$dups = @($named | Where-Object { $keep -notcontains $_ -and $_.Ip -ne '10.1.1.1' })
if ($dups) { Say ('Also answering (same VM on another address, left out): ' + (($dups | ForEach-Object { "$($_.Ip)=$($_.Name)" }) -join ', ')) 'DarkGray' }

# --- the content.json block ---
$pick = { param($k) @($keep | Where-Object { $_.Kind -eq $k -and $_.Ip -ne 'this machine' } | Sort-Object { & $rank $_.Ip } | ForEach-Object { $_.Ip }) }
$entry = [ordered]@{ windows = & $pick 'Windows'; gaia = & $pick 'Gaia' }
if ($late) { $entry.gaiaLate = @('10.1.1.1') }
$l = & $pick 'Linux'; if ($l) { $entry.linux = $l }
$v = & $pick 'VyOS';  if ($v) { $entry.vyos = $v }
$json = "`"$Course`": " + (ConvertTo-Json ([pscustomobject]$entry) -Depth 3)
Say ''
Say 'Paste this into content.json under "localiseHosts" (it is also on the clipboard):' 'Green'
Write-Host $json
try { Set-Clipboard -Value $json } catch {}
if ($unknown) { Say ''; Say 'Yellow lines: answering, but no lab login worked (e.g. the Kali attacker, or a router with SSH closed to RDP-HOST). They are left out; add them by hand if Lab Start should set them.' 'Yellow' }
Say 'VMs that are switched off in this lab are not found - start them first if they belong in the list.' 'DarkGray'
