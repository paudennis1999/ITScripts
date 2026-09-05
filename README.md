# ITScripts
Lightweight PowerShell agent for centralized script distribution, integrity verification, and scheduled execution across Windows endpoints.

Built to solve a real problem: distributing and running maintenance/automation scripts across a fleet of Windows PCs that don't share a domain controller or a full RMM (Remote Monitoring & Management) platform, using only an FTP server as the source of truth.

## How it works

```
┌─────────────┐         ┌──────────────────┐         ┌─────────────────┐
│  FTP Server │ ──────▶ │  Windows Agent   │ ──────▶ │  Local Scripts │
│             │         │  (Task Scheduler,│         │  (per group,    │
│ config.json │         │   runs as SYSTEM │         │   per schedule) │
│Scripts/*.ps1│         │   every 5 min)   │         │                 │
└─────────────┘         └──────────────────┘         └─────────────────┘
```

1. **`Install.ps1`** is run once, as administrator, on each target machine. It asks which *group* the machine belongs to, saves the FTP credentials and group into `agent-config.json`, copies `Agent.ps1` into place, and registers a Scheduled Task (running as `SYSTEM`) that triggers at startup and then every 5 minutes, forever.
2. **`Agent.ps1`** runs on every trigger. Each run:
   - downloads the shared `config.json` from the FTP server,
   - matches every script entry against the machine's group (with support for group inheritance, see below),
   - downloads matching scripts, verifying their SHA-256 hash if one is provided,
   - decides whether each script is actually *due* right now, based on its own `schedule` (`manual`, `interval`, `daily`, `weekly`),
   - executes it, and logs everything to a rolling local log file.

The agent has no long-running process and no in-memory state: everything it needs to "remember" between runs (last execution time per script) is persisted to a small JSON state file, so it's resilient to reboots and crashes.

## Features

- **Group-based script distribution**, with one-way group inheritance (e.g. a `GROUP_A_SUB` machine gets everything `GROUP_A` gets, plus its own scripts — but not the other way around).
- **Per-script scheduling** independent of how often the agent itself is triggered:
  - `manual` — no automatic gating, purely controlled by an `execute` flag
  - `interval` — run every N minutes
  - `daily` — run once a day, at or after a given time
  - `weekly` — run once a week, on a given day and time
- **Integrity verification** via SHA-256 hash checking on downloaded scripts.
- **Path traversal protection** on script names and resolved download paths.
- **Overlap protection**, at two independent levels: a Scheduled Task setting (`MultipleInstances IgnoreNew`) plus a named system Mutex inside the agent itself, so a manual test run and a scheduled run can never execute concurrently.
- **Self-healing schedule state**: a corrupted or missing state file is transparently recreated rather than crashing the agent.
- **Post-install verification**: the installer re-reads the Scheduled Task right after creating it and confirms both triggers were actually saved (see "Lessons learned" below for why this matters).

## Configuration

### `agent-config.json` (created by the installer, one per machine)

```json
{
    "ftpServer": "ftp://ftp.example.com/ITScripts/",
    "username": "ftp-user",
    "password": "ftp-password",
    "group": "GROUP_A"
}
```

### `config.json` (shared, lives on the FTP server, edited centrally)

```json
{
    "scripts": [
        {
            "name": "cleanup.ps1",
            "enabled": true,
            "execute": true,
            "group": "GROUP_A",
            "sha256": "3B1A2C...",
            "schedule": {
                "type": "daily",
                "time": "19:00"
            }
        },
        {
            "name": "healthcheck.ps1",
            "enabled": true,
            "execute": true,
            "group": "ALL",
            "schedule": {
                "type": "interval",
                "minutes": 5
            }
        },
        {
            "name": "weekly_report.ps1",
            "enabled": true,
            "execute": true,
            "group": "GROUP_A_SUB",
            "schedule": {
                "type": "weekly",
                "day": "Monday",
                "time": "08:00"
            }
        }
    ]
}
```

- `sha256` is optional — if present, the download is rejected and discarded when it doesn't match.
- `group` on a script is the *minimum* group required to run it; see group inheritance above.
- Any script without a recognized `schedule` runs every time the agent finds it enabled and its group matches (legacy behavior).

## Installation

On each target machine, as Administrator, with `Install.ps1` and `Agent.ps1` in the same folder:

```powershell
powershell -ExecutionPolicy Bypass -File .\Install.ps1
```

The installer will prompt for the target group and FTP credentials, then set everything up.

## Security considerations (read before using this in a real environment)

This project was built for an internal, trusted LAN with an FTP server under direct control — it is **not** hardened for a hostile network or an untrusted FTP host. Known limitations, by design trade-off rather than oversight:

- **FTP is unencrypted.** Credentials and script contents travel in plaintext. Use FTPS or move to an authenticated HTTPS endpoint if the network isn't fully trusted.
- **Credentials are stored in plaintext** in `agent-config.json` on each machine's disk.
- **The SHA-256 check verifies integrity, not authenticity.** Since both the script and its expected hash come from the same FTP server, a compromised server can update both consistently. There's no independent signing or trusted source verification.
- **The agent runs as `SYSTEM`** and executes arbitrary downloaded code with `-ExecutionPolicy Bypass`. This is a supply-chain risk: control of the FTP server means code execution as SYSTEM on every enrolled machine.
- No tamper-evidence on the local log or schedule-state files.

None of this is disqualifying for the use case it was built for (internal maintenance scripts on a controlled LAN), but it should be a conscious choice, not an assumption, before pointing this at anything more exposed.

## Lessons learned (a couple of real bugs worth knowing about)

- **`New-ScheduledTaskTrigger -RepetitionDuration` is oddly finicky.** A large-but-finite `TimeSpan` (e.g. `New-TimeSpan -Days 3650`) gets silently dropped by `Register-ScheduledTask` — the task registers successfully, with no error, but ends up with only the startup trigger. `[TimeSpan]::MaxValue` fails loudly instead, with an explicit "value out of range" error. The only form that reliably produces an indefinite repeating trigger is to **omit `-RepetitionDuration` entirely**. This is why the installer verifies both triggers exist right after registration — the failure mode here is completely silent otherwise, and you won't notice until you wonder why scheduled scripts "sometimes" don't run.
- **Session 0 isolation makes background testing misleading.** Any GUI program launched by a task running as `SYSTEM` (or via WMI process creation) runs in Session 0, with no desktop to attach to — the process exists and runs successfully, but you'll never see a window, even testing with something as simple as `notepad.exe` or `calc.exe` (which, on modern Windows, is itself a thin launcher for a UWP app that fails to activate outside an interactive session). Debugging this required checking the `SessionId` (`SI`) column of `Get-Process`, not just whether the process existed.

## License

MIT
