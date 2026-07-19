# FinalEclipse Release Draft

## Title

FinalEclipse GDID hardening with live monitor and drift reporting

## Summary

This release expands FinalEclipse from one-shot local GDID cleanup into a lean
hardening and monitoring tool. It now includes service recovery hardening, curated
scheduled task audit/disable support, monitor task health checks, and drift reports
that show when local identity traces or persistence settings reappear.

## Highlights

- Added **Advanced harden** action.
- Added service recovery reset for watched services.
- Added curated scheduled task audit and disable pass.
- Added **Task audit** view for known telemetry/feedback/data collection tasks.
- Added **Task health** view for the `FinalEclipse-Monitor` logon task.
- Added GUI **Dry run**, operation plan prompts, **Restore latest**, and
  **Environment** views.
- Added JSONL audit logging at `%ProgramData%\FinalEclipse\Logs\events.jsonl`.
- Added backup `manifest.json` with environment, service, and task state.
- Added `Test-Release.ps1` and optional Pester static checks.
- Added **Drift report** baseline comparison under
  `%ProgramData%\FinalEclipse\State\last-snapshot.json`.
- Extended `Full harden` to include the advanced hardening pass.
- Extended the live monitor to periodically re-clear watched service recovery
  actions.
- Added CLI switches: `-AdvancedHarden`, `-TaskHealth`, and `-DriftReport`.
- Refreshed README coverage for verification, limitations, and release signing.

## Suggested Assets

Upload these files to the GitHub release:

- `FinalEclipse.ps1`
- `FinalEclipse.ps1.asc`
- `FinalEclipse.bat`
- `FinalEclipse.bat.asc`
- `Test-Release.ps1`
- `Test-Release.ps1.asc`
- `Tests/FinalEclipse.Static.Tests.ps1`
- `Tests/FinalEclipse.Static.Tests.ps1.asc`
- `README.md`
- `README.md.asc`
- `docs/FinalEclipse_Release_Signing_2026_pubkey.asc`
- `docs/SHA256SUMS`
- `docs/SHA256SUMS.asc`

## Verification

```bash
gpg --show-keys docs/FinalEclipse_Release_Signing_2026_pubkey.asc
gpg --import docs/FinalEclipse_Release_Signing_2026_pubkey.asc
gpg --verify FinalEclipse.ps1.asc FinalEclipse.ps1
gpg --verify FinalEclipse.bat.asc FinalEclipse.bat
gpg --verify Test-Release.ps1.asc Test-Release.ps1
gpg --verify Tests/FinalEclipse.Static.Tests.ps1.asc Tests/FinalEclipse.Static.Tests.ps1
gpg --verify README.md.asc README.md
gpg --verify docs/SHA256SUMS.asc docs/SHA256SUMS
```

Expected fingerprint:

```text
Primary: 2E2C F162 13EC E257 0406 C1C0 CE7A 8F43 AD8A F9D2
Signing subkey: EBD3 817D EEA9 356D CE76 ABA8 6BAF DFAB F5F9 A1FA
Encryption subkey: 64A6 668A 61F5 760A BB0D 1E1B 88DB E7EE 626F 9545
```

## Release Checklist

- Run PowerShell parser check on `FinalEclipse.ps1`.
- Run `.\Test-Release.ps1` from the project root.
- Run `.\Sign-Release.ps1` from the project root.
- Verify detached signatures from `.gnupg-release`.
- Verify every entry in `docs/SHA256SUMS`.
- Confirm `.gnupg-release\` is not uploaded or committed.
- Confirm the GitHub release assets match `docs/SHA256SUMS`.

## Notes

FinalEclipse only affects local Windows traces and local re-registration paths. It
does not erase Microsoft server-side account or device history, hardware
fingerprints, IP history, browser fingerprints, or every possible system
identifier.
