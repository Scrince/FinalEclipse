# Windows installer

Installs the PowerShell and batch scripts with documentation. The installer does not run the system hardening scripts.

Installer: `release/windows/FinalEclipse-Setup-1.0.0.exe`

SHA-256: `6ffabed6144b455b9f39579baf337345b0f3af8b913733510ce91feabd95d57d`

Detached OpenPGP signature: `release/windows/FinalEclipse-Setup-1.0.0.exe.asc`

This is a detached OpenPGP release signature, not a Windows Authenticode signature.

Public key: `docs/FinalEclipse_Release_Signing_2026_pubkey.asc`
Fingerprint: `2E2CF16213ECE2570406C1C0CE7A8F43AD8AF9D2`

Compare the fingerprint above before importing the key. From the project root:

```powershell
gpg --show-keys docs/FinalEclipse_Release_Signing_2026_pubkey.asc
gpg --import docs/FinalEclipse_Release_Signing_2026_pubkey.asc
gpg --verify release/windows/FinalEclipse-Setup-1.0.0.exe.asc release/windows/FinalEclipse-Setup-1.0.0.exe
gpg --verify release/windows/SHA256SUMS.asc release/windows/SHA256SUMS
```
