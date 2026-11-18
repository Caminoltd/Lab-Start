<#
.SYNOPSIS
    Camino Lab Start - add HTTPS (port 443) to the IIS web site on A-DMZ.
.DESCRIPTION
    Runs on A-GUI (Lab Start Extras). Through RDP-HOST (WinRM) it connects to A-DMZ and:
      - creates a self-signed certificate for A-DMZ (names: A-DMZ, its IP addresses, www.alpha.cp),
      - adds an https binding on port 443 to the Default Web Site with that certificate,
      - opens TCP 443 in the Windows firewall.
    The http site on port 80 is not changed. Running it again changes nothing.
    -Remove takes the binding, certificate and firewall rule away again.
    Windows PowerShell 5.1, ASCII only.
#>
[CmdletBinding()]
param(
    [switch]$Remove,
    [string]$DmzHost  = '192.168.12.101',
    [string]$RdpHost  = '10.1.1.230',
    [string]$Password = 'Chkp!234'
)

$ErrorActionPreference = 'Stop'
$env:PSModulePath = "$env:SystemRoot\system32\WindowsPowerShell\v1.0\Modules;$env:ProgramFiles\WindowsPowerShell\Modules"

$OnDmz = {
    param([bool]$Rm)
    Import-Module WebAdministration
    $site = 'Default Web Site'
    $fw   = 'Lab Start - HTTPS 443'
    $tag  = 'Camino Lab Start'
    $out  = @()
    if ($Rm) {
        Get-WebBinding -Name $site -Protocol https -Port 443 -ErrorAction SilentlyContinue | Remove-WebBinding -ErrorAction SilentlyContinue
        if (Test-Path 'IIS:\SslBindings\0.0.0.0!443') { Remove-Item 'IIS:\SslBindings\0.0.0.0!443' -Force }
        Get-ChildItem Cert:\LocalMachine\My | Where-Object { $_.FriendlyName -eq $tag } | Remove-Item -Force
        Get-NetFirewallRule -DisplayName $fw -ErrorAction SilentlyContinue | Remove-NetFirewallRule
        return 'HTTPS removed from A-DMZ (http on port 80 is unchanged).'
    }
    $cert = Get-ChildItem Cert:\LocalMachine\My | Where-Object { $_.FriendlyName -eq $tag -and $_.NotAfter -gt (Get-Date).AddDays(7) } | Select-Object -First 1
    if (-not $cert) {
        $ips = @(Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -ne '127.0.0.1' } | ForEach-Object { $_.IPAddress })
        $names = @('A-DMZ', "$env:COMPUTERNAME", 'www.alpha.cp', 'a-dmz.alpha.cp') + $ips + @('203.0.113.121') | Select-Object -Unique
        $cert = New-SelfSignedCertificate -DnsName $names -CertStoreLocation Cert:\LocalMachine\My -NotAfter (Get-Date).AddYears(5)
        $cert.FriendlyName = $tag
        $out += "certificate created ($($cert.Thumbprint.Substring(0,8))...)"
    } else { $out += 'certificate already there' }
    if (-not (Get-WebBinding -Name $site -Protocol https -Port 443 -ErrorAction SilentlyContinue)) {
        New-WebBinding -Name $site -Protocol https -Port 443 -IPAddress '*'
        $out += 'https binding added on port 443'
    } else { $out += 'https binding already there' }
    if (Test-Path 'IIS:\SslBindings\0.0.0.0!443') { Remove-Item 'IIS:\SslBindings\0.0.0.0!443' -Force }
    Get-Item "Cert:\LocalMachine\My\$($cert.Thumbprint)" | New-Item 'IIS:\SslBindings\0.0.0.0!443' | Out-Null
    if (-not (Get-NetFirewallRule -DisplayName $fw -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -DisplayName $fw -Direction Inbound -Protocol TCP -LocalPort 443 -Action Allow | Out-Null
        $out += 'firewall opened for TCP 443'
    }
    return ($out -join '; ')
}

Write-Host ''
Write-Host $(if ($Remove) { 'Camino Lab Start - remove HTTPS from A-DMZ' } else { 'Camino Lab Start - add HTTPS to A-DMZ' }) -ForegroundColor White
Write-Host ('-' * 50) -ForegroundColor DarkGray
try {
    $rc = New-Object System.Management.Automation.PSCredential ('Admin', (ConvertTo-SecureString $Password -AsPlainText -Force))
    $r = Invoke-Command -ComputerName $RdpHost -Credential $rc -ArgumentList $OnDmz.ToString(), $DmzHost, $Password, ([bool]$Remove) -ErrorAction Stop -ScriptBlock {
        param([string]$Code, [string]$Dmz, [string]$Pw, [bool]$Rm)
        $dc = New-Object System.Management.Automation.PSCredential ('ALPHA\Administrator', (ConvertTo-SecureString $Pw -AsPlainText -Force))
        Invoke-Command -ComputerName $Dmz -Credential $dc -ScriptBlock ([scriptblock]::Create($Code)) -ArgumentList $Rm -ErrorAction Stop
    }
    Write-Host "A-DMZ ($DmzHost): $r" -ForegroundColor Green
    if (-not $Remove) {
        $code = & "$env:SystemRoot\System32\curl.exe" -k -s -m 10 -o NUL -w '%{http_code}' "https://$DmzHost/" 2>$null
        if ($code -eq '200') { Write-Host "Test from A-GUI: https://$DmzHost/ -> HTTP 200" -ForegroundColor Green }
        else { Write-Host "Test from A-GUI: https://$DmzHost/ -> $code (check the Access Control policy allows https from A-GUI to A-DMZ)" -ForegroundColor Yellow }
        Write-Host ''
        Write-Host 'A-DMZ answers on https://192.168.12.101; from outside (Attacker) on https://203.0.113.121 once the policy allows https to A-DMZ-NAT.' -ForegroundColor Cyan
        Write-Host 'The certificate is self-signed, so browsers warn unless HTTPS inspection re-signs the traffic.' -ForegroundColor Cyan
    }
}
catch { Write-Host "Failed: $($_.Exception.Message)" -ForegroundColor Red }
