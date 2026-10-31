[CmdletBinding()]
param(
    [string]$ProjectRoot = '',
    [string]$ReleaseHome = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
    if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
        $ProjectRoot = $PSScriptRoot
    } elseif ($MyInvocation.MyCommand.Path) {
        $ProjectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
    } else {
        $ProjectRoot = 'T:\FinalEclipse'
    }
}

if ([string]::IsNullOrWhiteSpace($ReleaseHome)) {
    $ReleaseHome = Join-Path $ProjectRoot '.gnupg-release'
}
$releaseHome = $ReleaseHome
$fpr = '2E2CF16213ECE2570406C1C0CE7A8F43AD8AF9D2'

if (-not (Test-Path -LiteralPath $releaseHome)) {
    throw "Missing release GnuPG home: $releaseHome"
}

function Invoke-Gpg {
    param([Parameter(Mandatory)][string[]]$GpgArgs)
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & gpg @GpgArgs 2>&1 | ForEach-Object {
            if ($_ -is [System.Management.Automation.ErrorRecord]) {
                Write-Verbose $_.Exception.Message
            } else {
                Write-Verbose "$_"
            }
        }
        $code = $LASTEXITCODE
        if ($code -eq 0) {
            for ($i = 0; $i -lt ($GpgArgs.Count - 1); $i++) {
                if ($GpgArgs[$i] -eq '--output') {
                    Normalize-TextFileToLf -Path $GpgArgs[$i + 1]
                    break
                }
            }
        }
        return $code
    } finally {
        $ErrorActionPreference = $prevEap
    }
}

function Normalize-TextFileToLf {
    param([Parameter(Mandatory)][string]$Path)
    $text = [System.IO.File]::ReadAllText($Path)
    $text = [regex]::Replace($text, "`r`n|`r|`n", "`n")
    [System.IO.File]::WriteAllText($Path, $text, (New-Object System.Text.UTF8Encoding($false)))
}

$prevHome = $env:GNUPGHOME
$env:GNUPGHOME = $releaseHome
try {
    $secOut = & gpg --list-secret-keys --with-colons 2>$null | Out-String
    if ($secOut -notmatch [regex]::Escape($fpr)) {
        throw "Secret key $fpr not found in $releaseHome"
    }

    $files = @(
        (Join-Path $ProjectRoot 'FinalEclipse.ps1'),
        (Join-Path $ProjectRoot 'FinalEclipse.bat'),
        (Join-Path $ProjectRoot 'Test-Release.ps1'),
        (Join-Path $ProjectRoot 'Tests\FinalEclipse.Static.Tests.ps1'),
        (Join-Path $ProjectRoot 'README.md'),
        (Join-Path $ProjectRoot 'docs\GITHUB_RELEASE.md'),
        (Join-Path $ProjectRoot 'docs\WINDOWS_INSTALLER.md')
    )
    foreach ($f in $files) {
        if (-not (Test-Path -LiteralPath $f)) { continue }
        $asc = "$f.asc"
        if (Test-Path $asc) { Remove-Item -LiteralPath $asc -Force }
        $code = Invoke-Gpg -GpgArgs @('--batch','--yes','--local-user',$fpr,'--detach-sign','--armor','--output',$asc,'--',$f)
        if ($code -ne 0) { throw "gpg sign failed for $f (exit $code)" }
        Write-Host "Signed $f"
    }

    $pubDoc = Join-Path $ProjectRoot 'docs\FinalEclipse_Release_Signing_2026_pubkey.asc'
    New-Item -ItemType Directory -Path (Split-Path $pubDoc) -Force | Out-Null
    $pubText = & gpg --armor --export $fpr 2>$null | Out-String
    if ([string]::IsNullOrWhiteSpace($pubText)) { throw 'Failed to export public key' }
    Set-Content -Path $pubDoc -Value $pubText.TrimEnd() -Encoding ASCII
    Normalize-TextFileToLf -Path $pubDoc

    Push-Location $ProjectRoot
    try {
        $toHash = @(
            'FinalEclipse.ps1', 'FinalEclipse.ps1.asc',
            'FinalEclipse.bat', 'FinalEclipse.bat.asc',
            'Test-Release.ps1', 'Test-Release.ps1.asc',
            'Tests\FinalEclipse.Static.Tests.ps1', 'Tests\FinalEclipse.Static.Tests.ps1.asc',
            'README.md', 'README.md.asc',
            'docs\GITHUB_RELEASE.md', 'docs\GITHUB_RELEASE.md.asc',
            'docs\WINDOWS_INSTALLER.md', 'docs\WINDOWS_INSTALLER.md.asc',
            'docs\FinalEclipse_Release_Signing_2026_pubkey.asc'
        )
        $lines = foreach ($rel in $toHash) {
            if (-not (Test-Path -LiteralPath $rel)) { continue }
            $h = (Get-FileHash -LiteralPath $rel -Algorithm SHA256).Hash.ToLowerInvariant()
            "$h  $($rel -replace '\\', '/')"
        }
        $sumsPath = 'docs\SHA256SUMS'
        (($lines -join "`n") + "`n") | Set-Content -Path $sumsPath -Encoding ASCII -NoNewline
        Normalize-TextFileToLf -Path $sumsPath
        $sumsAsc = 'docs\SHA256SUMS.asc'
        if (Test-Path $sumsAsc) { Remove-Item -LiteralPath $sumsAsc -Force }
        $code = Invoke-Gpg -GpgArgs @('--batch','--yes','--local-user',$fpr,'--detach-sign','--armor','--output',$sumsAsc,'--',$sumsPath)
        if ($code -ne 0) { throw "gpg sign failed for SHA256SUMS (exit $code)" }
        Write-Host "Signed $sumsPath"
    } finally {
        Pop-Location
    }

    $installerDir = Join-Path $ProjectRoot 'release\windows'
    $issPath = Join-Path $ProjectRoot 'installer\FinalEclipse.iss'
    $issText = Get-Content -LiteralPath $issPath -Raw -ErrorAction Stop
    $versionMatch = [regex]::Match($issText, '(?m)^#define\s+MyAppVersion\s+"([^"]+)"')
    if (-not $versionMatch.Success) { throw "Could not read MyAppVersion from $issPath" }
    $installerName = "FinalEclipse-Setup-$($versionMatch.Groups[1].Value).exe"
    $installerPath = Join-Path $installerDir $installerName
    if (-not (Test-Path -LiteralPath $installerPath)) {
        throw "Build the current installer first: $installerPath"
    }
    $installerSignature = "$installerPath.asc"
    $code = Invoke-Gpg -GpgArgs @('--batch','--yes','--local-user',$fpr,'--detach-sign','--armor','--output',$installerSignature,'--',$installerPath)
    if ($code -ne 0) { throw "gpg sign failed for $installerName (exit $code)" }
    $installerHash = (Get-FileHash -LiteralPath $installerPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $installerSums = Join-Path $installerDir 'SHA256SUMS'
    "$installerHash  $installerName`n" | Set-Content -LiteralPath $installerSums -Encoding ASCII -NoNewline
    Normalize-TextFileToLf -Path $installerSums
    $installerSumsSignature = "$installerSums.asc"
    $code = Invoke-Gpg -GpgArgs @('--batch','--yes','--local-user',$fpr,'--detach-sign','--armor','--output',$installerSumsSignature,'--',$installerSums)
    if ($code -ne 0) { throw "gpg sign failed for $installerSums (exit $code)" }
    Write-Host "Signed $installerName and rebuilt $installerSums"

    Write-Host "Done (GNUPGHOME=$releaseHome)"
} finally {
    & gpgconf --kill all 2>$null | Out-Null
    if ([string]::IsNullOrWhiteSpace($prevHome)) {
        Remove-Item Env:GNUPGHOME -ErrorAction SilentlyContinue
    } else {
        $env:GNUPGHOME = $prevHome
    }
}
