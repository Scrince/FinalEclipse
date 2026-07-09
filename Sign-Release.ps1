[CmdletBinding()]
param(
    [string]$ProjectRoot = ''
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

$releaseHome = Join-Path $ProjectRoot '.gnupg-release'
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
        return $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prevEap
    }
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
        (Join-Path $ProjectRoot 'README.md'),
        (Join-Path $ProjectRoot 'docs\GITHUB_RELEASE.md')
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

    Push-Location $ProjectRoot
    try {
        $toHash = @(
            'FinalEclipse.ps1', 'FinalEclipse.ps1.asc',
            'FinalEclipse.bat', 'FinalEclipse.bat.asc',
            'README.md', 'README.md.asc',
            'docs\GITHUB_RELEASE.md', 'docs\GITHUB_RELEASE.md.asc',
            'docs\FinalEclipse_Release_Signing_2026_pubkey.asc'
        )
        $lines = foreach ($rel in $toHash) {
            if (-not (Test-Path -LiteralPath $rel)) { continue }
            $h = (Get-FileHash -LiteralPath $rel -Algorithm SHA256).Hash.ToLowerInvariant()
            "$h  $($rel -replace '\\', '/')"
        }
        $sumsPath = 'docs\SHA256SUMS'
        (($lines -join "`n") + "`n") | Set-Content -Path $sumsPath -Encoding ASCII -NoNewline
        $sumsAsc = 'docs\SHA256SUMS.asc'
        if (Test-Path $sumsAsc) { Remove-Item -LiteralPath $sumsAsc -Force }
        $code = Invoke-Gpg -GpgArgs @('--batch','--yes','--local-user',$fpr,'--detach-sign','--armor','--output',$sumsAsc,'--',$sumsPath)
        if ($code -ne 0) { throw "gpg sign failed for SHA256SUMS (exit $code)" }
        Write-Host "Signed $sumsPath"
    } finally {
        Pop-Location
    }

    Write-Host "Done (GNUPGHOME=$releaseHome)"
} finally {
    & gpgconf --kill all 2>$null | Out-Null
    if ([string]::IsNullOrWhiteSpace($prevHome)) {
        Remove-Item Env:GNUPGHOME -ErrorAction SilentlyContinue
    } else {
        $env:GNUPGHOME = $prevHome
    }
}
