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
            'Restore-ServiceFailureConfig',
            'Convert-QFailureTextToScArgs',
            'Get-TaskBackupState',
            'Restore-TaskBackupState',
            'Format-OperationPlanText',
            'Format-EnvironmentReportText',
            'Export-RegistryBackup',
            'Restore-LatestRegistryBackup',
            'Invoke-UninstallAll',
            'Stop-FinalEclipseMonitorProcesses',
            'Remove-FinalEclipseAppData'
        ) | ForEach-Object {
            ($functions -contains $_) | Should Be $true
        }
    }

    It 'declares UninstallAll and RemoveAppData switches' {
        $text = Get-Content -LiteralPath $scriptPath -Raw
        $text | Should Match '\[switch\]\$UninstallAll'
        $text | Should Match '\[switch\]\$RemoveAppData'
        $text | Should Match 'Invoke-UninstallAll'
        $text | Should Match "Uninstall all"
    }

    It 'stores and restores service recovery (qfailure) from the manifest' {
        $text = Get-Content -LiteralPath $scriptPath -Raw
        $text | Should Match 'FailureConfig'
        $text | Should Match 'sc\.exe qfailure|qfailure'
        $text | Should Match 'Restore-ServiceFailureConfig'
        $text | Should Match 'ServiceRecoveryQueryNote'
    }

    It 'fails protected task installation when the payload ACL cannot be secured' {
        $text = Get-Content -LiteralPath $scriptPath -Raw
        $text | Should Match 'function Set-ProtectedPathAcl'
        $text | Should Match 'Set-ProtectedPathAcl -Path \$appRoot'
        $text | Should Match 'Set-ProtectedPathAcl -Path \$destDir'
        $text | Should Match 'Set-ProtectedPathAcl -Path \$dest'
        $text | Should Match 'Set-ProtectedPathAcl -Path \$hashPath'
        $text | Should Match 'AreAccessRulesProtected'
    }

    It 'requires at least one hashed registry export for a successful backup' {
        $text = Get-Content -LiteralPath $scriptPath -Raw
        $text | Should Match 'No registry sources were exported'
        $text | Should Match 'Success = \(\$failed.Count -eq 0 -and \$fileHashes.Count -gt 0\)'
    }

    It 'records restore outcome and individual registry or manifest failures' {
        $text = Get-Content -LiteralPath $scriptPath -Raw
        $text | Should Match 'backup-restored-\$restoreStatus'
        $text | Should Match 'registryRestored = @\(\$registryRestored\)'
        $text | Should Match 'manifestRestored = @\(\$manifestRestored\)'
        $text | Should Match 'restoreFailures \+= "registry file'
        $text | Should Match 'restoreFailures \+= "\$\{target\}:'
        $preflightIndex = $text.IndexOf('$verifiedFiles = @()')
        $importIndex = $text.IndexOf("Start-Process -FilePath 'reg.exe' -ArgumentList @('import', `$full)")
        ($preflightIndex -ge 0 -and $importIndex -gt $preflightIndex) | Should Be $true
    }

    It 'soft-fails when services or tasks are missing' {
        $text = Get-Content -LiteralPath $scriptPath -Raw
        $text | Should Match 'soft-fail skip'
        $text | Should Match 'Service not installed; soft-fail skip'
        $text | Should Match 'Scheduled task not installed; soft-fail skip'
    }

    It 'exposes UninstallAll in the parameter block AST' {
        $paramBlock = $ast.ParamBlock
        $names = @($paramBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
        ($names -contains 'UninstallAll') | Should Be $true
        ($names -contains 'RemoveAppData') | Should Be $true
        ($names -contains 'UninstallTask') | Should Be $true
        ($names -contains 'RestoreLatestBackup') | Should Be $true
    }

    It 'documents JSON audit logging, backup manifests, uninstall, and compatibility' {
        $readme = Get-Content -LiteralPath $readmePath -Raw
        $readme | Should Match 'events\.jsonl'
        $readme | Should Match 'manifest\.json'
        $readme | Should Match 'Uninstall all'
        $readme | Should Match 'RemoveAppData'
        $readme | Should Match 'Soft-fail'
        $readme | Should Match 'Windows Version Compatibility'
        $readme | Should Match 'FailureConfig'
        $readme | Should Match 'MachineGuid'
        $readme | Should Match 'Out-of-scope'
    }
}
