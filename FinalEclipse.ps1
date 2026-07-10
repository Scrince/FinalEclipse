[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [switch]$Monitor,
    [int]$IntervalSeconds = 5,
    [switch]$InstallTask,
    [switch]$UninstallTask,
    [switch]$AdvancedHarden,
    [switch]$DriftReport,
    [switch]$TaskHealth,
    [switch]$RestoreLatestBackup
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-IsAdmin)) {
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
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName  = 'powershell.exe'
    $psi.Arguments = ($argList -join ' ')
    $psi.Verb      = 'runas'
    try {
        [Diagnostics.Process]::Start($psi) | Out-Null
    } catch {
        Write-Host 'Administrator rights are required. Relaunch declined.' -ForegroundColor Yellow
    }
    exit
}

$script:AppName     = 'FinalEclipse'
$script:BackupRoot  = Join-Path $env:ProgramData 'FinalEclipse\Backups'
$script:LogDir      = Join-Path $env:ProgramData 'FinalEclipse\Logs'
$script:StateDir    = Join-Path $env:ProgramData 'FinalEclipse\State'
$script:LogFile     = Join-Path $script:LogDir 'monitor.log'
$script:DriftPath   = Join-Path $script:StateDir 'last-snapshot.json'
$script:TaskName    = 'FinalEclipse-Monitor'
$script:MonitorRunning = $false
$script:WatchdogTick = 0
$script:SuppressUiLog = $false
$script:LogRateLimit = @{}
$script:Mutex = $null
$script:MutexName = 'Global\FinalEclipse-Monitor-Singleton'
$script:LogMutexName = 'Global\FinalEclipse-Log-Writer'
$script:txtLog = $null
$script:WatchdogBusy = $false
$script:MonitorProcess = $null
$script:MaxLogBytes = 2MB
$script:MaxUiLogChars = 120000

if ($IntervalSeconds -lt 2) { $IntervalSeconds = 2 }
if ($IntervalSeconds -gt 3600) { $IntervalSeconds = 3600 }

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
    } catch { }
}

function Add-LogLine {
    param([Parameter(Mandatory)][string]$Line)
    Invoke-WithNamedMutex -Name $script:LogMutexName -Action {
        Ensure-AppDirs
        Invoke-LogRotation
        Add-Content -LiteralPath $script:LogFile -Value $Line -Encoding UTF8 -ErrorAction Stop
    } -TimeoutMs 2000
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

    if ($script:SuppressUiLog) {
        Write-Host $line
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
        Write-Host $line
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
    } catch { }

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
    $nowStopped  = ($after.Status -eq 'Stopped' -or $after.Status -eq 'StopPending')
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
    $files = @(Get-ChildItem -LiteralPath $latest.FullName -Filter '*.reg' -File -ErrorAction SilentlyContinue)
    if ($files.Count -eq 0) {
        throw "Latest backup has no .reg files: $($latest.FullName)"
    }
    foreach ($f in $files) {
        if ($WhatIfPreference) {
            Write-AppLog "WhatIf: would import registry backup $($f.FullName)"
            continue
        }
        $p = Start-Process -FilePath 'reg.exe' -ArgumentList @('import', $f.FullName) -Wait -PassThru -WindowStyle Hidden
        if ($null -eq $p -or $p.ExitCode -ne 0) {
            $code = if ($null -ne $p) { $p.ExitCode } else { 'n/a' }
            throw "reg.exe import failed for $($f.FullName) (exit $code)"
        }
        Write-AppLog "Restored registry backup: $($f.FullName)"
    }
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
            } catch { }
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

function Install-MonitorTask {
    $scriptPath = $PSCommandPath
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

    if ($WhatIfPreference) {
        Write-AppLog "WhatIf: would register scheduled task '$($script:TaskName)' for $userId"
        return
    }
    Unregister-ScheduledTask -TaskName $script:TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Register-ScheduledTask -TaskName $script:TaskName -Action $action -Trigger $trigger `
        -Principal $principal -Settings $settings -Force -ErrorAction Stop | Out-Null
    $health = Get-MonitorTaskHealth
    if (-not $health.Healthy) {
        throw "Scheduled task '$($script:TaskName)' installed but failed health validation: $($health.Summary)"
    }
    Write-AppLog "Scheduled task '$($script:TaskName)' installed for $userId (AtLogOn, elevated, monitor mode)."
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
    Write-Host (Format-TaskHealthText)
    exit 0
}

if ($RestoreLatestBackup) {
    Ensure-AppDirs
    $script:SuppressUiLog = $true
    try {
        $restored = Restore-LatestRegistryBackup
        Write-Host "Restored latest registry backup: $restored"
        exit 0
    } catch {
        Write-AppLog "Restore failed: $($_.Exception.Message)" 'ERROR'
        exit 1
    }
}

if ($DriftReport) {
    Ensure-AppDirs
    $script:SuppressUiLog = $true
    Write-Host (Format-DriftReport)
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

$script:txtLog = New-Object System.Windows.Forms.TextBox
$script:txtLog.Location = New-Object System.Drawing.Point(12, 464)
$script:txtLog.Size = New-Object System.Drawing.Size(900, 208)
$script:txtLog.Multiline = $true
$script:txtLog.ScrollBars = 'Vertical'
$script:txtLog.ReadOnly = $true
$script:txtLog.Font = New-Object System.Drawing.Font('Consolas', 8.5)
$script:txtLog.Anchor = 'Top,Bottom,Left,Right'
$script:txtLog.WordWrap = $false

$lblLog = New-Object System.Windows.Forms.Label
$lblLog.Location = New-Object System.Drawing.Point(12, 444)
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
    try { $null = Export-RegistryBackup } catch { Write-AppLog $_.Exception.Message 'ERROR' }
}
$btnDisable = New-ActionButton -Text 'Disable pipeline' -X 324 -Y 348 -OnClick {
    try { Invoke-DisableGdidPipeline; Refresh-SnapshotUi } catch { Write-AppLog $_.Exception.Message 'ERROR' }
}
$btnClear = New-ActionButton -Text 'Clear caches' -X 480 -Y 348 -OnClick {
    try { Invoke-ClearLocalCaches | Out-Null; Refresh-SnapshotUi } catch { Write-AppLog $_.Exception.Message 'ERROR' }
}
$btnWipe = New-ActionButton -Text 'Wipe local PUID' -X 636 -Y 348 -OnClick {
    $r = [System.Windows.Forms.MessageBox]::Show(
        "Removes local IdentityCRL device id values.`r`nMSA device features may break until re-registration.`r`nContinue?",
        'Confirm wipe', 'YesNo', 'Warning')
    if ($r -eq 'Yes') {
        try { Invoke-WipeLocalDevicePuid | Out-Null; Refresh-SnapshotUi } catch { Write-AppLog $_.Exception.Message 'ERROR' }
    }
}
$btnFull = New-ActionButton -Text 'Full harden' -X 792 -Y 348 -W 120 -OnClick {
    $r = [System.Windows.Forms.MessageBox]::Show(
        'Backup + disable pipeline + clear caches + wipe local PUID. Continue?',
        'Full harden', 'YesNo', 'Warning')
    if ($r -eq 'Yes') {
        try { Invoke-FullHarden; Refresh-SnapshotUi } catch { Write-AppLog $_.Exception.Message 'ERROR' }
    }
}

$btnStartMon = New-ActionButton -Text 'Start live monitor' -X 12 -Y 382 -W 170 -OnClick {
    try {
        if ($null -ne $script:MonitorProcess -and -not $script:MonitorProcess.HasExited) { return }
        $argList = @('-NoProfile', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass',
            '-File', "`"$PSCommandPath`"", '-Monitor', '-IntervalSeconds', "$IntervalSeconds")
        if ($WhatIfPreference) { $argList += '-WhatIf' }
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
        Install-MonitorTask
        [System.Windows.Forms.MessageBox]::Show(
            "Task '$($script:TaskName)' will start headless monitor at logon.`r`nLogs: $($script:LogFile)",
            'Task installed', 'OK', 'Information') | Out-Null
    } catch {
        Write-AppLog "Install task failed: $($_.Exception.Message)" 'ERROR'
    }
}

$btnRemoveTask = New-ActionButton -Text 'Remove logon task' -X 486 -Y 382 -W 150 -OnClick {
    try {
        Uninstall-MonitorTask
    } catch {
        Write-AppLog "Remove task failed: $($_.Exception.Message)" 'ERROR'
    }
}

$btnAdvanced = New-ActionButton -Text 'Advanced harden' -X 644 -Y 382 -W 140 -OnClick {
    $r = [System.Windows.Forms.MessageBox]::Show(
        'Clears service recovery actions, disables curated telemetry scheduled tasks, reapplies policies, and checks monitor task health. Continue?',
        'Advanced harden', 'YesNo', 'Warning')
    if ($r -eq 'Yes') {
        try { Invoke-AdvancedHardening; Refresh-SnapshotUi } catch { Write-AppLog $_.Exception.Message 'ERROR' }
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

$form.Controls.AddRange(@(
    $lblHeader, $txtSnap, $lblStatus, $lblLog, $script:txtLog,
    $btnScan, $btnBackup, $btnDisable, $btnClear, $btnWipe, $btnFull,
    $btnStartMon, $btnStopMon, $btnInstallTask, $btnRemoveTask,
    $btnAdvanced, $btnTaskAudit, $btnDrift, $btnTaskHealth
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
