[CmdletBinding()]
param(
    [string]$ProjectRoot = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
    if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
        $ProjectRoot = $PSScriptRoot
    } else {
        $ProjectRoot = (Get-Location).Path
    }
}

$scriptPath = Join-Path $ProjectRoot 'FinalEclipse.ps1'
$readmePath = Join-Path $ProjectRoot 'README.md'
$testPath = Join-Path $ProjectRoot 'Tests\FinalEclipse.Static.Tests.ps1'

Write-Host "FinalEclipse release checks"
Write-Host "ProjectRoot: $ProjectRoot"

$tokens = $null
$errors = $null
[System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors) | Out-Null
if ($errors) {
    $errors | Format-List *
    throw "Parser check failed for $scriptPath"
}
Write-Host 'Parser check: OK'

$requiredText = @{
    'JSON audit log' = 'events.jsonl'
    'Backup manifest' = 'manifest.json'
    'GUI dry run' = '$chkDryRun'
    'Operation plan' = 'Format-OperationPlanText'
}
$scriptText = Get-Content -LiteralPath $scriptPath -Raw
$readmeText = Get-Content -LiteralPath $readmePath -Raw
foreach ($item in $requiredText.GetEnumerator()) {
    if ($scriptText -notlike "*$($item.Value)*" -and $readmeText -notlike "*$($item.Value)*") {
        throw "Missing release-safety marker: $($item.Key) ($($item.Value))"
    }
}
Write-Host 'Static safety markers: OK'

$pester = Get-Module -ListAvailable -Name Pester | Sort-Object Version -Descending | Select-Object -First 1
if ($pester -and (Test-Path -LiteralPath $testPath)) {
    Write-Host "Pester: running $($pester.Version)"
    Import-Module Pester -MinimumVersion $pester.Version -Force
    $result = Invoke-Pester -Path $testPath -PassThru
    if ($result.FailedCount -gt 0) {
        throw "Pester failed: $($result.FailedCount) failing test(s)"
    }
} else {
    Write-Host 'Pester: not installed; skipped optional Pester suite'
}

$signScript = Join-Path $ProjectRoot 'Sign-Release.ps1'
if (-not (Test-Path -LiteralPath $signScript)) {
    throw "Missing signing script: $signScript"
}
Write-Host 'Signing script present: OK'
Write-Host 'Release checks complete.'
