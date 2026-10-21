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
- Shows a dry-run and operation plan before destructive GUI actions.
- Writes both human-readable logs and JSONL audit events.
- Stores backup manifests with service, task, and environment state.

## Requirements

- Windows PowerShell 5.1
- Administrator rights
- Windows desktop session for the GUI
- GnuPG only if you need to verify or recreate release signatures

## Windows Version Compatibility

| Area | Windows 10 | Windows 11 | Notes |
| --- | --- | --- | --- |
| PowerShell 5.1 host | Supported | Supported | Primary runtime; Windows PowerShell, not PowerShell 7-only syntax |
| Watched services (`CDPSvc`, `DiagTrack`, `dmwappushservice`, `CDPUserSvc*`) | Present on most SKUs | Present on most SKUs | Home/Pro/Enterprise may differ; some IoT/Server SKUs omit consumer services |
| Curated telemetry scheduled tasks | Names generally stable | Names generally stable | Builds may omit individual tasks under Application Experience, CEIP, Feedback, DiskDiagnostic |
| Logon task `FinalEclipse-Monitor` | Supported | Supported | Registered with elevated interactive principal at logon; task name is stable across 10/11 |
| Service recovery (`sc.exe qfailure` / `failure`) | Supported | Supported | Captured into backup manifest `Services[].FailureConfig` for restore |
| GUI (WinForms) | Supported | Supported | Requires a desktop session |

### Soft-fail philosophy

FinalEclipse treats missing services and missing curated tasks as **soft failures**, not hard errors:

- If a watched service is not installed, disable/recovery/restore steps log a clear line such as `Service not installed; soft-fail skip...` and continue.
- If a known telemetry task path is not present on the build, disable/restore logs `Scheduled task not installed; soft-fail skip...` and continues.
- Hardening, monitor ticks, and uninstall therefore complete on SKUs where Microsoft already removed a component.

Only integrity and operator-required steps (for example a missing backup during Full harden, hash mismatch on restore, or failed task health after install) remain hard failures.

## Files

| Path | Purpose |
| --- | --- |
| `FinalEclipse.bat` | Double-click launcher for the PowerShell app |
| `FinalEclipse.ps1` | Main GUI, CLI, monitor, backup, and hardening script |
| `Sign-Release.ps1` | Recreates detached signatures and checksum manifest |
| `Test-Release.ps1` | Runs parser, static safety, and optional Pester release checks |
| `Tests/FinalEclipse.Static.Tests.ps1` | Optional Pester static test suite |
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
3. Turn on **Dry run** if you want to preview changes without applying them.
4. Click **Full harden** to back up, disable the pipeline, run advanced hardening,
   clear caches, and wipe local device ID values.
5. Click **Start live monitor** to keep the local values from reappearing during
   the current session.
6. Use **Install logon task** if you want the monitor to start automatically at
   sign-in.

## Command Line

```powershell
.\FinalEclipse.bat

.\FinalEclipse.bat -Monitor

.\FinalEclipse.bat -Monitor -IntervalSeconds 10

.\FinalEclipse.bat -InstallTask
.\FinalEclipse.bat -UninstallTask

.\FinalEclipse.bat -UninstallAll
.\FinalEclipse.bat -UninstallAll -RemoveAppData

.\FinalEclipse.bat -AdvancedHarden

.\FinalEclipse.bat -AdvancedHarden -WhatIf

.\FinalEclipse.bat -TaskHealth

.\FinalEclipse.bat -DriftReport

.\FinalEclipse.bat -RestoreLatestBackup

.\Test-Release.ps1
```

The interval is clamped between 2 seconds and 3600 seconds.

### Uninstall all

`-UninstallAll` (GUI: **Uninstall all**) removes the `FinalEclipse-Monitor` logon task and stops any running FinalEclipse monitor process for this script.

- By default it does **not** delete `%ProgramData%\FinalEclipse` data. The CLI prompts whether to remove backups, logs, state, and the protected script copy; pass `-RemoveAppData` to delete that data without a prompt. The GUI asks with a Yes/No/Cancel dialog.
- Uninstall all does **not** re-enable telemetry services, curated tasks, or privacy policies. To reverse hardening:
  1. Prefer **Restore latest** / `-RestoreLatestBackup` if you created a backup before hardening (restores registry exports plus manifest-backed service startup types, recovery actions when stored, and task enablement).
  2. Or manually re-enable services (for example `DiagTrack`), re-enable known telemetry tasks, and adjust policies under `HKLM\SOFTWARE\Policies\Microsoft\Windows\DataCollection`, `...\System` (Activity History), and `HKCU\...\AdvertisingInfo`.

## GUI Actions

| Action | Effect |
| --- | --- |
| **Scan** | Shows local PUID/GDID-related values, CDP folder status, service state, MachineGuid, advertising ID, monitor task health, and known task count |
| **Dry run** | Previews supported hardening, restore, task, and wipe changes without applying them |
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
| **Restore latest** | Imports the newest registry backup and restores manifest-backed service startup types, recovery actions (when stored), and task enablement |
| **Environment** | Shows Windows, PowerShell, path, log, and admin context for support and compatibility checks |
| **Uninstall all** | Removes `FinalEclipse-Monitor`, stops the monitor, optionally deletes `%ProgramData%\FinalEclipse` data; does not re-enable telemetry |

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
is already running, a new monitor exits instead of competing with it. The GUI
starts its live monitor as a hidden child PowerShell process so watchdog work does
not block the window.

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
updates the baseline after it is generated. Baseline updates are written through a
temporary file and then moved into place to avoid leaving partial JSON behind.

## Backups And Logs

Backups are written to timestamped folders:

```text
%ProgramData%\FinalEclipse\Backups\
```

Each backup includes registry exports, `snapshot.txt`, and `manifest.json`. The
manifest records the app versioned backup format, script path, environment,
watched service startup state, service recovery query output (`sc.exe qfailure`
text in each `Services[].FailureConfig` entry), known telemetry task state, and
registry export results.

`Full harden` stops before making destructive changes if the backup step is
incomplete. Use `-RestoreLatestBackup` or **Restore latest** to import the newest
`.reg` files from the backup folder (SHA-256 bound via the manifest). When
`manifest.json` is present, restore also attempts to reapply:

- Captured service startup types
- Service recovery actions parsed from stored `FailureConfig` / `sc.exe qfailure` text
- Scheduled task enabled/disabled states for the curated list

### Restore limits

- If `FailureConfig` is missing, empty, or unparseable (older backups or failed
  `qfailure` capture), recovery actions are **not** rebuilt; only startup type is
  restored for that service. Create a new backup with this version to capture
  recovery for future restores.
- Deleted IrisService registry trees and ConnectedDevicesPlatform folder contents
  are not reconstructed from the backup (only registry `.reg` exports that were
  successfully hashed into the manifest are imported).
- Missing services or tasks on the current machine soft-fail with log lines and do
  not abort the rest of restore.

Monitor logs are written here:

```text
%ProgramData%\FinalEclipse\Logs\monitor.log
```

Machine-readable audit events are written here:

```text
%ProgramData%\FinalEclipse\Logs\events.jsonl
```

The text log rotates at 2 MB and the JSONL audit log rotates at 4 MB. Both keep
the five most recent rotated logs.

## Release Checks

Run the release checks before signing:

```powershell
.\Test-Release.ps1
```

The check script validates PowerShell syntax, verifies expected safety markers,
and runs the optional Pester suite when Pester is installed.

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

### Out-of-scope note (GUI and elsewhere)

The GUI **Scan** view may display `MachineGuid` and other related IDs for
operator awareness. Displaying a value does **not** mean FinalEclipse wipes or
rotates it. `MachineGuid`, server-side GDID/account history, and similar
identifiers are intentionally out of scope: they are not cleared by Full harden,
Wipe local PUID, Clear caches, or the live monitor. Do not treat a scan field as
an action target unless the corresponding button or CLI switch documents that
change.

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
Primary fingerprint: 2E2C F162 13EC E257 0406 C1C0 CE7A 8F43 AD8A F9D2
Signing subkey: EBD3 817D EEA9 356D CE76 ABA8 6BAF DFAB F5F9 A1FA
Encryption subkey: 64A6 668A 61F5 760A BB0D 1E1B 88DB E7EE 626F 9545
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
gpg --verify Test-Release.ps1.asc Test-Release.ps1
gpg --verify Tests/FinalEclipse.Static.Tests.ps1.asc Tests/FinalEclipse.Static.Tests.ps1
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

The script signs `FinalEclipse.ps1`, `FinalEclipse.bat`, `Test-Release.ps1`,
`Tests/FinalEclipse.Static.Tests.ps1`, `README.md`, and
`docs/GITHUB_RELEASE.md`, exports the public key, rebuilds `docs/SHA256SUMS`,
and signs the manifest.

## Responsible Use

Use FinalEclipse only on machines you own or are authorized to administer. Make a
backup before hardening, review the scan output before sharing screenshots, and
expect Windows updates or account changes to require another scan.

## Windows installer

See [Windows installer and signature verification](docs/WINDOWS_INSTALLER.md) for the download path and verification steps.
