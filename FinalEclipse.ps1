[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [switch]$Monitor,
    [int]$IntervalSeconds = 5,
    [switch]$InstallTask,
    [switch]$UninstallTask,
    [switch]$AdvancedHarden,
    [switch]$DriftReport,
    [switch]$TaskHealth,
    [switch]$RestoreLatestBackup,
    [string]$RelaunchOutputPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-IsAdmin)) {
    $isCliMode = $Monitor -or $InstallTask -or $UninstallTask -or $AdvancedHarden -or
        $DriftReport -or $TaskHealth -or $RestoreLatestBackup
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    if ($Monitor)         { $argList += '-Monitor' }
    if ($InstallTask)     { $argList += '-InstallTask' }
    if ($UninstallTask)   { $argList += '-UninstallTask' }
    if ($AdvancedHarden)  { $argList += '-AdvancedHarden' }
    if ($DriftReport)     { $argList += '-DriftReport' }
    if ($TaskHealth)      { $argList += '-TaskHealth' }
    if ($RestoreLatestBackup) { $argList += '-RestoreLatestBackup' }
    if ($WhatIfPreference) { $argList += '-WhatIf' }
    if ($PSBoundParameters.ContainsKey('IntervalSeconds')) {
        $argList += @('-IntervalSeconds', "$IntervalSeconds")
    }
    $relayPath = $null
    if ($isCliMode) {
        $relayPath = [System.IO.Path]::GetTempFileName()
        $argList += @('-RelaunchOutputPath', "`"$relayPath`"")
    }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName  = 'powershell.exe'
    $psi.Arguments = ($argList -join ' ')
    $psi.Verb      = 'runas'
    $psi.UseShellExecute = $true
    $psi.WorkingDirectory = Split-Path -Parent $PSCommandPath
    try {
        $p = [Diagnostics.Process]::Start($psi)
        if ($isCliMode -and $null -ne $p) {
            $p.WaitForExit()
            if ($relayPath -and (Test-Path -LiteralPath $relayPath)) {
                $relayText = Get-Content -LiteralPath $relayPath -Raw -ErrorAction SilentlyContinue
                if (-not [string]::IsNullOrEmpty($relayText)) {
                    Write-Host $relayText -NoNewline
                }
                Remove-Item -LiteralPath $relayPath -Force -ErrorAction SilentlyContinue
            }
            exit $p.ExitCode
        }
    } catch {
        Write-Host 'Administrator rights are required. Relaunch declined.' -ForegroundColor Yellow
        if ($relayPath -and (Test-Path -LiteralPath $relayPath)) {
            Remove-Item -LiteralPath $relayPath -Force -ErrorAction SilentlyContinue
        }
        exit 1
    }
    exit 0
}

$script:AppName     = 'FinalEclipse'
$script:BackupRoot  = Join-Path $env:ProgramData 'FinalEclipse\Backups'
$script:LogDir      = Join-Path $env:ProgramData 'FinalEclipse\Logs'
$script:StateDir    = Join-Path $env:ProgramData 'FinalEclipse\State'
$script:LogFile     = Join-Path $script:LogDir 'monitor.log'
$script:JsonLogFile = Join-Path $script:LogDir 'events.jsonl'
$script:DriftPath   = Join-Path $script:StateDir 'last-snapshot.json'
$script:TaskName    = 'FinalEclipse-Monitor'
$script:MonitorRunning = $false
$script:WatchdogTick = 0
$script:SuppressUiLog = $false
$script:LogRateLimit = @{}
$script:Mutex = $null
$script:MutexName = 'Global\FinalEclipse-Monitor-Singleton'
$script:LogMutexName = 'Global\FinalEclipse-Log-Writer'
$script:AuditMutexName = 'Global\FinalEclipse-Audit-Writer'
$script:txtLog = $null
$script:WatchdogBusy = $false
$script:MonitorProcess = $null
$script:MaxLogBytes = 2MB
$script:MaxJsonLogBytes = 4MB
$script:MaxUiLogChars = 120000
$script:BackupManifestVersion = 2
$script:RelaunchOutputPath = $RelaunchOutputPath

if ($IntervalSeconds -lt 2) { $IntervalSeconds = 2 }
if ($IntervalSeconds -gt 3600) { $IntervalSeconds = 3600 }

function Write-CliHost {
    param([AllowNull()][object]$Object)
    $text = if ($null -eq $Object) { '' } else { "$Object" }
    if (-not [string]::IsNullOrWhiteSpace($script:RelaunchOutputPath)) {
        try {
            Add-Content -LiteralPath $script:RelaunchOutputPath -Value $text -Encoding UTF8 -ErrorAction Stop
        } catch {
            Write-Verbose "Relaunch output relay failed: $($_.Exception.Message)"
        }
    }
    Write-Host $text
}

$IdentityExtProps  = 'HKCU:\SOFTWARE\Microsoft\IdentityCRL\ExtendedProperties'
$IdentityImmersive = 'HKCU:\SOFTWARE\Microsoft\IdentityCRL\Immersive\production\Token'
$IrisServiceKey    = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\IrisService'
$MachineGuidKey    = 'HKLM:\SOFTWARE\Microsoft\Cryptography'
$CDPLocal          = Join-Path $env:LOCALAPPDATA 'ConnectedDevicesPlatform'
$DiagTrackPolicy   = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection'
$ActivityHistory   = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'
$AdvertisingId     = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\AdvertisingInfo'

$script:WatchedServiceNames = @(
    'CDPSvc',
    'DiagTrack',
    'dmwappushservice'
)

$script:KnownTelemetryTasks = @(
    '\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser',
    '\Microsoft\Windows\Application Experience\ProgramDataUpdater',
    '\Microsoft\Windows\Application Experience\StartupAppTask',
    '\Microsoft\Windows\Autochk\Proxy',
    '\Microsoft\Windows\Customer Experience Improvement Program\Consolidator',
    '\Microsoft\Windows\Customer Experience Improvement Program\UsbCeip',
    '\Microsoft\Windows\DiskDiagnostic\Microsoft-Windows-DiskDiagnosticDataCollector',
    '\Microsoft\Windows\Feedback\Siuf\DmClient',
    '\Microsoft\Windows\Feedback\Siuf\DmClientOnScenarioDownload'
)

function Ensure-AppDirs {
    foreach ($d in @($script:BackupRoot, $script:LogDir, $script:StateDir)) {
        if (-not (Test-Path -LiteralPath $d)) {
            New-Item -ItemType Directory -Path $d -Force | Out-Null
        }
    }
}

function Invoke-WithNamedMutex {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Action,
        [int]$TimeoutMs = 3000
    )
    $m = $null
    $owned = $false
    try {
        $created = $false
        $m = New-Object System.Threading.Mutex($false, $Name, [ref]$created)
        try {
            $owned = $m.WaitOne($TimeoutMs)
        } catch [System.Threading.AbandonedMutexException] {
            $owned = $true
        }
        if (-not $owned) { throw "Timed out waiting for mutex $Name" }
        & $Action
    } finally {
        if ($owned -and $null -ne $m) {
            try { $m.ReleaseMutex() | Out-Null } catch { }
        }
        if ($null -ne $m) {
            try { $m.Dispose() } catch { }
        }
    }
}

function Write-LogInfraFailure {
    param([Parameter(Mandatory)][string]$Message)
    # Non-recursive fallback: never call Write-AppLog/Add-LogLine here.
    try {
        $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        $line = "[$ts] [WARN] log-infra: $Message"
        $fallback = Join-Path $env:ProgramData 'FinalEclipse\Logs\infra-errors.log'
        $dir = Split-Path -Parent $fallback
        if (-not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        Add-Content -LiteralPath $fallback -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
        Write-Verbose $line
    } catch {
        Write-Verbose "log-infra fallback failed: $($_.Exception.Message)"
    }
}

function Invoke-LogRotation {
    try {
        if (-not (Test-Path -LiteralPath $script:LogFile)) { return }
        $fi = Get-Item -LiteralPath $script:LogFile -ErrorAction SilentlyContinue
        if ($null -eq $fi -or $fi.Length -lt $script:MaxLogBytes) { return }
        $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
        $archive = Join-Path $script:LogDir ("monitor_{0}.log" -f $stamp)
        Move-Item -LiteralPath $script:LogFile -Destination $archive -Force -ErrorAction Stop
        Get-ChildItem -LiteralPath $script:LogDir -Filter 'monitor_*.log' -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending |
            Select-Object -Skip 5 |
            Remove-Item -Force -ErrorAction SilentlyContinue
    } catch {
        Write-LogInfraFailure "Invoke-LogRotation failed: $($_.Exception.Message)"
    }
}

function Invoke-JsonLogRotation {
    try {
        if (-not (Test-Path -LiteralPath $script:JsonLogFile)) { return }
        $fi = Get-Item -LiteralPath $script:JsonLogFile -ErrorAction SilentlyContinue
        if ($null -eq $fi -or $fi.Length -lt $script:MaxJsonLogBytes) { return }
        $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
        $archive = Join-Path $script:LogDir ("events_{0}.jsonl" -f $stamp)
        Move-Item -LiteralPath $script:JsonLogFile -Destination $archive -Force -ErrorAction Stop
        Get-ChildItem -LiteralPath $script:LogDir -Filter 'events_*.jsonl' -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending |
            Select-Object -Skip 5 |
            Remove-Item -Force -ErrorAction SilentlyContinue
    } catch {
        Write-LogInfraFailure "Invoke-JsonLogRotation failed: $($_.Exception.Message)"
    }
}

function Add-LogLine {
    param([Parameter(Mandatory)][string]$Line)
    Invoke-WithNamedMutex -Name $script:LogMutexName -Action {
        Ensure-AppDirs
        Invoke-LogRotation
        Add-Content -LiteralPath $script:LogFile -Value $Line -Encoding UTF8 -ErrorAction Stop
    } -TimeoutMs 2000
}

function Write-AuditEvent {
    param(
        [Parameter(Mandatory)][string]$Event,
        [string]$Level = 'INFO',
        [string]$Message = '',
        [string]$Target = '',
        [hashtable]$Data = @{}
    )
    try {
        Invoke-WithNamedMutex -Name $script:AuditMutexName -Action {
            Ensure-AppDirs
            Invoke-JsonLogRotation
            $body = [ordered]@{
                timestamp = (Get-Date).ToString('o')
                app = $script:AppName
                event = $Event
                level = $Level
                user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
                computer = $env:COMPUTERNAME
                target = $Target
                message = $Message
                data = $Data
            }
            ($body | ConvertTo-Json -Depth 8 -Compress) |
                Add-Content -LiteralPath $script:JsonLogFile -Encoding UTF8 -ErrorAction Stop
        } -TimeoutMs 2000
    } catch {
        Write-Verbose "Audit write failed: $($_.Exception.Message)"
    }
}

function Write-AppLog {
    param(
        [string]$Message,
        [string]$Level = 'INFO',
        [int]$RateLimitTicks = 0
    )
    if ($RateLimitTicks -gt 0) {
        $key = "$Level|$Message"
        if ($script:LogRateLimit.ContainsKey($key)) {
            $last = $script:LogRateLimit[$key]
            if (($script:WatchdogTick - $last) -lt $RateLimitTicks) {
                return
            }
        }
        $script:LogRateLimit[$key] = $script:WatchdogTick
    }

    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$ts] [$Level] $Message"
    try {
        Add-LogLine -Line $line
    } catch {
        Write-Verbose "Log write failed: $($_.Exception.Message)"
    }
    Write-AuditEvent -Event 'log' -Level $Level -Message $Message

    if ($script:SuppressUiLog) {
        Write-CliHost $line
        return
    }
    if ($null -ne $script:txtLog) {
        try {
            if (-not $script:txtLog.IsDisposed) {
                $script:txtLog.AppendText($line + [Environment]::NewLine)
                if ($script:txtLog.TextLength -gt $script:MaxUiLogChars) {
                    $script:txtLog.Text = $script:txtLog.Text.Substring($script:txtLog.TextLength - [int]($script:MaxUiLogChars * 0.7))
                }
                $script:txtLog.SelectionStart = $script:txtLog.TextLength
                $script:txtLog.ScrollToCaret()
            }
        } catch { }
    } else {
        Write-CliHost $line
    }
}

function Test-EnterMonitorMutex {

    try {
        $created = $false
        $m = New-Object System.Threading.Mutex($false, $script:MutexName, [ref]$created)
        $owned = $false
        try {
            $owned = $m.WaitOne(0)
        } catch [System.Threading.AbandonedMutexException] {
            $owned = $true
            Write-AppLog 'Recovered abandoned monitor mutex from a previous crash.' 'WARN'
        }
        if (-not $owned) {
            $m.Dispose()
            return $false
        }
        $script:Mutex = $m
        return $true
    } catch {
        Write-AppLog "Mutex acquire failed; monitor will not start: $($_.Exception.Message)" 'ERROR'
        return $false
    }
}

function Exit-MonitorMutex {
    if ($null -ne $script:Mutex) {
        try {
            $script:Mutex.ReleaseMutex() | Out-Null
        } catch { }
        try {
            $script:Mutex.Dispose()
        } catch { }
        $script:Mutex = $null
    }
}

function Convert-ToHexString {
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [byte[]]) {
        return ([BitConverter]::ToString([byte[]]$Value) -replace '-', '')
    }
    if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [string])) {
        try {
            $bytes = @($Value | ForEach-Object { [byte]$_ })
            if ($bytes.Count -gt 0) {
                return ([BitConverter]::ToString([byte[]]$bytes) -replace '-', '')
            }
        } catch { }
    }
    return [string]$Value
}

function Convert-HexPuidToGdid {
    param($Hex)
    if ($null -eq $Hex) { return $null }
    $asText = Convert-ToHexString -Value $Hex
    if ([string]::IsNullOrWhiteSpace($asText)) { return $null }
    $clean = ($asText -replace '[^0-9A-Fa-f]', '').ToUpperInvariant()
    if ($clean.Length -lt 1 -or $clean.Length -gt 16) {
        if ($clean.Length -gt 16) { $clean = $clean.Substring(0, 16) }
        else { return $null }
    }
    try {
        $n = [Convert]::ToUInt64($clean, 16)
        return "g:$n"
    } catch {
        return $null
    }
}

function Get-SafeRegValue {
    param([string]$Path, [string]$Name)
    try {
        if (-not (Test-Path -LiteralPath $Path)) { return $null }
        $item = Get-ItemProperty -LiteralPath $Path -ErrorAction SilentlyContinue
        if ($null -eq $item) { return $null }
        $matched = @($item.PSObject.Properties.Match([string]$Name))
        if ($matched.Count -lt 1) { return $null }
        return $matched[0].Value
    } catch {
        return $null
    }
}

function Set-DwordPolicy {
    param([string]$Path, [string]$Name, [int]$Value)
    if ($WhatIfPreference) {
        Write-AppLog "WhatIf: would set $Path\$Name to $Value"
        return
    }
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -Path $Path -Force | Out-Null
    }
    Set-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -Type DWord -Force -ErrorAction Stop
}

function Get-ServiceState {
    param([string]$Name)
    $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $svc) { return 'Not installed' }
    return "$($svc.Status) / $($svc.StartType)"
}

function Get-ServiceBackupState {
    param([string]$Name)
    $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $svc) {
        return [ordered]@{
            Name = $Name
            Installed = $false
            Status = 'Not installed'
            StartType = 'n/a'
            FailureConfig = ''
        }
    }
    $failureConfig = ''
    try {
        $failureConfig = ((& sc.exe qfailure "$Name" 2>&1) | ForEach-Object { "$_" }) -join "`n"
    } catch {
        $failureConfig = "Unavailable: $($_.Exception.Message)"
    }
    return [ordered]@{
        Name = $Name
        Installed = $true
        Status = [string]$svc.Status
        StartType = [string]$svc.StartType
        FailureConfig = $failureConfig
    }
}

function Restore-ServiceBackupState {
    param($State)
    if ($null -eq $State -or -not $State.Installed) { return }
    $svc = Get-Service -Name $State.Name -ErrorAction SilentlyContinue
    if (-not $svc) { return }
    if ($WhatIfPreference) {
        Write-AppLog "WhatIf: would restore service $($State.Name) startup type to $($State.StartType)"
        return
    }
    try {
        Set-Service -Name $State.Name -StartupType $State.StartType -ErrorAction Stop
        Write-AppLog "Restored service startup type: $($State.Name) -> $($State.StartType)"
    } catch {
        Write-AppLog "Could not restore startup type for $($State.Name): $($_.Exception.Message)" 'WARN'
    }
}

function Split-TaskPath {
    param([Parameter(Mandatory)][string]$FullPath)
    $trimmed = $FullPath.Trim()
    $ix = $trimmed.LastIndexOf('\')
    if ($ix -lt 1) {
        return [pscustomobject]@{ TaskPath = '\'; TaskName = $trimmed.TrimStart('\') }
    }
    return [pscustomobject]@{
        TaskPath = ($trimmed.Substring(0, $ix + 1))
        TaskName = ($trimmed.Substring($ix + 1))
    }
}

function Get-TaskBackupState {
    param([string]$FullPath)
    $parts = Split-TaskPath -FullPath $FullPath
    $task = Get-ScheduledTask -TaskPath $parts.TaskPath -TaskName $parts.TaskName -ErrorAction SilentlyContinue
    if ($null -eq $task) {
        return [ordered]@{
            Path = $FullPath
            Installed = $false
            State = 'Not installed'
        }
    }
    return [ordered]@{
        Path = $FullPath
        Installed = $true
        State = [string]$task.State
    }
}

function Restore-TaskBackupState {
    param($State)
    if ($null -eq $State -or -not $State.Installed) { return }
    $parts = Split-TaskPath -FullPath $State.Path
    $task = Get-ScheduledTask -TaskPath $parts.TaskPath -TaskName $parts.TaskName -ErrorAction SilentlyContinue
    if ($null -eq $task) { return }
    try {
        if ($State.State -eq 'Disabled') {
            if ($WhatIfPreference) { Write-AppLog "WhatIf: would disable task $($State.Path)" }
            else {
                Disable-ScheduledTask -TaskPath $parts.TaskPath -TaskName $parts.TaskName -ErrorAction Stop | Out-Null
                Write-AppLog "Restored task disabled state: $($State.Path)"
            }
        } elseif ($task.State -eq 'Disabled') {
            if ($WhatIfPreference) { Write-AppLog "WhatIf: would enable task $($State.Path)" }
            else {
                Enable-ScheduledTask -TaskPath $parts.TaskPath -TaskName $parts.TaskName -ErrorAction Stop | Out-Null
                Write-AppLog "Restored task enabled state: $($State.Path)"
            }
        }
    } catch {
        Write-AppLog "Could not restore task $($State.Path): $($_.Exception.Message)" 'WARN'
    }
}

function Get-KnownTelemetryTaskState {
    $items = @()
    foreach ($full in $script:KnownTelemetryTasks) {
        $parts = Split-TaskPath -FullPath $full
        $task = Get-ScheduledTask -TaskPath $parts.TaskPath -TaskName $parts.TaskName -ErrorAction SilentlyContinue
        if ($null -eq $task) {
            $items += [pscustomobject]@{
                Path = $full
                State = 'Not installed'
                Enabled = $false
            }
            continue
        }
        $items += [pscustomobject]@{
            Path = $full
            State = [string]$task.State
            Enabled = ($task.State -ne 'Disabled')
        }
    }
    return $items
}

function Get-MonitorTaskHealth {
    $task = Get-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue
    if ($null -eq $task) {
        return [pscustomobject]@{
            Installed = $false
            Enabled = $false
            RunLevel = 'n/a'
            Action = ''
            TriggerOk = $false
            SettingsOk = $false
            Healthy = $false
            Summary = 'Not installed'
        }
    }

    $actions = @($task.Actions | ForEach-Object {
        "$($_.Execute) $($_.Arguments)"
    })
    $actionText = ($actions -join ' ; ')
    $hasMonitorAction = ($actionText -match [regex]::Escape($PSCommandPath) -and $actionText -match '-Monitor')
    $triggerOk = $false
    foreach ($trigger in @($task.Triggers)) {
        $className = ''
        if ($null -ne $trigger -and $null -ne $trigger.CimClass) {
            $className = [string]$trigger.CimClass.CimClassName
        }
        if ($className -match 'LogonTrigger') {
            $triggerOk = $true
            break
        }
    }
    $settingsOk = $false
    if ($null -ne $task.Settings) {
        $settingsOk = ([string]$task.Settings.MultipleInstances -eq 'IgnoreNew' -and [int]$task.Settings.RestartCount -ge 1)
    }
    $runLevelOk = ([string]$task.Principal.RunLevel -eq 'Highest')
    $healthy = ($task.State -ne 'Disabled' -and $hasMonitorAction -and $triggerOk -and $settingsOk -and $runLevelOk)

    return [pscustomobject]@{
        Installed = $true
        Enabled = ($task.State -ne 'Disabled')
        RunLevel = [string]$task.Principal.RunLevel
        Action = $actionText
        TriggerOk = $triggerOk
        SettingsOk = $settingsOk
        Healthy = $healthy
        Summary = if ($healthy) { 'Installed and points to this script' } else { 'Installed but needs review' }
    }
}

function Get-GdidSnapshot {
    $snap = [ordered]@{
        Timestamp            = (Get-Date).ToString('o')
        IdentityCRL_LID      = $null
        IdentityCRL_LID_GDID = $null
        DeviceIdTokens       = @()
        IrisGlobalDeviceIds  = @()
        MachineGuid          = $null
        AdvertisingId        = $null
        MonitorTask          = (Get-MonitorTaskHealth).Summary
        KnownTasksEnabled    = 0
        CDPSvc               = (Get-ServiceState 'CDPSvc')
        CDPUserSvc           = 'n/a'
        DiagTrack            = (Get-ServiceState 'DiagTrack')
        dmwappushservice     = (Get-ServiceState 'dmwappushservice')
        CDPFolderExists      = (Test-Path -LiteralPath $CDPLocal)
        MonitorRunning       = $script:MonitorRunning
        IsAdmin              = (Test-IsAdmin)
    }

    $userCdps = @(Get-Service -Name 'CDPUserSvc*' -ErrorAction SilentlyContinue)
    if ($userCdps.Count -gt 0) {
        $snap.CDPUserSvc = (($userCdps | ForEach-Object { "$($_.Name)=$($_.Status)/$($_.StartType)" }) -join '; ')
    } else {
        $snap.CDPUserSvc = 'Not installed'
    }

    $lid = Get-SafeRegValue -Path $IdentityExtProps -Name 'LID'
    if ($null -ne $lid -and "$lid" -ne '') {
        $lidText = Convert-ToHexString -Value $lid
        $snap.IdentityCRL_LID = $lidText
        $snap.IdentityCRL_LID_GDID = Convert-HexPuidToGdid -Hex $lid
    }

    if (Test-Path -LiteralPath $IdentityImmersive) {
        Get-ChildItem -LiteralPath $IdentityImmersive -ErrorAction SilentlyContinue | ForEach-Object {
            $dev = Get-SafeRegValue -Path $_.PSPath -Name 'DeviceId'
            if ($null -ne $dev -and "$dev" -ne '') {
                $devText = Convert-ToHexString -Value $dev
                $snap.DeviceIdTokens += [pscustomobject]@{
                    Path  = $_.PSPath
                    Value = $devText
                    GDID  = (Convert-HexPuidToGdid -Hex $dev)
                }
            }
        }
    }

    if (Test-Path -LiteralPath $IrisServiceKey) {
        Get-ChildItem -LiteralPath $IrisServiceKey -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
            try {
                $props = Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction SilentlyContinue
                if (-not $props) { return }
                foreach ($p in $props.PSObject.Properties) {
                    if ($p.Name -in @('PSPath','PSParentPath','PSChildName','PSDrive','PSProvider')) { continue }
                    $val = [string]$p.Value
                    if ($val -match 'g:\d{10,}' -or $val -match 'GLOBALDEVICEID' -or $p.Name -match 'GLOBALDEVICEID|GlobalDeviceId') {
                        $m = [regex]::Matches($val, 'g:\d{10,20}')
                        if ($m.Count -gt 0) {
                            foreach ($hit in $m) {
                                $snap.IrisGlobalDeviceIds += [pscustomobject]@{
                                    Path  = $_.PSPath
                                    Name  = $p.Name
                                    Value = $hit.Value
                                }
                            }
                        } elseif ($p.Name -match 'GLOBALDEVICEID|GlobalDeviceId') {
                            $snap.IrisGlobalDeviceIds += [pscustomobject]@{
                                Path  = $_.PSPath
                                Name  = $p.Name
                                Value = $val.Substring(0, [Math]::Min(120, $val.Length))
                            }
                        }
                    }
                }
            } catch { }
        }
    }

    $snap.MachineGuid   = Get-SafeRegValue -Path $MachineGuidKey -Name 'MachineGuid'
    $snap.AdvertisingId = Get-SafeRegValue -Path $AdvertisingId -Name 'Id'
    $snap.KnownTasksEnabled = @((Get-KnownTelemetryTaskState) | Where-Object { $_.Enabled }).Count
    return $snap
}

function Format-SnapshotText {
    param($Snap)
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('=== FinalEclipse snapshot ===')
    [void]$sb.AppendLine("Time: $($Snap.Timestamp)")
    [void]$sb.AppendLine("Live monitor: $(if ($Snap.MonitorRunning) { 'RUNNING' } else { 'stopped' })")
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('-- IdentityCRL device PUID (often mapped to GDID) --')
    if ($Snap.IdentityCRL_LID) {
        [void]$sb.AppendLine("LID (hex):  $($Snap.IdentityCRL_LID)")
        [void]$sb.AppendLine("As g: form: $($Snap.IdentityCRL_LID_GDID)")
    } else {
        [void]$sb.AppendLine('(not found under ExtendedProperties\LID)')
    }
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('-- Token DeviceId entries --')
    $tokenList = @($Snap.DeviceIdTokens)
    if ($tokenList.Count -eq 0) {
        [void]$sb.AppendLine('(none found)')
    } else {
        foreach ($t in $tokenList) {
            [void]$sb.AppendLine("  DeviceId: $($t.Value)  =>  $($t.GDID)")
        }
    }
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('-- IrisService cached GLOBALDEVICEID (g:...) --')
    $irisList = @($Snap.IrisGlobalDeviceIds)
    if ($irisList.Count -eq 0) {
        [void]$sb.AppendLine('(none found in cache)')
    } else {
        $unique = @($irisList | Select-Object -ExpandProperty Value -Unique)
        foreach ($u in $unique) {
            [void]$sb.AppendLine("  $u")
        }
    }
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('-- Related IDs --')
    [void]$sb.AppendLine("MachineGuid:   $($Snap.MachineGuid)")
    [void]$sb.AppendLine("AdvertisingId: $($Snap.AdvertisingId)")
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('-- Persistence checks --')
    [void]$sb.AppendLine("Monitor task:       $($Snap.MonitorTask)")
    [void]$sb.AppendLine("Known tasks enabled: $($Snap.KnownTasksEnabled)")
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('-- Services --')
    [void]$sb.AppendLine("CDPSvc:           $($Snap.CDPSvc)")
    [void]$sb.AppendLine("CDPUserSvc*:      $($Snap.CDPUserSvc)")
    [void]$sb.AppendLine("DiagTrack:        $($Snap.DiagTrack)")
    [void]$sb.AppendLine("dmwappushservice: $($Snap.dmwappushservice)")
    [void]$sb.AppendLine("CDP local folder: $(if ($Snap.CDPFolderExists) { $CDPLocal } else { '(absent)' })")
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('NOTE: Do not share these values publicly.')
    return $sb.ToString()
}

function Get-EnvironmentReport {
    $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction SilentlyContinue
    $ps = $PSVersionTable
    return [ordered]@{
        App = $script:AppName
        ScriptPath = $PSCommandPath
        IsAdmin = (Test-IsAdmin)
        User = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        Computer = $env:COMPUTERNAME
        PowerShellVersion = [string]$ps.PSVersion
        PowerShellEdition = [string]$ps.PSEdition
        CLRVersion = [string]$ps.CLRVersion
        OSName = if ($os) { [string]$os.Caption } else { 'Unavailable' }
        OSVersion = if ($os) { [string]$os.Version } else { 'Unavailable' }
        OSBuild = if ($os) { [string]$os.BuildNumber } else { 'Unavailable' }
        BackupRoot = $script:BackupRoot
        LogFile = $script:LogFile
        JsonLogFile = $script:JsonLogFile
        StateDir = $script:StateDir
    }
}

function Format-EnvironmentReportText {
    $envReport = Get-EnvironmentReport
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('=== Environment ===')
    foreach ($key in $envReport.Keys) {
        [void]$sb.AppendLine(("{0}: {1}" -f $key, $envReport[$key]))
    }
    return $sb.ToString()
}

function Format-OperationPlanText {
    param([ValidateSet('Wipe','Advanced','Full','Restore')]$Operation)
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("=== Planned operation: $Operation ===")
    [void]$sb.AppendLine("Dry run: $(if ($WhatIfPreference) { 'ON' } else { 'off' })")
    [void]$sb.AppendLine('')
    switch ($Operation) {
        'Wipe' {
            [void]$sb.AppendLine('Will remove local identity values when present:')
            [void]$sb.AppendLine("  $IdentityExtProps\LID, DeviceId, GlobalDeviceId")
            [void]$sb.AppendLine("  $IdentityImmersive token DeviceId and LID values")
            [void]$sb.AppendLine('  HKLM:\SOFTWARE\Microsoft\IdentityStore DeviceId, LID, GlobalDeviceId values')
        }
        'Advanced' {
            [void]$sb.AppendLine('Will clear service recovery actions for:')
            foreach ($n in $script:WatchedServiceNames) { [void]$sb.AppendLine("  $n") }
            [void]$sb.AppendLine('  CDPUserSvc* instances')
            [void]$sb.AppendLine('')
            [void]$sb.AppendLine('Will disable known telemetry/feedback scheduled tasks when installed:')
            foreach ($t in $script:KnownTelemetryTasks) { [void]$sb.AppendLine("  $t") }
            [void]$sb.AppendLine('')
            [void]$sb.AppendLine('Will reapply Activity History, telemetry, and Advertising ID policies.')
        }
        'Full' {
            [void]$sb.AppendLine("Will create a backup under: $script:BackupRoot")
            [void]$sb.AppendLine('Will stop/disable watched services and CDPUserSvc* instances.')
            [void]$sb.AppendLine('Will run Advanced harden.')
            [void]$sb.AppendLine("Will remove IrisService cache: $IrisServiceKey")
            [void]$sb.AppendLine("Will remove CDP local folder: $CDPLocal")
            [void]$sb.AppendLine('Will wipe local PUID/GDID registry values listed in the Wipe plan.')
        }
        'Restore' {
            [void]$sb.AppendLine("Will import .reg files from the newest folder under: $script:BackupRoot")
            [void]$sb.AppendLine('When manifest.json is present, will restore captured service startup types and scheduled task enabled states.')
        }
    }
    return $sb.ToString()
}

function Disable-ServiceRecovery {
    param([string]$Name, [switch]$Quiet)
    $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $svc) { return $false }

    $changed = $false
    if ($WhatIfPreference) {
        Write-AppLog "WhatIf: would clear service recovery actions for $Name"
        return $true
    }
    try {
        $out = & sc.exe failure "$Name" reset= 0 actions= "" 2>&1
        if ($LASTEXITCODE -eq 0) { $changed = $true }
        else { Write-AppLog "Service recovery reset failed for ${Name}: $out" 'WARN' -RateLimitTicks 24 }
    } catch {
        Write-AppLog "Service recovery reset error for ${Name}: $($_.Exception.Message)" 'WARN' -RateLimitTicks 24
    }

    try {
        & sc.exe failureflag "$Name" 0 2>$null | Out-Null
    } catch {
        Write-AppLog "Service failure flag reset error for ${Name}: $($_.Exception.Message)" 'WARN' -RateLimitTicks 24
    }

    if ($changed -and -not $Quiet) {
        Write-AppLog "Cleared service recovery actions: $Name"
    }
    return $changed
}

function Invoke-ExternalCommand {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$Arguments
    )
    $output = & $FilePath @Arguments 2>&1
    return [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Output = (($output | ForEach-Object { "$_" }) -join "`n").Trim()
    }
}

function Wait-ServiceStableState {
    param(
        [Parameter(Mandatory)][string]$Name,
        [switch]$NeedStopped,
        [switch]$NeedDisabled,
        [int]$TimeoutSeconds = 12
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $last = $null
    do {
        $last = Get-Service -Name $Name -ErrorAction SilentlyContinue
        if ($null -eq $last) { return $null }
        $stoppedOk = (-not $NeedStopped) -or $last.Status -eq 'Stopped'
        $disabledOk = (-not $NeedDisabled) -or $last.StartType -eq [System.ServiceProcess.ServiceStartMode]::Disabled
        if ($stoppedOk -and $disabledOk) { return $last }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $deadline)
    return $last
}

function Disable-ServiceHard {
    param([string]$Name, [switch]$Quiet)
    $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $svc) { return $false }

    $neededStop    = ($svc.Status -ne 'Stopped' -and $svc.Status -ne 'StopPending')
    $neededDisable = ($svc.StartType -ne [System.ServiceProcess.ServiceStartMode]::Disabled)
    if (-not $neededStop -and -not $neededDisable) {
        return $false
    }

    if ($neededStop) {
        if ($WhatIfPreference) {
            Write-AppLog "WhatIf: would stop service $Name"
        } else {
            try {
                Stop-Service -Name $Name -Force -ErrorAction Stop
            } catch {
                $r = Invoke-ExternalCommand -FilePath 'sc.exe' -Arguments @('stop', $Name)
                if ($r.ExitCode -ne 0) {
                    Write-AppLog "sc.exe stop failed for ${Name} (exit $($r.ExitCode)): $($r.Output)" 'WARN' -RateLimitTicks 24
                }
            }
        }
    }
    if ($neededDisable) {
        if ($WhatIfPreference) {
            Write-AppLog "WhatIf: would disable service $Name"
        } else {
            try {
                Set-Service -Name $Name -StartupType Disabled -ErrorAction Stop
            } catch {
                $r = Invoke-ExternalCommand -FilePath 'sc.exe' -Arguments @('config', $Name, 'start=', 'disabled')
                if ($r.ExitCode -ne 0) {
                    Write-AppLog "sc.exe config failed for ${Name} (exit $($r.ExitCode)): $($r.Output)" 'WARN' -RateLimitTicks 24
                }
            }
        }
    }

    if ($WhatIfPreference) { return $true }

    $after = Wait-ServiceStableState -Name $Name -NeedStopped:$neededStop -NeedDisabled:$neededDisable
    if (-not $after) { return $false }
    $nowStopped  = ($after.Status -eq 'Stopped')
    $nowDisabled = ($after.StartType -eq [System.ServiceProcess.ServiceStartMode]::Disabled)
    $changed = ($neededStop -and $nowStopped) -or ($neededDisable -and $nowDisabled)

    if ($changed) {
        if ($Quiet) {
            Write-AppLog "Monitor: stopped/disabled $Name" 'WARN' -RateLimitTicks 12
        } else {
            Write-AppLog "Blocked/disabled service: $Name"
        }
        return $true
    }

    if ($Quiet) {
        Write-AppLog "Monitor: could not fully disable $Name (status=$($after.Status), start=$($after.StartType))" 'WARN' -RateLimitTicks 24
    } else {
        Write-AppLog "Could not fully disable $Name (status=$($after.Status), start=$($after.StartType))" 'WARN'
    }
    return $false
}

function Export-RegistryBackup {
    if ($WhatIfPreference) {
        Write-AppLog 'WhatIf: would create registry backup'
        return [pscustomobject]@{
            Path = $null
            Success = $true
            Exported = @()
            Failed = @()
            Skipped = $true
        }
    }

    Ensure-AppDirs
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $dir = Join-Path $script:BackupRoot $stamp
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $failed = @()
    $exported = @()

    $exports = @(
        @{ File = 'IdentityCRL.reg'; Path = 'HKCU\SOFTWARE\Microsoft\IdentityCRL' },
        @{ File = 'IrisService.reg'; Path = 'HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\IrisService' },
        @{ File = 'AdvertisingInfo.reg'; Path = 'HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\AdvertisingInfo' }
    )

    foreach ($e in $exports) {
        $out = Join-Path $dir $e.File
        if (-not (Test-Path -LiteralPath ("Registry::{0}" -f $e.Path))) {
            Write-AppLog "Backup source absent, skipped: $($e.Path)"
            continue
        }
        try {
            $p = Start-Process -FilePath 'reg.exe' -ArgumentList @('export', $e.Path, $out, '/y') -Wait -PassThru -WindowStyle Hidden
            if ($null -ne $p -and $p.ExitCode -eq 0) {
                Write-AppLog "Backed up $($e.Path) -> $out"
                $exported += $out
            } else {
                $code = if ($null -ne $p) { $p.ExitCode } else { 'n/a' }
                Write-AppLog "Backup skipped/failed for $($e.Path) (exit $code)" 'WARN'
                $failed += $e.Path
            }
        } catch {
            Write-AppLog "Backup error for $($e.Path): $($_.Exception.Message)" 'WARN'
            $failed += $e.Path
        }
    }

    $snap = Get-GdidSnapshot
    $snapPath = Join-Path $dir 'snapshot.txt'
    try {
        Format-SnapshotText -Snap $snap | Set-Content -LiteralPath $snapPath -Encoding UTF8 -ErrorAction Stop
        Write-AppLog "Snapshot written: $snapPath"
    } catch {
        Write-AppLog "Snapshot backup failed: $($_.Exception.Message)" 'ERROR'
        $failed += 'snapshot.txt'
    }
    $manifestPath = Join-Path $dir 'manifest.json'
    try {
        $serviceNames = @($script:WatchedServiceNames)
        $serviceNames += @(Get-Service -Name 'CDPUserSvc*' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
        $fileHashes = @()
        foreach ($expPath in $exported) {
            if (Test-Path -LiteralPath $expPath) {
                $hash = (Get-FileHash -LiteralPath $expPath -Algorithm SHA256).Hash
                $fileHashes += [ordered]@{
                    File = Split-Path -Leaf $expPath
                    Sha256 = $hash
                }
            }
        }
        $manifest = [ordered]@{
            Version = $script:BackupManifestVersion
            Created = (Get-Date).ToString('o')
            ScriptPath = $PSCommandPath
            Computer = $env:COMPUTERNAME
            User = [Security.Principal.WindowsIdentity]::GetCurrent().Name
            ExportedRegistryFiles = @($exported | ForEach-Object { Split-Path -Leaf $_ })
            RegistryFileHashes = @($fileHashes)
            RegistryExportFailures = @($failed)
            Services = @($serviceNames | Select-Object -Unique | ForEach-Object { Get-ServiceBackupState -Name $_ })
            KnownTelemetryTasks = @($script:KnownTelemetryTasks | ForEach-Object { Get-TaskBackupState -FullPath $_ })
            Environment = Get-EnvironmentReport
        }
        $manifest | ConvertTo-Json -Depth 10 |
            Set-Content -LiteralPath $manifestPath -Encoding UTF8 -ErrorAction Stop
        Write-AppLog "Backup manifest written: $manifestPath"
        Write-AuditEvent -Event 'backup-created' -Message "Backup created: $dir" -Target $dir -Data @{
            success = ($failed.Count -eq 0)
            exported = @($exported)
            failed = @($failed)
            manifest = $manifestPath
        }
    } catch {
        Write-AppLog "Backup manifest failed: $($_.Exception.Message)" 'ERROR'
        $failed += 'manifest.json'
    }
    return [pscustomobject]@{
        Path = $dir
        Success = ($failed.Count -eq 0)
        Exported = $exported
        Failed = $failed
    }
}

function Restore-LatestRegistryBackup {
    Ensure-AppDirs
    $latest = Get-ChildItem -LiteralPath $script:BackupRoot -Directory -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    if ($null -eq $latest) {
        throw "No backup folders found under $script:BackupRoot"
    }
    $manifestPath = Join-Path $latest.FullName 'manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath)) {
        throw "Refusing restore: latest backup has no manifest.json (integrity binding required): $($latest.FullName)"
    }
    try {
        $manifest = Get-Content -LiteralPath $manifestPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    } catch {
        throw "Refusing restore: cannot parse manifest.json: $($_.Exception.Message)"
    }

    # Build allowlist: prefer RegistryFileHashes (SHA-256 bound); fall back to ExportedRegistryFiles only with hash verification when available.
    $allowed = @{}
    if ($null -ne $manifest.RegistryFileHashes) {
        foreach ($entry in @($manifest.RegistryFileHashes)) {
            if ($null -eq $entry.File -or [string]::IsNullOrWhiteSpace([string]$entry.File)) { continue }
            $leaf = [string]$entry.File
            if ($leaf.Contains('..') -or $leaf.Contains('/') -or $leaf.Contains('\')) {
                throw "Refusing restore: invalid manifest file name '$leaf'"
            }
            $allowed[$leaf] = [string]$entry.Sha256
        }
    } elseif ($null -ne $manifest.ExportedRegistryFiles) {
        foreach ($leaf in @($manifest.ExportedRegistryFiles)) {
            $name = [string]$leaf
            if ($name.Contains('..') -or $name.Contains('/') -or $name.Contains('\')) {
                throw "Refusing restore: invalid manifest file name '$name'"
            }
            $allowed[$name] = $null  # no hash in older manifests — refuse for security
        }
        if ($allowed.Count -gt 0 -and (@($allowed.Values | Where-Object { $_ })) -eq $null) {
            # All null hashes => legacy manifest without integrity hashes
            throw "Refusing restore: manifest lacks RegistryFileHashes (create a new backup with this version first)"
        }
    } else {
        throw "Refusing restore: manifest lists no registry files"
    }
    if ($allowed.Count -eq 0) {
        throw "Refusing restore: no registry files listed in manifest"
    }

    foreach ($leaf in @($allowed.Keys)) {
        $full = Join-Path $latest.FullName $leaf
        if (-not (Test-Path -LiteralPath $full)) {
            throw "Refusing restore: listed file missing: $leaf"
        }
        $expected = $allowed[$leaf]
        if ([string]::IsNullOrWhiteSpace($expected)) {
            throw "Refusing restore: no SHA-256 recorded for $leaf"
        }
        $actual = (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash
        if ($actual -ne $expected) {
            throw "Refusing restore: hash mismatch for $leaf (possible tampering)"
        }
        if ($WhatIfPreference) {
            Write-AppLog "WhatIf: would import verified registry backup $full"
            continue
        }
        $p = Start-Process -FilePath 'reg.exe' -ArgumentList @('import', $full) -Wait -PassThru -WindowStyle Hidden
        if ($null -eq $p -or $p.ExitCode -ne 0) {
            $code = if ($null -ne $p) { $p.ExitCode } else { 'n/a' }
            throw "reg.exe import failed for $full (exit $code)"
        }
        Write-AppLog "Restored verified registry backup: $full"
    }

    try {
        foreach ($svcState in @($manifest.Services)) {
            Restore-ServiceBackupState -State $svcState
        }
        foreach ($taskState in @($manifest.KnownTelemetryTasks)) {
            Restore-TaskBackupState -State $taskState
        }
        Write-AppLog "Restored reversible state from manifest: $manifestPath"
    } catch {
        Write-AppLog "Manifest state restore failed: $($_.Exception.Message)" 'WARN'
    }
    Write-AuditEvent -Event 'backup-restored' -Message "Restored latest backup: $($latest.FullName)" -Target $latest.FullName
    return $latest.FullName
}

function Invoke-AssertPrivacyPolicies {
    Set-DwordPolicy -Path $ActivityHistory -Name 'EnableActivityFeed' -Value 0
    Set-DwordPolicy -Path $ActivityHistory -Name 'PublishUserActivities' -Value 0
    Set-DwordPolicy -Path $ActivityHistory -Name 'UploadUserActivities' -Value 0
    Set-DwordPolicy -Path $DiagTrackPolicy -Name 'AllowTelemetry' -Value 1
    Set-DwordPolicy -Path $AdvertisingId -Name 'Enabled' -Value 0
    if ($WhatIfPreference) {
        Write-AppLog "WhatIf: would remove $AdvertisingId\Id"
    } else {
        Remove-ItemProperty -LiteralPath $AdvertisingId -Name 'Id' -ErrorAction SilentlyContinue
    }
}

function Invoke-DisableGdidPipeline {
    Write-AppLog 'Disabling Connected Devices Platform and related telemetry helpers...'

    foreach ($n in $script:WatchedServiceNames) {
        Disable-ServiceHard -Name $n | Out-Null
        Disable-ServiceRecovery -Name $n | Out-Null
    }
    foreach ($svc in @(Get-Service -Name 'CDPUserSvc*' -ErrorAction SilentlyContinue)) {
        Disable-ServiceHard -Name $svc.Name | Out-Null
        Disable-ServiceRecovery -Name $svc.Name | Out-Null
    }

    try {
        Invoke-AssertPrivacyPolicies
        Write-AppLog 'Activity History policies set to off.'
        Write-AppLog 'AllowTelemetry policy set to 1 (Basic).'
        Write-AppLog 'Advertising ID disabled and local Id cleared.'
    } catch {
        Write-AppLog "Policy apply failed: $($_.Exception.Message)" 'WARN'
    }
    Write-AppLog 'Pipeline disable complete.'
}

function Disable-KnownTelemetryTasks {
    param([switch]$Quiet)
    $changed = 0
    foreach ($full in $script:KnownTelemetryTasks) {
        $parts = Split-TaskPath -FullPath $full
        $task = Get-ScheduledTask -TaskPath $parts.TaskPath -TaskName $parts.TaskName -ErrorAction SilentlyContinue
        if ($null -eq $task -or $task.State -eq 'Disabled') { continue }
        try {
            if ($WhatIfPreference) {
                Write-AppLog "WhatIf: would disable known telemetry task: $full"
            } else {
                Disable-ScheduledTask -TaskPath $parts.TaskPath -TaskName $parts.TaskName -ErrorAction Stop | Out-Null
                if (-not $Quiet) { Write-AppLog "Disabled known telemetry task: $full" }
            }
            $changed++
        } catch {
            Write-AppLog "Could not disable task $full`: $($_.Exception.Message)" 'WARN'
        }
    }
    if (-not $Quiet -and $changed -eq 0) {
        Write-AppLog 'Known telemetry task audit found nothing enabled to disable.'
    }
    return $changed
}

function Format-TaskAuditText {
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('=== Known task audit ===')
    foreach ($t in Get-KnownTelemetryTaskState) {
        [void]$sb.AppendLine(("{0}  [{1}]" -f $t.Path, $t.State))
    }
    return $sb.ToString()
}

function Format-TaskHealthText {
    $h = Get-MonitorTaskHealth
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('=== FinalEclipse monitor task health ===')
    [void]$sb.AppendLine("Installed: $($h.Installed)")
    [void]$sb.AppendLine("Enabled:   $($h.Enabled)")
    [void]$sb.AppendLine("RunLevel:  $($h.RunLevel)")
    [void]$sb.AppendLine("TriggerOk: $($h.TriggerOk)")
    [void]$sb.AppendLine("SettingsOk:$($h.SettingsOk)")
    [void]$sb.AppendLine("Healthy:   $($h.Healthy)")
    if ($h.Action) {
        [void]$sb.AppendLine("Action:    $($h.Action)")
    }
    [void]$sb.AppendLine("Summary:   $($h.Summary)")
    return $sb.ToString()
}

function Convert-SnapshotForDrift {
    param($Snap)
    $deviceTokens = @($Snap.DeviceIdTokens | ForEach-Object { "$($_.Value)|$($_.GDID)" })
    $irisIds = @($Snap.IrisGlobalDeviceIds | Select-Object -ExpandProperty Value -Unique)
    return [ordered]@{
        IdentityCRL_LID = [string]$Snap.IdentityCRL_LID
        IdentityCRL_LID_GDID = [string]$Snap.IdentityCRL_LID_GDID
        DeviceIdTokens = ($deviceTokens -join ';')
        IrisGlobalDeviceIds = ($irisIds -join ';')
        AdvertisingId = [string]$Snap.AdvertisingId
        CDPSvc = [string]$Snap.CDPSvc
        CDPUserSvc = [string]$Snap.CDPUserSvc
        DiagTrack = [string]$Snap.DiagTrack
        dmwappushservice = [string]$Snap.dmwappushservice
        CDPFolderExists = [string]$Snap.CDPFolderExists
        MonitorTask = [string]$Snap.MonitorTask
        KnownTasksEnabled = [string]$Snap.KnownTasksEnabled
    }
}

function Write-DriftBaseline {
    param($Snap)
    Ensure-AppDirs
    $body = [ordered]@{
        Created = (Get-Date).ToString('o')
        Snapshot = (Convert-SnapshotForDrift -Snap $Snap)
    }
    Invoke-WithNamedMutex -Name 'Global\FinalEclipse-State-Writer' -Action {
        $tmp = Join-Path $script:StateDir ("last-snapshot.{0}.tmp" -f ([guid]::NewGuid().ToString('N')))
        try {
            $json = $body | ConvertTo-Json -Depth 5
            $null = $json | ConvertFrom-Json -ErrorAction Stop
            $json | Set-Content -LiteralPath $tmp -Encoding UTF8 -ErrorAction Stop
            Move-Item -LiteralPath $tmp -Destination $script:DriftPath -Force -ErrorAction Stop
        } finally {
            if (Test-Path -LiteralPath $tmp) {
                Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

function Format-DriftReport {
    Ensure-AppDirs
    $current = Get-GdidSnapshot
    $currentFlat = Convert-SnapshotForDrift -Snap $current
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('=== Drift report ===')

    if (-not (Test-Path -LiteralPath $script:DriftPath)) {
        Write-DriftBaseline -Snap $current
        [void]$sb.AppendLine("No previous baseline existed. Created: $script:DriftPath")
        return $sb.ToString()
    }

    $old = Get-Content -LiteralPath $script:DriftPath -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json -ErrorAction SilentlyContinue
    if ($null -eq $old -or $null -eq $old.Snapshot) {
        Write-DriftBaseline -Snap $current
        [void]$sb.AppendLine("Previous baseline was unreadable. Replaced: $script:DriftPath")
        return $sb.ToString()
    }

    [void]$sb.AppendLine("Previous baseline: $($old.Created)")
    [void]$sb.AppendLine("Current scan:      $($current.Timestamp)")
    [void]$sb.AppendLine('')

    $changes = 0
    foreach ($key in $currentFlat.Keys) {
        $before = [string]$old.Snapshot.$key
        $after = [string]$currentFlat[$key]
        if ($before -ne $after) {
            $changes++
            [void]$sb.AppendLine("$key")
            [void]$sb.AppendLine("  before: $before")
            [void]$sb.AppendLine("  after:  $after")
        }
    }

    if ($changes -eq 0) {
        [void]$sb.AppendLine('No drift detected.')
    } else {
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine("Changes detected: $changes")
    }

    Write-DriftBaseline -Snap $current
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine("Baseline updated: $script:DriftPath")
    return $sb.ToString()
}

function Invoke-AdvancedHardening {
    Write-AppLog 'Running advanced hardening checks...'
    foreach ($n in $script:WatchedServiceNames) {
        Disable-ServiceRecovery -Name $n | Out-Null
    }
    foreach ($svc in @(Get-Service -Name 'CDPUserSvc*' -ErrorAction SilentlyContinue)) {
        Disable-ServiceRecovery -Name $svc.Name | Out-Null
    }
    $disabled = Disable-KnownTelemetryTasks
    try { Invoke-AssertPrivacyPolicies } catch { Write-AppLog "Policy apply failed: $($_.Exception.Message)" 'WARN' }
    $health = Get-MonitorTaskHealth
    Write-AppLog "Advanced hardening complete. Known tasks disabled this run: $disabled. Monitor task: $($health.Summary)"
}

function Invoke-ClearLocalCaches {
    param([switch]$Quiet)
    $did = $false

    if (Test-Path -LiteralPath $IrisServiceKey) {
        try {
            if ($WhatIfPreference) {
                Write-AppLog "WhatIf: would remove IrisService registry tree: $IrisServiceKey"
            } else {
                Remove-Item -LiteralPath $IrisServiceKey -Recurse -Force -ErrorAction Stop
            }
            $did = $true
            if ($Quiet) { Write-AppLog 'Monitor: erased IrisService cache' 'WARN' -RateLimitTicks 6 }
            else { Write-AppLog 'Removed IrisService registry tree.' }
        } catch {
            Write-AppLog "Could not remove IrisService: $($_.Exception.Message)" 'WARN' -RateLimitTicks 12
        }
    }

    if (Test-Path -LiteralPath $CDPLocal) {
        try {
            if ($WhatIfPreference) {
                Write-AppLog "WhatIf: would remove CDP local folder: $CDPLocal"
            } else {
                Remove-Item -LiteralPath $CDPLocal -Recurse -Force -ErrorAction Stop
            }
            $did = $true
            if ($Quiet) { Write-AppLog 'Monitor: erased CDP local folder' 'WARN' -RateLimitTicks 6 }
            else { Write-AppLog "Removed $CDPLocal" }
        } catch {
            Write-AppLog "Could not remove CDP folder: $($_.Exception.Message)" 'WARN' -RateLimitTicks 12
        }
    }

    if (-not $Quiet -and -not $did) {
        Write-AppLog 'Local caches already absent.'
    }
    return $did
}

function Invoke-WipeLocalDevicePuid {
    param([switch]$Quiet)
    $did = $false

    if (Test-Path -LiteralPath $IdentityExtProps) {
        foreach ($name in @('LID', 'DeviceId', 'GlobalDeviceId')) {
            if ($null -ne (Get-SafeRegValue -Path $IdentityExtProps -Name $name)) {
                try {
                    if ($WhatIfPreference) {
                        Write-AppLog "WhatIf: would remove $IdentityExtProps\$name"
                    } else {
                        Remove-ItemProperty -LiteralPath $IdentityExtProps -Name $name -ErrorAction Stop
                    }
                    $did = $true
                    if ($Quiet) { Write-AppLog "Monitor: wiped ExtendedProperties\$name" 'WARN' -RateLimitTicks 6 }
                    else { Write-AppLog "Removed ExtendedProperties\$name" }
                } catch {
                    Write-AppLog "Could not remove ExtendedProperties\${name}: $($_.Exception.Message)" 'WARN' -RateLimitTicks 12
                }
            }
        }
    }

    if (Test-Path -LiteralPath $IdentityImmersive) {
        Get-ChildItem -LiteralPath $IdentityImmersive -ErrorAction SilentlyContinue | ForEach-Object {
            foreach ($name in @('DeviceId', 'LID')) {
                if ($null -ne (Get-SafeRegValue -Path $_.PSPath -Name $name)) {
                    try {
                        if ($WhatIfPreference) {
                            Write-AppLog "WhatIf: would remove $($_.PSPath)\$name"
                        } else {
                            Remove-ItemProperty -LiteralPath $_.PSPath -Name $name -ErrorAction Stop
                        }
                        $did = $true
                        if ($Quiet) { Write-AppLog "Monitor: wiped token $name under $($_.PSChildName)" 'WARN' -RateLimitTicks 6 }
                        else { Write-AppLog "Removed $name under $($_.PSChildName)" }
                    } catch {
                        Write-AppLog "Could not remove token $name under $($_.PSChildName): $($_.Exception.Message)" 'WARN' -RateLimitTicks 12
                    }
                }
            }
        }
    }

    $idStore = 'HKLM:\SOFTWARE\Microsoft\IdentityStore'
    if (Test-Path -LiteralPath $idStore) {
        Get-ChildItem -LiteralPath $idStore -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
            try {
                $props = Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction SilentlyContinue
                if (-not $props) { return }
                foreach ($name in @('DeviceId', 'LID', 'GlobalDeviceId')) {
                    $matched = @($props.PSObject.Properties.Match([string]$name))
                    if ($matched.Count -lt 1 -or $null -eq $matched[0].Value) { continue }
                    if ($WhatIfPreference) {
                        Write-AppLog "WhatIf: would remove $($_.PSPath)\$name"
                    } else {
                        Remove-ItemProperty -LiteralPath $_.PSPath -Name $name -ErrorAction Stop
                    }
                    $did = $true
                    if ($Quiet) { Write-AppLog "Monitor: wiped IdentityStore $name" 'WARN' -RateLimitTicks 6 }
                    else { Write-AppLog "Cleared IdentityStore $name" }
                }
            } catch {
                Write-AppLog "IdentityStore scan/wipe error under $($_.PSPath): $($_.Exception.Message)" 'WARN' -RateLimitTicks 12
            }
        }
    }

    if (-not $Quiet -and -not $did) {
        Write-AppLog 'No local PUID values present to wipe.'
    }
    return $did
}

function Invoke-FullHarden {
    $backup = Export-RegistryBackup
    if (-not $backup.Success) {
        $failed = ($backup.Failed -join ', ')
        throw "Full harden stopped because backup was incomplete. Backup folder: $($backup.Path). Failed: $failed"
    }
    Invoke-DisableGdidPipeline
    Invoke-AdvancedHardening
    Invoke-ClearLocalCaches | Out-Null
    Invoke-WipeLocalDevicePuid | Out-Null
    Write-AppLog 'Full harden finished. Start live monitor to keep it that way.'
}

function Invoke-WatchdogTick {

    if ($script:WatchdogBusy) { return 0 }
    $script:WatchdogBusy = $true
    try {
        $script:WatchdogTick++
        $actions = 0

        foreach ($n in $script:WatchedServiceNames) {
            if (Disable-ServiceHard -Name $n -Quiet) { $actions++ }
        }
        foreach ($svc in @(Get-Service -Name 'CDPUserSvc*' -ErrorAction SilentlyContinue)) {
            if (Disable-ServiceHard -Name $svc.Name -Quiet) { $actions++ }
        }

        if (($script:WatchdogTick % 120) -eq 0) {
            foreach ($n in $script:WatchedServiceNames) {
                Disable-ServiceRecovery -Name $n -Quiet | Out-Null
            }
            foreach ($svc in @(Get-Service -Name 'CDPUserSvc*' -ErrorAction SilentlyContinue)) {
                Disable-ServiceRecovery -Name $svc.Name -Quiet | Out-Null
            }
        }

        if (Invoke-WipeLocalDevicePuid -Quiet) { $actions++ }
        if (Invoke-ClearLocalCaches -Quiet) { $actions++ }

        if (($script:WatchdogTick % 30) -eq 0) {
            try {
                Invoke-AssertPrivacyPolicies
            } catch {
                Write-AppLog "Monitor: policy re-assert failed: $($_.Exception.Message)" 'WARN' -RateLimitTicks 12
            }
        }

        if (($script:WatchdogTick % 12) -eq 0) {
            Write-AppLog "Monitor heartbeat tick#$($script:WatchdogTick) (actions this cycle: $actions)"
        }

        return $actions
    } finally {
        $script:WatchdogBusy = $false
    }
}

function Get-ProtectedScriptInstallPath {
    return (Join-Path $env:ProgramData 'FinalEclipse\FinalEclipse.ps1')
}

function Install-ProtectedScriptCopy {
    <#
      Copy this script into ProgramData with an Administrators/SYSTEM-only ACL
      so a non-elevated user cannot replace the elevated task payload.
    #>
    param([Parameter(Mandatory)][string]$SourcePath)
    Ensure-AppDirs
    $dest = Get-ProtectedScriptInstallPath
    $destDir = Split-Path -Parent $dest
    if (-not (Test-Path -LiteralPath $destDir)) {
        New-Item -ItemType Directory -Path $destDir -Force | Out-Null
    }
    Copy-Item -LiteralPath $SourcePath -Destination $dest -Force -ErrorAction Stop

    # Restrict ACL: SYSTEM + Administrators full; remove inherited Everyone/Users write.
    try {
        $acl = Get-Acl -LiteralPath $dest
        $acl.SetAccessRuleProtection($true, $false)
        $rules = @(
            (New-Object System.Security.AccessControl.FileSystemAccessRule('NT AUTHORITY\SYSTEM','FullControl','Allow')),
            (New-Object System.Security.AccessControl.FileSystemAccessRule('BUILTIN\Administrators','FullControl','Allow'))
        )
        $acl.Access | ForEach-Object { [void]$acl.RemoveAccessRule($_) }
        foreach ($r in $rules) { $acl.AddAccessRule($r) }
        Set-Acl -LiteralPath $dest -AclObject $acl
    } catch {
        Write-AppLog "Could not fully lock ACL on $dest : $($_.Exception.Message)" 'WARN'
    }

    $hash = (Get-FileHash -LiteralPath $dest -Algorithm SHA256).Hash
    $hashPath = Join-Path $script:StateDir 'installed-script.sha256'
    Set-Content -LiteralPath $hashPath -Value $hash -Encoding ASCII -Force
    try {
        $hAcl = Get-Acl -LiteralPath $hashPath
        $hAcl.SetAccessRuleProtection($true, $false)
        $hAcl.Access | ForEach-Object { [void]$hAcl.RemoveAccessRule($_) }
        $hAcl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule('NT AUTHORITY\SYSTEM','FullControl','Allow')))
        $hAcl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule('BUILTIN\Administrators','FullControl','Allow')))
        Set-Acl -LiteralPath $hashPath -AclObject $hAcl
    } catch { }
    return [pscustomobject]@{ Path = $dest; Sha256 = $hash }
}

function Test-ProtectedScriptIntegrity {
    param([Parameter(Mandatory)][string]$ScriptPath)
    $hashPath = Join-Path $script:StateDir 'installed-script.sha256'
    if (-not (Test-Path -LiteralPath $hashPath)) {
        return $false
    }
    if (-not (Test-Path -LiteralPath $ScriptPath)) {
        return $false
    }
    $expected = (Get-Content -LiteralPath $hashPath -Raw -ErrorAction SilentlyContinue).Trim()
    if ([string]::IsNullOrWhiteSpace($expected)) { return $false }
    $actual = (Get-FileHash -LiteralPath $ScriptPath -Algorithm SHA256).Hash
    return ($actual -eq $expected)
}

function Install-MonitorTask {
    $sourcePath = $PSCommandPath
    if ($WhatIfPreference) {
        Write-AppLog "WhatIf: would install protected script copy and register scheduled task '$($script:TaskName)'"
        return
    }
    $installed = Install-ProtectedScriptCopy -SourcePath $sourcePath
    $scriptPath = $installed.Path
    if (-not (Test-ProtectedScriptIntegrity -ScriptPath $scriptPath)) {
        throw "Protected script integrity check failed after install."
    }

    # Prefer ConstrainedLanguage-friendly invocation: -File under ProgramData, no Bypass when possible.
    # Use Bypass only because some hosts strip Unrestricted; path is ACL-locked + hash-pinned.
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$scriptPath`" -Monitor -IntervalSeconds $IntervalSeconds"
    $trigger = New-ScheduledTaskTrigger -AtLogOn
    $userId = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    if ([string]::IsNullOrWhiteSpace($userId)) {
        if ($env:USERDOMAIN) { $userId = "$env:USERDOMAIN\$env:USERNAME" }
        else { $userId = $env:USERNAME }
    }
    $principal = New-ScheduledTaskPrincipal -UserId $userId -RunLevel Highest -LogonType Interactive
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -StartWhenAvailable -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) `
        -ExecutionTimeLimit ([TimeSpan]::Zero) `
        -MultipleInstances IgnoreNew

    Unregister-ScheduledTask -TaskName $script:TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Register-ScheduledTask -TaskName $script:TaskName -Action $action -Trigger $trigger `
        -Principal $principal -Settings $settings -Force -ErrorAction Stop | Out-Null
    $health = Get-MonitorTaskHealth
    if (-not $health.Healthy) {
        throw "Scheduled task '$($script:TaskName)' installed but failed health validation: $($health.Summary)"
    }
    Write-AppLog "Scheduled task '$($script:TaskName)' installed for $userId (AtLogOn, elevated, monitor mode)."
    Write-AppLog "Task payload: $scriptPath (SHA256=$($installed.Sha256))"
    Write-AuditEvent -Event 'task-installed' -Message "Monitor task installed" -Target $scriptPath -Data @{
        sha256 = $installed.Sha256
        user = $userId
    }
}

function Uninstall-MonitorTask {
    if ($WhatIfPreference) {
        Write-AppLog "WhatIf: would unregister scheduled task '$($script:TaskName)'"
        return
    }
    $task = Get-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue
    if ($null -eq $task) {
        Write-AppLog "Scheduled task '$($script:TaskName)' was not installed."
        return
    }
    Unregister-ScheduledTask -TaskName $script:TaskName -Confirm:$false -ErrorAction Stop
    Write-AppLog "Scheduled task '$($script:TaskName)' removed."
}

if ($UninstallTask) {
    Ensure-AppDirs
    $script:SuppressUiLog = $true
    Uninstall-MonitorTask
    exit 0
}

if ($InstallTask) {
    Ensure-AppDirs
    $script:SuppressUiLog = $true
    Install-MonitorTask
    exit 0
}

if ($TaskHealth) {
    Ensure-AppDirs
    $script:SuppressUiLog = $true
    Write-CliHost (Format-TaskHealthText)
    exit 0
}

if ($RestoreLatestBackup) {
    Ensure-AppDirs
    $script:SuppressUiLog = $true
    try {
        $restored = Restore-LatestRegistryBackup
        Write-CliHost "Restored latest registry backup: $restored"
        exit 0
    } catch {
        Write-AppLog "Restore failed: $($_.Exception.Message)" 'ERROR'
        exit 1
    }
}

if ($DriftReport) {
    Ensure-AppDirs
    $script:SuppressUiLog = $true
    Write-CliHost (Format-DriftReport)
    exit 0
}

if ($AdvancedHarden) {
    Ensure-AppDirs
    $script:SuppressUiLog = $true
    Invoke-AdvancedHardening
    exit 0
}

if ($Monitor) {
    Ensure-AppDirs
    $script:SuppressUiLog = $true
    # Integrity gate for elevated scheduled-task payload (FE-2).
    $protected = Get-ProtectedScriptInstallPath
    if (Test-Path -LiteralPath $protected) {
        if (-not (Test-ProtectedScriptIntegrity -ScriptPath $protected)) {
            Write-AppLog "Refusing to start monitor: protected script hash mismatch (possible tampering): $protected" 'ERROR'
            exit 2
        }
    } elseif (Test-Path -LiteralPath (Join-Path $script:StateDir 'installed-script.sha256')) {
        Write-AppLog 'Refusing to start monitor: installed-script.sha256 present but protected copy missing.' 'ERROR'
        exit 2
    }
    if (-not (Test-EnterMonitorMutex)) {
        Write-AppLog 'Another FinalEclipse monitor is already running. Exiting.' 'WARN'
        exit 1
    }
    $script:MonitorRunning = $true
    Write-AppLog "FinalEclipse headless monitor started (interval ${IntervalSeconds}s). Ctrl+C to stop."
    try {
        Invoke-DisableGdidPipeline
        Invoke-WipeLocalDevicePuid -Quiet | Out-Null
        Invoke-ClearLocalCaches -Quiet | Out-Null

        while ($true) {
            try {
                Invoke-WatchdogTick | Out-Null
            } catch {
                Write-AppLog "Monitor tick error: $($_.Exception.Message)" 'ERROR'
            }
            Start-Sleep -Seconds $IntervalSeconds
        }
    } finally {
        Exit-MonitorMutex
    }
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$form = New-Object System.Windows.Forms.Form
$form.Text = 'FinalEclipse - GDID privacy + live monitor'
$form.Size = New-Object System.Drawing.Size(940, 730)
$form.StartPosition = 'CenterScreen'
$form.MinimumSize = New-Object System.Drawing.Size(820, 620)
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)

$lblHeader = New-Object System.Windows.Forms.Label
$lblHeader.Location = New-Object System.Drawing.Point(12, 10)
$lblHeader.Size = New-Object System.Drawing.Size(900, 42)
$lblHeader.Anchor = 'Top,Left,Right'
$lblHeader.Text = "Scan, harden, and live-monitor Windows GDID exposure. Monitor stops CDP/related services if they restart and continually erases reappearing local device PUID / GDID cache values."

$txtSnap = New-Object System.Windows.Forms.TextBox
$txtSnap.Location = New-Object System.Drawing.Point(12, 55)
$txtSnap.Size = New-Object System.Drawing.Size(900, 260)
$txtSnap.Multiline = $true
$txtSnap.ScrollBars = 'Vertical'
$txtSnap.ReadOnly = $true
$txtSnap.Font = New-Object System.Drawing.Font('Consolas', 9)
$txtSnap.Anchor = 'Top,Left,Right'
$txtSnap.WordWrap = $false

$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Location = New-Object System.Drawing.Point(12, 322)
$lblStatus.Size = New-Object System.Drawing.Size(900, 22)
$lblStatus.Anchor = 'Top,Left,Right'
$lblStatus.ForeColor = [System.Drawing.Color]::DarkRed
$lblStatus.Text = 'Monitor: STOPPED'

$chkDryRun = New-Object System.Windows.Forms.CheckBox
$chkDryRun.Location = New-Object System.Drawing.Point(760, 322)
$chkDryRun.Size = New-Object System.Drawing.Size(152, 22)
$chkDryRun.Anchor = 'Top,Right'
$chkDryRun.Text = 'Dry run'
$chkDryRun.Checked = [bool]$WhatIfPreference

$script:txtLog = New-Object System.Windows.Forms.TextBox
$script:txtLog.Location = New-Object System.Drawing.Point(12, 498)
$script:txtLog.Size = New-Object System.Drawing.Size(900, 174)
$script:txtLog.Multiline = $true
$script:txtLog.ScrollBars = 'Vertical'
$script:txtLog.ReadOnly = $true
$script:txtLog.Font = New-Object System.Drawing.Font('Consolas', 8.5)
$script:txtLog.Anchor = 'Top,Bottom,Left,Right'
$script:txtLog.WordWrap = $false

$lblLog = New-Object System.Windows.Forms.Label
$lblLog.Location = New-Object System.Drawing.Point(12, 478)
$lblLog.Size = New-Object System.Drawing.Size(400, 18)
$lblLog.Text = "Action log  (also: $($script:LogFile))"
$lblLog.Anchor = 'Top,Left'

function New-ActionButton {
    param([string]$Text, [int]$X, [int]$Y, [int]$W = 148, [scriptblock]$OnClick)
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $Text
    $b.Location = New-Object System.Drawing.Point($X, $Y)
    $b.Size = New-Object System.Drawing.Size($W, 30)
    $b.Anchor = 'Top,Left'
    $b.Add_Click($OnClick)
    return $b
}

function Invoke-GuiAction {
    param(
        [Parameter(Mandatory)][scriptblock]$Action,
        [switch]$RefreshAfter
    )
    $oldWhatIf = $WhatIfPreference
    $WhatIfPreference = [bool]$chkDryRun.Checked
    try {
        & $Action
        if ($RefreshAfter) { Refresh-SnapshotUi }
    } finally {
        $WhatIfPreference = $oldWhatIf
    }
}

function Confirm-GuiOperation {
    param(
        [Parameter(Mandatory)][ValidateSet('Wipe','Advanced','Full','Restore')]$Operation,
        [Parameter(Mandatory)][string]$Title
    )
    $oldWhatIf = $WhatIfPreference
    $WhatIfPreference = [bool]$chkDryRun.Checked
    try {
        $plan = Format-OperationPlanText -Operation $Operation
        $txtSnap.Text = $plan
        $message = "$plan`r`nContinue?"
        $r = [System.Windows.Forms.MessageBox]::Show($message, $Title, 'YesNo', 'Warning')
        return ($r -eq 'Yes')
    } finally {
        $WhatIfPreference = $oldWhatIf
    }
}

function Refresh-SnapshotUi {
    try {
        $snap = Get-GdidSnapshot
        $txtSnap.Text = Format-SnapshotText -Snap $snap
    } catch {
        Write-AppLog "Snapshot failed: $($_.Exception.Message)" 'ERROR'
    }
}

function Update-MonitorStatusUi {
    if ($null -ne $script:MonitorProcess -and $script:MonitorProcess.HasExited) {
        Write-AppLog "Owned monitor process exited with code $($script:MonitorProcess.ExitCode)." 'WARN' -RateLimitTicks 1
        $script:MonitorProcess.Dispose()
        $script:MonitorProcess = $null
        $script:MonitorRunning = $false
    }
    if ($script:MonitorRunning) {
        $lblStatus.Text = "Monitor: RUNNING (every ${IntervalSeconds}s) - blocking service restarts + erasing reappearing GDID local values"
        $lblStatus.ForeColor = [System.Drawing.Color]::DarkGreen
        $btnStartMon.Enabled = $false
        $btnStopMon.Enabled = $true
    } else {
        $lblStatus.Text = 'Monitor: STOPPED - services may re-register a device id until you start monitoring'
        $lblStatus.ForeColor = [System.Drawing.Color]::DarkRed
        $btnStartMon.Enabled = $true
        $btnStopMon.Enabled = $false
    }
}

$watchTimer = New-Object System.Windows.Forms.Timer
$watchTimer.Interval = [Math]::Max(2000, $IntervalSeconds * 1000)
$watchTimer.Add_Tick({
    try {
        Update-MonitorStatusUi
        if ($script:MonitorRunning) { Refresh-SnapshotUi }
    } catch {
        Write-AppLog "Monitor status refresh error: $($_.Exception.Message)" 'ERROR'
    }
})

$btnScan = New-ActionButton -Text 'Scan' -X 12 -Y 348 -OnClick {
    Refresh-SnapshotUi
    Write-AppLog 'Snapshot refreshed.'
}
$btnBackup = New-ActionButton -Text 'Backup' -X 168 -Y 348 -OnClick {
    try { Invoke-GuiAction { $null = Export-RegistryBackup } } catch { Write-AppLog $_.Exception.Message 'ERROR' }
}
$btnDisable = New-ActionButton -Text 'Disable pipeline' -X 324 -Y 348 -OnClick {
    try { Invoke-GuiAction { Invoke-DisableGdidPipeline } -RefreshAfter } catch { Write-AppLog $_.Exception.Message 'ERROR' }
}
$btnClear = New-ActionButton -Text 'Clear caches' -X 480 -Y 348 -OnClick {
    try { Invoke-GuiAction { Invoke-ClearLocalCaches | Out-Null } -RefreshAfter } catch { Write-AppLog $_.Exception.Message 'ERROR' }
}
$btnWipe = New-ActionButton -Text 'Wipe local PUID' -X 636 -Y 348 -OnClick {
    if (Confirm-GuiOperation -Operation Wipe -Title 'Confirm wipe') {
        try { Invoke-GuiAction { Invoke-WipeLocalDevicePuid | Out-Null } -RefreshAfter } catch { Write-AppLog $_.Exception.Message 'ERROR' }
    }
}
$btnFull = New-ActionButton -Text 'Full harden' -X 792 -Y 348 -W 120 -OnClick {
    if (Confirm-GuiOperation -Operation Full -Title 'Full harden') {
        try { Invoke-GuiAction { Invoke-FullHarden } -RefreshAfter } catch { Write-AppLog $_.Exception.Message 'ERROR' }
    }
}

$btnStartMon = New-ActionButton -Text 'Start live monitor' -X 12 -Y 382 -W 170 -OnClick {
    try {
        if ($null -ne $script:MonitorProcess -and -not $script:MonitorProcess.HasExited) { return }
        $argList = @('-NoProfile', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass',
            '-File', "`"$PSCommandPath`"", '-Monitor', '-IntervalSeconds', "$IntervalSeconds")
        if ($WhatIfPreference -or $chkDryRun.Checked) { $argList += '-WhatIf' }
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = 'powershell.exe'
        $psi.Arguments = ($argList -join ' ')
        $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
        $psi.UseShellExecute = $true
        $script:MonitorProcess = [Diagnostics.Process]::Start($psi)
        Start-Sleep -Milliseconds 800
        if ($null -eq $script:MonitorProcess -or $script:MonitorProcess.HasExited) {
            $code = if ($null -ne $script:MonitorProcess) { $script:MonitorProcess.ExitCode } else { 'n/a' }
            [System.Windows.Forms.MessageBox]::Show(
                "The hidden monitor did not stay running (exit $code). Another monitor may already own the singleton.",
                'Monitor not started', 'OK', 'Warning') | Out-Null
            $script:MonitorRunning = $false
            Update-MonitorStatusUi
            return
        }
        $script:MonitorRunning = $true
        $script:WatchdogTick = 0
        $script:LogRateLimit = @{}
        $watchTimer.Interval = [Math]::Max(2000, $IntervalSeconds * 1000)
        $watchTimer.Start()
        Update-MonitorStatusUi
        Write-AppLog "Live monitor started (interval ${IntervalSeconds}s)."
        Refresh-SnapshotUi
    } catch {
        Exit-MonitorMutex
        Write-AppLog $_.Exception.Message 'ERROR'
    }
}

$btnStopMon = New-ActionButton -Text 'Stop monitor' -X 190 -Y 382 -W 130 -OnClick {
    $watchTimer.Stop()
    if ($null -ne $script:MonitorProcess -and -not $script:MonitorProcess.HasExited) {
        try {
            $script:MonitorProcess.Kill()
            $script:MonitorProcess.WaitForExit(3000) | Out-Null
        } catch {
            Write-AppLog "Could not stop owned monitor process: $($_.Exception.Message)" 'WARN'
        }
    }
    if ($null -ne $script:MonitorProcess) {
        try { $script:MonitorProcess.Dispose() } catch { }
        $script:MonitorProcess = $null
    }
    $script:MonitorRunning = $false
    Update-MonitorStatusUi
    Write-AppLog 'Live monitor stopped.'
    Refresh-SnapshotUi
}

$btnInstallTask = New-ActionButton -Text 'Install logon task' -X 328 -Y 382 -W 150 -OnClick {
    try {
        Invoke-GuiAction { Install-MonitorTask }
        [System.Windows.Forms.MessageBox]::Show(
            "Task '$($script:TaskName)' will start headless monitor at logon.`r`nLogs: $($script:LogFile)",
            'Task installed', 'OK', 'Information') | Out-Null
    } catch {
        Write-AppLog "Install task failed: $($_.Exception.Message)" 'ERROR'
    }
}

$btnRemoveTask = New-ActionButton -Text 'Remove logon task' -X 486 -Y 382 -W 150 -OnClick {
    try {
        Invoke-GuiAction { Uninstall-MonitorTask }
    } catch {
        Write-AppLog "Remove task failed: $($_.Exception.Message)" 'ERROR'
    }
}

$btnAdvanced = New-ActionButton -Text 'Advanced harden' -X 644 -Y 382 -W 140 -OnClick {
    if (Confirm-GuiOperation -Operation Advanced -Title 'Advanced harden') {
        try { Invoke-GuiAction { Invoke-AdvancedHardening } -RefreshAfter } catch { Write-AppLog $_.Exception.Message 'ERROR' }
    }
}

$btnTaskAudit = New-ActionButton -Text 'Task audit' -X 792 -Y 382 -W 120 -OnClick {
    try {
        $txtSnap.Text = Format-TaskAuditText
        Write-AppLog 'Known scheduled task audit refreshed.'
    } catch {
        Write-AppLog $_.Exception.Message 'ERROR'
    }
}

$btnDrift = New-ActionButton -Text 'Drift report' -X 12 -Y 416 -W 150 -OnClick {
    try {
        $txtSnap.Text = Format-DriftReport
        Write-AppLog 'Drift report generated and baseline updated.'
    } catch {
        Write-AppLog $_.Exception.Message 'ERROR'
    }
}

$btnTaskHealth = New-ActionButton -Text 'Task health' -X 170 -Y 416 -W 150 -OnClick {
    try {
        $txtSnap.Text = Format-TaskHealthText
        Write-AppLog 'Monitor task health checked.'
    } catch {
        Write-AppLog $_.Exception.Message 'ERROR'
    }
}

$btnRestore = New-ActionButton -Text 'Restore latest' -X 328 -Y 416 -W 150 -OnClick {
    if (Confirm-GuiOperation -Operation Restore -Title 'Restore latest backup') {
        try {
            Invoke-GuiAction { $restored = Restore-LatestRegistryBackup; Write-AppLog "Restore finished from $restored" } -RefreshAfter
        } catch {
            Write-AppLog "Restore failed: $($_.Exception.Message)" 'ERROR'
        }
    }
}

$btnEnvironment = New-ActionButton -Text 'Environment' -X 486 -Y 416 -W 150 -OnClick {
    try {
        $txtSnap.Text = Format-EnvironmentReportText
        Write-AppLog 'Environment report refreshed.'
    } catch {
        Write-AppLog $_.Exception.Message 'ERROR'
    }
}

$form.Controls.AddRange(@(
    $lblHeader, $txtSnap, $lblStatus, $chkDryRun, $lblLog, $script:txtLog,
    $btnScan, $btnBackup, $btnDisable, $btnClear, $btnWipe, $btnFull,
    $btnStartMon, $btnStopMon, $btnInstallTask, $btnRemoveTask,
    $btnAdvanced, $btnTaskAudit, $btnDrift, $btnTaskHealth,
    $btnRestore, $btnEnvironment
))

$form.Add_FormClosing({
    if ($watchTimer.Enabled) { $watchTimer.Stop() }
    if ($null -ne $script:MonitorProcess -and -not $script:MonitorProcess.HasExited) {
        try {
            $script:MonitorProcess.Kill()
            $script:MonitorProcess.WaitForExit(3000) | Out-Null
        } catch {
            Write-AppLog "Could not stop owned monitor process during exit: $($_.Exception.Message)" 'WARN'
        }
    }
    if ($null -ne $script:MonitorProcess) {
        try { $script:MonitorProcess.Dispose() } catch { }
        $script:MonitorProcess = $null
    }
    $script:MonitorRunning = $false
    Exit-MonitorMutex
})

$form.Add_Shown({
    Ensure-AppDirs
    Write-AppLog "FinalEclipse running elevated as $env:USERNAME on $env:COMPUTERNAME"
    Write-AppLog "Backups: $script:BackupRoot"
    Write-AppLog "Logs:    $script:LogFile"
    Update-MonitorStatusUi
    Refresh-SnapshotUi
})

[void]$form.ShowDialog()
