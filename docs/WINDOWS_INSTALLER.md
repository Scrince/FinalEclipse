# Windows installer

The `1.0.1` installer is built from the current source files. The older `1.0.0`
installer is retained as a historical artifact and does not include these changes.

Installs the PowerShell and batch scripts with documentation. The installer does not run the system hardening scripts.

Installer: `release/windows/FinalEclipse-Setup-1.0.1.exe`

SHA-256: see `release/windows/SHA256SUMS`

Detached OpenPGP signature: `release/windows/FinalEclipse-Setup-1.0.1.exe.asc`

This is a detached OpenPGP release signature, not a Windows Authenticode signature.

Public key: `docs/FinalEclipse_Release_Signing_2026_pubkey.asc`
Fingerprint: `2E2CF16213ECE2570406C1C0CE7A8F43AD8AF9D2`

Compare the fingerprint above before importing the key. From the project root:

```powershell
gpg --show-keys docs/FinalEclipse_Release_Signing_2026_pubkey.asc
gpg --import docs/FinalEclipse_Release_Signing_2026_pubkey.asc
gpg --verify release/windows/FinalEclipse-Setup-1.0.1.exe.asc release/windows/FinalEclipse-Setup-1.0.1.exe
gpg --verify release/windows/SHA256SUMS.asc release/windows/SHA256SUMS
```

Build the installer after updating `installer/FinalEclipse.iss` with the release
version:

```powershell
ISCC.exe .\installer\FinalEclipse.iss
```

Then run `Sign-Release.ps1` to sign the installer and regenerate both checksum
manifests.
