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

The student chooses their course at the top right (remembered on A-GUI). Every course uses the same A-GUI image, so the course choice decides what tabs 3 to 5 show.

Tabs 2 to 5 are filled from **`content.json`** (cached on A-GUI in case the download fails): edit that file to change the wording, credentials, tool descriptions or notes. No code change needed.

## How Localise works

1. A-GUI connects to RDP-HOST with PowerShell remoting (WinRM) as `Admin`. Tested in a CCSA lab on 10 Nov 2026: this works with no extra setup.
2. On RDP-HOST it writes `C:\scripts\LabStart\run-localise.ps1` and starts it as a one-off scheduled task (`LabStart-Localise`, running as Admin). The run therefore carries on when A-GUI restarts part-way through.
3. The runner downloads the SkillableMods v5 patcher, patches `C:\scripts\changes.ps1`/`changes.cmd` (skipped if already patched), then runs `changes.ps1 'RDP-HOST' 'uk'`. That is the same sequence as `run-uk-setup.ps1`, tested from A-GUI on 10 Nov 2026.
4. Progress goes to `C:\scripts\LabStart\status.json` and `localise.log` on RDP-HOST. The Localise tab polls them every 10 seconds, and reads them again when Lab Start is reopened after the restart.

## Status

- **v0.2.0**: course selector; per-course credentials (CCSA, CCSE; others use `default`); tools tab filtered; notes link to the course pages; auto-reopen after the restart.
- **v0.1.0**: UK only. Other countries need a generic preset in the patcher. Next step: get a copy of the original `C:\scripts\changes.ps1` (the `.bak-*` file on RDP-HOST) to check which keyboard, timezone and Gaia values its menus accept.
- `content.json` holds only values confirmed so far. Add per-course credentials, IPs and lab notes.

## Test plan for a fresh lab

1. On A-GUI, run the one-liner. The window opens and the shortcut appears.
2. The Localise tab says "Not applied yet in this lab".
3. Click Apply and confirm. The status shows progress, and A-GUI restarts about a minute later.
4. Log back in and double-click the Lab Start shortcut. The Localise tab should say Done.
5. Check one Gaia host (`show clock`, `show timezone`) and the keyboard on a Windows VM other than A-GUI.
6. On RDP-HOST, `C:\scripts\LabStart\localise.log` should hold the full output.
