# FinalEclipse

FinalEclipse is a Windows privacy hardening tool for local Global Device Identifier
(GDID) traces. It scans known local identity locations, backs them up, disables the
services and policies that commonly recreate them, and can run a live monitor that
keeps removing IDs if Windows brings them back.

The tool is intended for systems you own or administer.

## What It Does

- Scans local IdentityCRL, IdentityStore, IrisService, Connected Devices Platform,
  advertising ID, service state, monitor task health, and known telemetry task
  state.
- Exports registry backups before destructive hardening actions.
- Disables Connected Devices Platform and selected telemetry-related services.
- Clears service recovery actions that could restart watched services.
- Turns off Activity History and the local advertising ID.
- Removes local PUID, DeviceId, GlobalDeviceId, IrisService, and CDP cache data.
- Disables a curated set of telemetry scheduled tasks.
- Generates drift reports against the previous scan baseline.
- Runs an optional watchdog monitor that repeats the hardening checks on an
  interval.
- Can install that monitor as an elevated logon scheduled task.

## Requirements

- Windows PowerShell 5.1
- Administrator rights
- Windows desktop session for the GUI
- GnuPG only if you need to verify or recreate release signatures

## Files

| Path | Purpose |
| --- | --- |
| `FinalEclipse.bat` | Double-click launcher for the PowerShell app |
| `FinalEclipse.ps1` | Main GUI, CLI, monitor, backup, and hardening script |
| `Sign-Release.ps1` | Recreates detached signatures and checksum manifest |
| `README.md` | This guide |
| `*.asc` | Detached ASCII-armored PGP signatures for release files |
| `docs/FinalEclipse_Release_Signing_2026_pubkey.asc` | Public release-signing key |
| `docs/SHA256SUMS` | SHA-256 checksum manifest |
| `docs/SHA256SUMS.asc` | Detached signature for the checksum manifest |
| `docs/GITHUB_RELEASE.md` | Draft GitHub release text and asset checklist |
| `docs/GITHUB_RELEASE.md.asc` | Detached signature for the GitHub release draft |

## Quick Start

Run the launcher from an elevated prompt or double-click it and approve UAC:

```powershell
.\FinalEclipse.bat
```

Recommended first pass:

1. Click **Scan** to inspect current local identity state.
2. Click **Backup** to export the relevant registry areas.
3. Click **Full harden** to back up, disable the pipeline, run advanced hardening,
   clear caches, and wipe local device ID values.
4. Click **Start live monitor** to keep the local values from reappearing during
   the current session.
5. Use **Install logon task** if you want the monitor to start automatically at
   sign-in.

## Command Line

```powershell
# Open the GUI
.\FinalEclipse.bat

# Run the headless monitor every 5 seconds
.\FinalEclipse.bat -Monitor

# Run the headless monitor with a custom interval
.\FinalEclipse.bat -Monitor -IntervalSeconds 10

# Install or remove the elevated logon monitor task
.\FinalEclipse.bat -InstallTask
.\FinalEclipse.bat -UninstallTask

# Run advanced hardening without opening the GUI
.\FinalEclipse.bat -AdvancedHarden

# Print monitor task health
.\FinalEclipse.bat -TaskHealth

# Print a drift report and update the baseline
.\FinalEclipse.bat -DriftReport
```

The interval is clamped between 2 seconds and 3600 seconds.

## GUI Actions

| Action | Effect |
| --- | --- |
| **Scan** | Shows local PUID/GDID-related values, CDP folder status, service state, MachineGuid, advertising ID, monitor task health, and known task count |
| **Backup** | Exports selected registry trees and writes a text snapshot under `%ProgramData%\FinalEclipse\Backups` |
| **Disable pipeline** | Stops and disables CDP, CDPUserSvc instances, DiagTrack, and dmwappushservice; clears recovery actions; reapplies privacy policies |
| **Clear caches** | Deletes IrisService registry cache and the local ConnectedDevicesPlatform folder |
| **Wipe local PUID** | Removes local IdentityCRL and IdentityStore device ID values |
| **Full harden** | Runs backup, pipeline disable, advanced hardening, cache clearing, and local PUID wipe |
| **Start live monitor** | Starts the watchdog inside the GUI session |
| **Stop monitor** | Stops the GUI watchdog |
| **Install logon task** | Registers `FinalEclipse-Monitor` to run elevated at logon |
| **Remove logon task** | Removes the scheduled task if present |
| **Advanced harden** | Clears watched service recovery actions, disables curated telemetry tasks, reapplies policies, and checks monitor task health |
| **Task audit** | Displays the curated scheduled task list and current state |
| **Drift report** | Compares the current scan to the previous baseline, then updates the baseline |
| **Task health** | Shows whether the logon monitor task is installed, enabled, elevated, and pointing to this script |

## Live Monitor

The monitor repeats these checks on each interval:

- Stops and disables `CDPSvc`, `CDPUserSvc*`, `DiagTrack`, and
  `dmwappushservice` if they start again or leave the Disabled startup state.
- Removes reappearing `LID`, `DeviceId`, and `GlobalDeviceId` values from the
  watched identity registry areas.
- Deletes re-created IrisService and ConnectedDevicesPlatform local caches.
- Periodically reapplies Activity History, telemetry, and advertising ID policies.
- Periodically clears recovery actions on watched services.

Only one monitor instance is allowed at a time. If another GUI or headless monitor
is already running, a new monitor exits instead of competing with it.

## Advanced Hardening

Advanced hardening stays intentionally narrow. It only modifies known service and
task surfaces related to telemetry, compatibility, feedback, CDP, or device data
collection.

It currently covers:

- Service recovery actions for `CDPSvc`, `CDPUserSvc*`, `DiagTrack`, and
  `dmwappushservice`
- Activity History, telemetry, and advertising ID policies
- Curated scheduled tasks under Application Experience, Autochk, Customer
  Experience Improvement Program, DiskDiagnostic, and Feedback
- FinalEclipse monitor task health checks

The task audit is visible before or after hardening so you can see exactly which
known tasks exist on a given Windows build.

## Drift Reports

Drift reports compare the current scan against the previous baseline stored at:

```text
%ProgramData%\FinalEclipse\State\last-snapshot.json
```

The report highlights re-created IDs, changed service state, changed CDP cache
presence, changed monitor task health, and changed known task counts. Each report
updates the baseline after it is generated.

## Backups And Logs

Backups are written to timestamped folders:

```text
%ProgramData%\FinalEclipse\Backups\
```

Monitor logs are written here:

```text
%ProgramData%\FinalEclipse\Logs\monitor.log
```

The log rotates when it reaches 2 MB and keeps the five most recent rotated logs.

## Important Limits

FinalEclipse only targets local Windows traces and local re-registration paths. It
does not erase Microsoft server-side account or device history, and it does not
remove every possible fingerprint on a system.

Examples of data outside this tool's scope include:

- Microsoft server-side GDID or account history
- Hardware identifiers
- IP address history
- Browser and app fingerprints
- `MachineGuid`
- Account identifiers

Some Microsoft account and device experiences may re-register local identifiers if
the monitor is stopped or if related Windows components are re-enabled later.

## Verify A Release

The release-signing public key is:

```text
docs/FinalEclipse_Release_Signing_2026_pubkey.asc
```

Expected key identity:

```text
FinalEclipse Release Signing (2026) <release@finaleclipse.local>
Fingerprint: 2E2C F162 13EC E257 0406 C1C0 CE7A 8F43 AD8A F9D2
Primary RSA-4096 signing key only; no subkeys
```

Inspect the key before trusting it:

```bash
gpg --show-keys docs/FinalEclipse_Release_Signing_2026_pubkey.asc
```

Import the key and verify release artifacts:

```bash
gpg --import docs/FinalEclipse_Release_Signing_2026_pubkey.asc
gpg --verify FinalEclipse.ps1.asc FinalEclipse.ps1
gpg --verify FinalEclipse.bat.asc FinalEclipse.bat
gpg --verify README.md.asc README.md
gpg --verify docs/GITHUB_RELEASE.md.asc docs/GITHUB_RELEASE.md
gpg --verify docs/SHA256SUMS.asc docs/SHA256SUMS
```

You can also compare file hashes against:

```text
docs/SHA256SUMS
```

## Re-Signing A Local Release

Release signing uses an isolated project-local GnuPG home:

```text
.gnupg-release\
```

That directory contains secret key material and must remain private.

To recreate signatures and checksums:

```powershell
.\Sign-Release.ps1
```

The script signs `FinalEclipse.ps1`, `FinalEclipse.bat`, `README.md`, and
`docs/GITHUB_RELEASE.md`, exports the public key, rebuilds `docs/SHA256SUMS`, and
signs the manifest.

## Responsible Use

Use FinalEclipse only on machines you own or are authorized to administer. Make a
backup before hardening, review the scan output before sharing screenshots, and
expect Windows updates or account changes to require another scan.
