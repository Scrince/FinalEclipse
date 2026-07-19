[CmdletBinding()]
param(
    [string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot)
)

$scriptPath = Join-Path $ProjectRoot 'FinalEclipse.ps1'
$readmePath = Join-Path $ProjectRoot 'README.md'
$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors)

Describe 'FinalEclipse static checks' {
    It 'parses without syntax errors' {
        @($errors).Count | Should Be 0
    }

    It 'keeps WhatIf support enabled' {
        $text = Get-Content -LiteralPath $scriptPath -Raw
        $text | Should Match 'SupportsShouldProcess\s*=\s*\$true'
        $text | Should Match '\$chkDryRun'
    }

    It 'contains the expected release-safety functions' {
        $functions = @($ast.FindAll({ param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
        }, $true) | Select-Object -ExpandProperty Name)

        @(
            'Write-AuditEvent',
            'Get-ServiceBackupState',
            'Restore-ServiceBackupState',
            'Get-TaskBackupState',
            'Restore-TaskBackupState',
            'Format-OperationPlanText',
            'Format-EnvironmentReportText',
            'Export-RegistryBackup',
            'Restore-LatestRegistryBackup'
        ) | ForEach-Object {
            ($functions -contains $_) | Should Be $true
        }
    }

    It 'documents JSON audit logging and backup manifests' {
        $readme = Get-Content -LiteralPath $readmePath -Raw
        $readme | Should Match 'events\.jsonl'
        $readme | Should Match 'manifest\.json'
    }
}
