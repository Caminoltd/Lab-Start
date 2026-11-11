# Lab Start

A student start tool for Camino Ltd's Skillable Check Point labs. It runs on **A-GUI** and puts everything needed before Lab 1A in one window.

## Start it (on A-GUI, in PowerShell)

```powershell
irm https://raw.githubusercontent.com/Caminoltd/Lab-Start/main/go.ps1 | iex
```

This opens the window and adds a **Lab Start** shortcut on the desktop, so students can reopen it after A-GUI restarts. The shortcut always fetches the latest version.

## Tabs

| Tab | What it does |
| --- | --- |
| 1. Localise | Applies keyboard and timezone to every lab VM in one click, without going to RDP-HOST. Lab Start reopens by itself after A-GUI restarts (RunOnce) and shows the result. |
| 2. Lab checklist | Steps to tick off; ticks are saved on A-GUI for that user. |
| 3. Credentials & IPs | Logins and IPs for the chosen course; double-click a cell to copy it. Button opens the course's credentials PDF. |
| 4. Check Point Tools | The chosen course's documents, then the main tools. "Show everything" lists the rest of the folder. |
| 5. Lab notes | Notes for the chosen course, plus buttons for the course page (lab notes, topology) and the checklist on caminoltd.github.io. |
| 6. Extras | Optional tools (MobaXterm setup, SmartConsole cleanup, ...) from `extras` in content.json. Each runs in its own PowerShell window. |
| 7. Gaia commands | Runs clish or expert commands on ticked Gaia hosts in parallel via plink. Skips hosts that are off (port 22 check), accepts host keys, detects the login shell (clish commands are wrapped in `clish -c` on bash hosts), one SSH call per command with a timeout, so nothing hangs. Built-in item: keyboard and time zone for the country chosen in tab 1 (the original `changes.ps1` Gaia sequence; restarts the host), for VMs that were off when Localise ran. Hosts and commands: `gaiaHosts` / `gaiaCommands` in content.json. |

The student chooses their course at the top right (remembered on A-GUI). Every course uses the same A-GUI image, so the course choice decides what tabs 3 to 5 show.

Tabs 2 to 5 are filled from **`content.json`** (cached on A-GUI in case the download fails): edit that file to change the wording, credentials, tool descriptions or notes. No code change needed.

## How Localise works

1. A-GUI connects to RDP-HOST with PowerShell remoting (WinRM) as `Admin`. Tested in a CCSA lab on 10 Nov 2026: this works with no extra setup.
2. It copies the localisation engine `LabLocalise.ps1` (from this repo, same commit as Lab Start) and a `settings.json` for the chosen country and keyboard to `C:\scripts\LabStart\` on RDP-HOST, and starts it as a one-off scheduled task (`LabStart-Localise`, running as Admin). The run therefore carries on when A-GUI restarts part-way through.
3. The engine does not use Oliver's `changes.cmd` / `changes.ps1` at all. It localises RDP-HOST itself (no restart), then in parallel: every Windows VM over WinRM as `ALPHA\Administrator` (time zone, language list = chosen keyboard + en-US, rewrites `C:\scripts\local_changes.ps1` so the image's logon script keeps the new settings, restart after 60 s), and every Gaia host over plink (time zone, keyboard map, login shell back to clish, save config, restart). Hosts that are off are skipped and listed. Cluster addresses (`gaiaLateHosts`, default 10.1.1.1) run last and are skipped when they answer as a member that is already done, so a cluster member is never restarted twice. Optional per-course host lists: `localiseHosts` in content.json.
4. Progress goes to `C:\scripts\LabStart\status.json` and `localise.log` on RDP-HOST. The Localise tab polls them every 10 seconds, and reads them again when Lab Start is reopened after the restart.

## Status

- **v0.7.2**: browser bookmarks are optional: buttons 'Add browser bookmarks' and 'Remove bookmarks' on tab 3 (nothing is added at start-up any more). Once added, they follow a course change. Remove deletes the policies and any policy keys left empty, so the browsers stop showing 'Managed by your organization'. Extras: traffic generator start / stop. Tested on A-GUI 11 Nov 2026.
- **v0.7.1 / engine 1.0.1**: new engine `LabLocalise.ps1` replaces the `changes.ps1` patch method, so Lab Start no longer depends on the image's scripts. Tested in a CCSE lab on 11 Nov 2026: Netherlands (all 6 Windows VMs + RDP-HOST on W. Europe / en-US, 7 Gaia hosts on Europe/Amsterdam) and back to United Kingdom (GMT / en-GB, Europe/London); whole run about 10 seconds plus restarts. Cluster VIP handled last. Lab Start reopens after the restart with the same commit (`-Ref`).
- **v0.6.0**: web portal bookmarks: when a course is chosen (and at every start), the https addresses from its credentials list are added to Chrome, Edge and Firefox as a 'Lab - <course>' folder on the bookmarks bar. Written as machine browser policies through a WinRM session to A-GUI itself as ALPHA\\Administrator (no UAC prompt). Extra links per course: `bookmarks` in content.json. 'Open web address' button on tab 3. More Gaia commands (show version all, hcp -r all, show cluster state, show security-gateway policy, show route); command output up to 80 lines. Extras can run elevated / in PowerShell 7. Localise moves en-US to second place in the Windows language list (winget was falling back to French).
- **v0.5.0**: tab 7 Gaia commands (replaces Plink-Automation, which hung on interactive clish sessions). Tested 10 Nov 2026 on clish and bash hosts.
- **v0.4.0**: tab 6 Extras.
- **v0.3.0**: 31 countries plus a keyboard choice (values checked against the original `changes.ps1` menus). The runner adds a `custom` case to the SkillableMods preset block and calls `changes.ps1 'RDP-HOST' 'custom' <winKbd> <gaiaKbd> <winTz> <region> <zone>`. `go.ps1` pins the latest commit so new versions load at once. Tested in a CCSE lab on 10 Nov 2026 (Ireland): Gaia hosts set to Europe/Dublin, A-GUI restarted and Lab Start reopened by itself showing Done.
- **v0.2.0**: course selector; per-course credentials (CCSA, CCSE; others use `default`); tools tab filtered; notes link to the course pages; auto-reopen after the restart.
- **v0.1.0**: UK only.
- `content.json` holds only values confirmed so far. Add per-course credentials, IPs and lab notes.

## Test plan for a fresh lab

1. On A-GUI, run the one-liner. The window opens and the shortcut appears.
2. The Localise tab says "Not applied yet in this lab".
3. Click Apply and confirm. The status shows progress, and A-GUI restarts about a minute later.
4. Log back in and double-click the Lab Start shortcut. The Localise tab should say Done.
5. Check one Gaia host (`show clock`, `show timezone`) and the keyboard on a Windows VM other than A-GUI.
6. On RDP-HOST, `C:\scripts\LabStart\localise.log` should hold the full output.
