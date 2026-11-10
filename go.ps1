<#
.SYNOPSIS
    Bootstrap for Camino Lab Start. Run on A-GUI:
        irm https://raw.githubusercontent.com/Caminoltd/Lab-Start/main/go.ps1 | iex

    Downloads the latest LabStart.ps1, opens it in its own window, and puts a "Lab Start" shortcut
    on the desktop so it can be reopened after A-GUI restarts.
#>
$ErrorActionPreference = 'Stop'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}

$main = 'https://raw.githubusercontent.com/Caminoltd/Lab-Start/main'
# Pin the latest commit so a just-published change is used at once (raw.githubusercontent.com caches 'main' for ~5 minutes)
$ref = 'main'
try {
    $sha = Invoke-RestMethod -Uri 'https://api.github.com/repos/Caminoltd/Lab-Start/commits/main' -Headers @{ 'User-Agent' = 'LabStart'; 'Accept' = 'application/vnd.github.sha' } -TimeoutSec 10
    if ("$sha" -match '^[0-9a-f]{40}$') { $ref = "$sha" }
} catch {}
$repo = "https://raw.githubusercontent.com/Caminoltd/Lab-Start/$ref"
$dir  = Join-Path $env:LOCALAPPDATA 'LabStart'
New-Item -ItemType Directory -Force -Path $dir | Out-Null
$file = Join-Path $dir 'LabStart.ps1'

Write-Host 'Lab Start: downloading...' -ForegroundColor Cyan
(Invoke-WebRequest -Uri ("$repo/LabStart.ps1?" + (Get-Date -Format 'yyyyMMddHHmmss')) -UseBasicParsing).Content |
    Set-Content -Path $file -Encoding UTF8

# Desktop shortcut that always fetches the latest version
try {
    $lnk = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Lab Start.lnk'
    $ws  = New-Object -ComObject WScript.Shell
    $sc  = $ws.CreateShortcut($lnk)
    $sc.TargetPath   = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $sc.Arguments    = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command `"irm '$main/go.ps1' | iex`""
    $sc.IconLocation = "$env:SystemRoot\System32\imageres.dll,76"
    $sc.Description  = 'Camino Lab Start'
    $sc.Save()
} catch { Write-Host "  (could not create the desktop shortcut: $($_.Exception.Message))" -ForegroundColor Yellow }

Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
    -ArgumentList @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', "`"$file`"", '-Ref', $ref)
Write-Host 'Lab Start is opening.' -ForegroundColor Green
