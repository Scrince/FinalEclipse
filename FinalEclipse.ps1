[CmdletBinding()]
param(
    [switch]$Monitor,
    [int]$IntervalSeconds = 5,
    [switch]$InstallTask,
    [switch]$UninstallTask,
    [switch]$AdvancedHarden,
    [switch]$DriftReport,
    [switch]$TaskHealth
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
$script:txtLog = $null
$script:WatchdogBusy = $false
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
        Ensure-AppDirs
        Invoke-LogRotation
        Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
    } catch { }

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
        Write-AppLog "Mutex acquire failed (continuing without singleton): $($_.Exception.Message)" 'WARN'
        return $true
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
            Healthy = $false
            Summary = 'Not installed'
        }
    }

    $actions = @($task.Actions | ForEach-Object {
        "$($_.Execute) $($_.Arguments)"
    })
    $actionText = ($actions -join ' ; ')
    $healthy = ($task.State -ne 'Disabled' -and
        $actionText -match [regex]::Escape($PSCommandPath) -and
        $actionText -match '-Monitor')

    return [pscustomobject]@{
        Installed = $true
        Enabled = ($task.State -ne 'Disabled')
        RunLevel = [string]$task.Principal.RunLevel
        Action = $actionText
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
        try {
            Stop-Service -Name $Name -Force -ErrorAction Stop
        } catch {
            & sc.exe stop "$Name" 2>$null | Out-Null
        }
        Start-Sleep -Milliseconds 250
    }
    if ($neededDisable) {
        try {
            Set-Service -Name $Name -StartupType Disabled -ErrorAction Stop
        } catch {
            & sc.exe config "$Name" start= disabled 2>$null | Out-Null
        }
    }

    $after = Get-Service -Name $Name -ErrorAction SilentlyContinue
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

    $exports = @(
        @{ File = 'IdentityCRL.reg'; Path = 'HKCU\SOFTWARE\Microsoft\IdentityCRL' },
        @{ File = 'IrisService.reg'; Path = 'HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\IrisService' },
        @{ File = 'AdvertisingInfo.reg'; Path = 'HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\AdvertisingInfo' }
    )

    foreach ($e in $exports) {
        $out = Join-Path $dir $e.File
        try {
            $p = Start-Process -FilePath 'reg.exe' -ArgumentList @('export', $e.Path, $out, '/y') -Wait -PassThru -WindowStyle Hidden
            if ($null -ne $p -and $p.ExitCode -eq 0) {
                Write-AppLog "Backed up $($e.Path) -> $out"
            } else {
                $code = if ($null -ne $p) { $p.ExitCode } else { 'n/a' }
                Write-AppLog "Backup skipped/failed for $($e.Path) (exit $code)" 'WARN'
            }
        } catch {
            Write-AppLog "Backup error for $($e.Path): $($_.Exception.Message)" 'WARN'
        }
    }

    $snap = Get-GdidSnapshot
    $snapPath = Join-Path $dir 'snapshot.txt'
    Format-SnapshotText -Snap $snap | Set-Content -Path $snapPath -Encoding UTF8
    Write-AppLog "Snapshot written: $snapPath"
    return $dir
}

function Invoke-AssertPrivacyPolicies {
    Set-DwordPolicy -Path $ActivityHistory -Name 'EnableActivityFeed' -Value 0
    Set-DwordPolicy -Path $ActivityHistory -Name 'PublishUserActivities' -Value 0
    Set-DwordPolicy -Path $ActivityHistory -Name 'UploadUserActivities' -Value 0
    Set-DwordPolicy -Path $DiagTrackPolicy -Name 'AllowTelemetry' -Value 1
    Set-DwordPolicy -Path $AdvertisingId -Name 'Enabled' -Value 0
    Remove-ItemProperty -LiteralPath $AdvertisingId -Name 'Id' -ErrorAction SilentlyContinue
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
            Disable-ScheduledTask -TaskPath $parts.TaskPath -TaskName $parts.TaskName -ErrorAction Stop | Out-Null
            $changed++
            if (-not $Quiet) { Write-AppLog "Disabled known telemetry task: $full" }
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
    $body | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $script:DriftPath -Encoding UTF8
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
            Remove-Item -LiteralPath $IrisServiceKey -Recurse -Force -ErrorAction Stop
            $did = $true
            if ($Quiet) { Write-AppLog 'Monitor: erased IrisService cache' 'WARN' -RateLimitTicks 6 }
            else { Write-AppLog 'Removed IrisService registry tree.' }
        } catch {
            Write-AppLog "Could not remove IrisService: $($_.Exception.Message)" 'WARN' -RateLimitTicks 12
        }
    }

    if (Test-Path -LiteralPath $CDPLocal) {
        try {
            Remove-Item -LiteralPath $CDPLocal -Recurse -Force -ErrorAction Stop
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
                Remove-ItemProperty -LiteralPath $IdentityExtProps -Name $name -ErrorAction SilentlyContinue
                $did = $true
                if ($Quiet) { Write-AppLog "Monitor: wiped ExtendedProperties\$name" 'WARN' -RateLimitTicks 6 }
                else { Write-AppLog "Removed ExtendedProperties\$name" }
            }
        }
    }

    if (Test-Path -LiteralPath $IdentityImmersive) {
        Get-ChildItem -LiteralPath $IdentityImmersive -ErrorAction SilentlyContinue | ForEach-Object {
            foreach ($name in @('DeviceId', 'LID')) {
                if ($null -ne (Get-SafeRegValue -Path $_.PSPath -Name $name)) {
                    Remove-ItemProperty -LiteralPath $_.PSPath -Name $name -ErrorAction SilentlyContinue
                    $did = $true
                    if ($Quiet) { Write-AppLog "Monitor: wiped token $name under $($_.PSChildName)" 'WARN' -RateLimitTicks 6 }
                    else { Write-AppLog "Removed $name under $($_.PSChildName)" }
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
                    Remove-ItemProperty -LiteralPath $_.PSPath -Name $name -ErrorAction SilentlyContinue
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
    $null = Export-RegistryBackup
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

    Unregister-ScheduledTask -TaskName $script:TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Register-ScheduledTask -TaskName $script:TaskName -Action $action -Trigger $trigger `
        -Principal $principal -Settings $settings -Force | Out-Null
    Write-AppLog "Scheduled task '$($script:TaskName)' installed for $userId (AtLogOn, elevated, monitor mode)."
}

function Uninstall-MonitorTask {
    Unregister-ScheduledTask -TaskName $script:TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Write-AppLog "Scheduled task '$($script:TaskName)' removed (if it existed)."
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
        $n = Invoke-WatchdogTick
        if ($n -gt 0) { Refresh-SnapshotUi }
    } catch {
        Write-AppLog "Watchdog error: $($_.Exception.Message)" 'ERROR'
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
        if (-not (Test-EnterMonitorMutex)) {
            [System.Windows.Forms.MessageBox]::Show(
                'Another FinalEclipse monitor is already running (GUI or logon task). Stop it first.',
                'Monitor already running', 'OK', 'Warning') | Out-Null
            return
        }
        Invoke-DisableGdidPipeline
        Invoke-WipeLocalDevicePuid -Quiet | Out-Null
        Invoke-ClearLocalCaches -Quiet | Out-Null
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
    $script:MonitorRunning = $false
    Exit-MonitorMutex
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
