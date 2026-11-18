<#
.SYNOPSIS
    Camino Lab Start - Threat Prevention test traffic for the CTPS labs.
.DESCRIPTION
    Runs on A-GUI (Lab Start Extras). Uses only the course's own test files, pages and attack steps.
      -Test Malware : from A-GUI, fetches the EICAR file, the wicar test page, the Anti-Bot test page,
                      cpcheckme and the threat-cloud bot test pages, and reports Blocked / Allowed / No answer.
      -Test Attacks : on the Attacker (Kali) through RDP-HOST: nikto against A-DMZ-NAT (time-limited) and
                      large ICMP packets (hping3 -d 2200 and -d 5000), as in Labs 2A, 6A and 7A.
      -Test Flood   : on the Attacker: ICMP flood at the gateway (Lab 10A penalty box), stopped after -Seconds.
    -Repeat N runs the chosen test N times with a pause between, so logs keep arriving during a demo.
    Kali needs SSH on (once, on Kali: sudo systemctl enable --now ssh).
    Windows PowerShell 5.1, ASCII only.
#>
[CmdletBinding()]
param(
    [ValidateSet('Malware', 'Attacks', 'Flood')][string]$Test = 'Malware',
    [int]$Repeat = 1,
    [int]$PauseSeconds = 30,
    [int]$Seconds = 20,
    [string]$Target   = '203.0.113.121',   # A-DMZ-NAT
    [string]$GwTarget = '203.0.113.1',     # A-GW external
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

function Invoke-FloodTest {
    $sh = @"
P='$KaliPassword'
echo '== hping3 ICMP flood (500-byte) at $GwTarget for $Seconds s'
echo "`$P" | sudo -S -p '' timeout -s INT $Seconds hping3 --flood -1 -d 500 $GwTarget 2>&1 | tail -4
"@
    Invoke-OnAttacker $sh ($Seconds + 60) | ForEach-Object { Say "  $_" 'Gray' }
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
            'Flood'   { Invoke-FloodTest }
        }
    } catch { Say "  Failed: $($_.Exception.Message)" 'Red' }
    if ($i -lt $Repeat) { Start-Sleep -Seconds $PauseSeconds }
}
Say ''
Say 'Done. See the results in SmartConsole: Logs & Events (Threat Prevention), or in Web SmartConsole.' 'Green'
