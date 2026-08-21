[CmdletBinding()]
param(
    [ValidateSet('Status', 'Start', 'Stop', 'Reset', 'Deploy', 'Smoke', 'Scenario')]
    [string]$Action = 'Status',

    [ValidateSet('A', 'B', 'All')]
    [string]$Vm = 'All',

    [string]$ExePath,

    [string]$InstalledPayloadPath,

    [ValidateSet('Portable', 'Install', 'Service', 'SingleGui', 'Wss')]
    [string]$Scenario,

    [string]$SnapshotName,

    [string]$ConfigPath = 'D:\Vms\MasterDeskLab\lab-config.psd1',

    [switch]$SkipScenarioReset,

    [ValidateRange(30, 900)]
    [int]$TimeoutSeconds = 240
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$script:RepoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$script:RunId = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
$script:ArtifactRoot = Join-Path $script:RepoRoot ("artifacts\lab\{0}" -f $script:RunId)
$script:GuestPassword = $null
$script:Failures = 0

New-Item -ItemType Directory -Path $script:ArtifactRoot -Force | Out-Null

function ConvertTo-SafeText {
    param([AllowNull()][object]$Value)

    $text = if ($null -eq $Value) { '' } else { [string]$Value }
    if (-not [string]::IsNullOrEmpty($script:GuestPassword)) {
        $text = $text.Replace($script:GuestPassword, '<redacted>')
    }
    return $text
}

function Get-ShortTail {
    param(
        [string]$LogPath,
        [object[]]$Fallback = @()
    )

    $lines = @()
    if (Test-Path -LiteralPath $LogPath) {
        $lines = @(Get-Content -LiteralPath $LogPath -Tail 4 -ErrorAction SilentlyContinue)
    }
    if ($lines.Count -eq 0) {
        $lines = @($Fallback | Select-Object -Last 4)
    }
    $tail = (($lines | ForEach-Object { ConvertTo-SafeText $_ }) -join ' | ')
    $tail = $tail -replace '[\r\n\t]+', ' '
    if ($tail.Length -gt 280) {
        $tail = $tail.Substring($tail.Length - 280)
    }
    return $tail.Replace('"', "'")
}

function Write-Pass {
    param(
        [string]$CurrentAction,
        [string]$VmLabel,
        [string]$Details
    )

    Write-Output (("PASS action={0} vm={1} {2}" -f $CurrentAction, $VmLabel, $Details).TrimEnd())
}

function Write-Fail {
    param(
        [string]$CurrentAction,
        [string]$VmLabel,
        [string]$Stage,
        [int]$ExitCode,
        [string]$LogPath,
        [object[]]$Fallback = @()
    )

    $script:Failures++
    $tail = Get-ShortTail -LogPath $LogPath -Fallback $Fallback
    Write-Output ("FAIL action={0} vm={1} stage={2} exit={3} log={4} tail=""{5}""" -f `
        $CurrentAction, $VmLabel, $Stage, $ExitCode, $LogPath, $tail)
}

function Assert-LabConfig {
    param([hashtable]$Config)

    foreach ($key in @(
        'Vmrun', 'VmA', 'VmB', 'VmAName', 'VmBName',
        'VmASnapshotClean', 'VmASnapshotRegistered', 'VmBSnapshotBase', 'GuestUser'
    )) {
        if (-not $Config.ContainsKey($key) -or [string]::IsNullOrWhiteSpace([string]$Config[$key])) {
            throw "Missing required lab configuration key: $key"
        }
    }
    if (-not (Test-Path -LiteralPath $Config.Vmrun -PathType Leaf)) {
        throw "vmrun was not found at configured path: $($Config.Vmrun)"
    }
}

function Get-VmDefinitions {
    param([hashtable]$Config)

    $definitions = @(
        [pscustomobject]@{
            Label           = 'A'
            Name            = [string]$Config.VmAName
            Vmx             = [string]$Config.VmA
            DefaultSnapshot = [string]$Config.VmASnapshotRegistered
            CleanSnapshot   = [string]$Config.VmASnapshotClean
        },
        [pscustomobject]@{
            Label           = 'B'
            Name            = [string]$Config.VmBName
            Vmx             = [string]$Config.VmB
            DefaultSnapshot = [string]$Config.VmBSnapshotBase
            CleanSnapshot   = if ($Config.ContainsKey('VmBSnapshotRdpOn')) {
                [string]$Config.VmBSnapshotRdpOn
            } else {
                $null
            }
        }
    )

    if ($Vm -eq 'All') {
        return $definitions
    }
    return @($definitions | Where-Object { $_.Label -eq $Vm })
}

function Get-VmSnapshots {
    param(
        [hashtable]$Config,
        [pscustomobject]$Definition,
        [string]$LogPath
    )

    $response = Invoke-Vmrun -Config $Config `
        -Arguments @('listSnapshots', $Definition.Vmx) -LogPath $LogPath
    $snapshots = if ($response.ExitCode -eq 0) {
        @($response.Output | Select-Object -Skip 1 | ForEach-Object { $_.Trim() } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    } else {
        @()
    }
    return [pscustomobject]@{
        Success = $response.ExitCode -eq 0
        Names = $snapshots
        Response = $response
    }
}

function New-VmArtifactDirectory {
    param([pscustomobject]$Definition)

    $path = Join-Path $script:ArtifactRoot ("vm-{0}" -f $Definition.Label)
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    return $path
}

function Invoke-Vmrun {
    param(
        [hashtable]$Config,
        [object[]]$Arguments,
        [string]$LogPath,
        [switch]$Guest
    )

    $actualArguments = New-Object System.Collections.Generic.List[object]
    $safeArguments = New-Object System.Collections.Generic.List[string]
    $actualArguments.Add('-T')
    $actualArguments.Add('ws')
    $safeArguments.Add('-T')
    $safeArguments.Add('ws')

    if ($Guest) {
        $actualArguments.Add('-gu')
        $actualArguments.Add([string]$Config.GuestUser)
        $actualArguments.Add('-gp')
        $actualArguments.Add($script:GuestPassword)
        $safeArguments.Add('-gu')
        $safeArguments.Add([string]$Config.GuestUser)
        $safeArguments.Add('-gp')
        $safeArguments.Add('<redacted>')
    }

    foreach ($argument in $Arguments) {
        $actualArguments.Add($argument)
        $safeArguments.Add((ConvertTo-SafeText $argument))
    }

    $started = Get-Date
    $rawOutput = @(& $Config.Vmrun @actualArguments 2>&1)
    $exitCode = $LASTEXITCODE
    $safeOutput = @($rawOutput | ForEach-Object { ConvertTo-SafeText $_ })

    $logLines = @(
        "timestamp=$($started.ToUniversalTime().ToString('o'))",
        "command=vmrun $($safeArguments -join ' ')",
        "exitCode=$exitCode",
        'output:'
    ) + $safeOutput
    $logLines | Set-Content -LiteralPath $LogPath -Encoding UTF8

    return [pscustomobject]@{
        ExitCode = [int]$exitCode
        Output   = $safeOutput
        LogPath  = $LogPath
    }
}

function Test-VmPoweredOn {
    param(
        [hashtable]$Config,
        [pscustomobject]$Definition,
        [string]$LogPath
    )

    $response = Invoke-Vmrun -Config $Config -Arguments @('list') -LogPath $LogPath
    if ($response.ExitCode -ne 0) {
        return [pscustomobject]@{ Success = $false; PoweredOn = $false; Response = $response }
    }
    $poweredOn = @($response.Output | Where-Object {
        [string]::Equals($_.Trim(), $Definition.Vmx, [StringComparison]::OrdinalIgnoreCase)
    }).Count -gt 0
    return [pscustomobject]@{ Success = $true; PoweredOn = $poweredOn; Response = $response }
}

function Get-ToolsState {
    param(
        [hashtable]$Config,
        [pscustomobject]$Definition,
        [string]$LogPath
    )

    $response = Invoke-Vmrun -Config $Config `
        -Arguments @('checkToolsState', $Definition.Vmx) -LogPath $LogPath
    $state = if ($response.Output.Count -gt 0) {
        [string]($response.Output | Select-Object -Last 1)
    } else {
        'unknown'
    }
    return [pscustomobject]@{
        Success  = $response.ExitCode -eq 0
        State    = $state.Trim()
        Response = $response
    }
}

function Wait-VmPoweredState {
    param(
        [hashtable]$Config,
        [pscustomobject]$Definition,
        [bool]$PoweredOn,
        [string]$LogDirectory,
        [int]$Seconds
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
    $attempt = 0
    do {
        $attempt++
        $state = Test-VmPoweredOn -Config $Config -Definition $Definition `
            -LogPath (Join-Path $LogDirectory ("power-wait-{0}.log" -f $attempt))
        if ($state.Success -and $state.PoweredOn -eq $PoweredOn) {
            return [pscustomobject]@{ Success = $true; Response = $state.Response }
        }
        Start-Sleep -Seconds 2
    } while ([DateTime]::UtcNow -lt $deadline)

    return [pscustomobject]@{ Success = $false; Response = $state.Response }
}

function Wait-ToolsRunning {
    param(
        [hashtable]$Config,
        [pscustomobject]$Definition,
        [string]$LogDirectory,
        [int]$Seconds
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
    $attempt = 0
    do {
        $attempt++
        $tools = Get-ToolsState -Config $Config -Definition $Definition `
            -LogPath (Join-Path $LogDirectory ("tools-wait-{0}.log" -f $attempt))
        if ($tools.Success -and $tools.State -eq 'running') {
            return [pscustomobject]@{ Success = $true; Response = $tools.Response }
        }
        Start-Sleep -Seconds 2
    } while ([DateTime]::UtcNow -lt $deadline)

    return [pscustomobject]@{ Success = $false; Response = $tools.Response }
}

function Ensure-VmStarted {
    param(
        [hashtable]$Config,
        [pscustomobject]$Definition,
        [string]$LogDirectory
    )

    $power = Test-VmPoweredOn -Config $Config -Definition $Definition `
        -LogPath (Join-Path $LogDirectory 'power-before-start.log')
    if (-not $power.Success) {
        return [pscustomobject]@{ Success = $false; Stage = 'power-state'; Response = $power.Response }
    }
    if (-not $power.PoweredOn) {
        $start = Invoke-Vmrun -Config $Config -Arguments @('start', $Definition.Vmx, 'nogui') `
            -LogPath (Join-Path $LogDirectory 'start.log')
        if ($start.ExitCode -ne 0) {
            return [pscustomobject]@{ Success = $false; Stage = 'start'; Response = $start }
        }
        $powerWait = Wait-VmPoweredState -Config $Config -Definition $Definition -PoweredOn $true `
            -LogDirectory $LogDirectory -Seconds $TimeoutSeconds
        if (-not $powerWait.Success) {
            return [pscustomobject]@{ Success = $false; Stage = 'power-on-timeout'; Response = $powerWait.Response }
        }
    }

    $toolsWait = Wait-ToolsRunning -Config $Config -Definition $Definition `
        -LogDirectory $LogDirectory -Seconds $TimeoutSeconds
    if (-not $toolsWait.Success) {
        return [pscustomobject]@{ Success = $false; Stage = 'tools-timeout'; Response = $toolsWait.Response }
    }
    return [pscustomobject]@{ Success = $true; Stage = 'ready'; Response = $toolsWait.Response }
}

function Stop-VmSoft {
    param(
        [hashtable]$Config,
        [pscustomobject]$Definition,
        [string]$LogDirectory
    )

    $power = Test-VmPoweredOn -Config $Config -Definition $Definition `
        -LogPath (Join-Path $LogDirectory 'power-before-stop.log')
    if (-not $power.Success) {
        return [pscustomobject]@{ Success = $false; Stage = 'power-state'; Response = $power.Response }
    }
    if (-not $power.PoweredOn) {
        return [pscustomobject]@{ Success = $true; Stage = 'already-stopped'; Response = $power.Response }
    }

    $stop = Invoke-Vmrun -Config $Config -Arguments @('stop', $Definition.Vmx, 'soft') `
        -LogPath (Join-Path $LogDirectory 'stop-soft.log')
    if ($stop.ExitCode -ne 0) {
        $afterFailedStop = Test-VmPoweredOn -Config $Config -Definition $Definition `
            -LogPath (Join-Path $LogDirectory 'power-after-failed-stop.log')
        if ($afterFailedStop.Success -and -not $afterFailedStop.PoweredOn) {
            return [pscustomobject]@{
                Success = $true
                Stage = 'already-stopped-after-race'
                Response = $afterFailedStop.Response
            }
        }
        return [pscustomobject]@{ Success = $false; Stage = 'stop-soft'; Response = $stop }
    }
    $powerWait = Wait-VmPoweredState -Config $Config -Definition $Definition -PoweredOn $false `
        -LogDirectory $LogDirectory -Seconds $TimeoutSeconds
    if (-not $powerWait.Success) {
        return [pscustomobject]@{ Success = $false; Stage = 'stop-timeout'; Response = $powerWait.Response }
    }
    return [pscustomobject]@{ Success = $true; Stage = 'stopped'; Response = $powerWait.Response }
}

function Reset-VmToSnapshot {
    param(
        [hashtable]$Config,
        [pscustomobject]$Definition,
        [string]$Snapshot,
        [string]$LogDirectory
    )

    $snapshots = Get-VmSnapshots -Config $Config -Definition $Definition `
        -LogPath (Join-Path $LogDirectory 'list-snapshots.log')
    if (-not $snapshots.Success) {
        return [pscustomobject]@{ Success = $false; Stage = 'list-snapshots'; Response = $snapshots.Response }
    }
    if ($snapshots.Names -notcontains $Snapshot) {
        $setupLog = Join-Path $LogDirectory 'snapshot-required.log'
        "Required snapshot '$Snapshot' does not exist. Available: $($snapshots.Names -join ', ')" |
            Set-Content -LiteralPath $setupLog -Encoding UTF8
        return [pscustomobject]@{
            Success = $false
            Stage = 'setup-required'
            Response = [pscustomobject]@{ ExitCode = 1; Output = @(); LogPath = $setupLog }
        }
    }

    $stop = Stop-VmSoft -Config $Config -Definition $Definition -LogDirectory $LogDirectory
    if (-not $stop.Success) {
        return $stop
    }
    $revert = Invoke-Vmrun -Config $Config `
        -Arguments @('revertToSnapshot', $Definition.Vmx, $Snapshot) `
        -LogPath (Join-Path $LogDirectory 'revert-snapshot.log')
    if ($revert.ExitCode -ne 0) {
        return [pscustomobject]@{ Success = $false; Stage = 'revert-snapshot'; Response = $revert }
    }
    return [pscustomobject]@{ Success = $true; Stage = 'reset'; Response = $revert }
}

function Test-GuestAccess {
    param(
        [hashtable]$Config,
        [pscustomobject]$Definition,
        [string]$LogPath
    )

    return Invoke-Vmrun -Config $Config -Guest `
        -Arguments @('listProcessesInGuest', $Definition.Vmx) -LogPath $LogPath
}

function Initialize-GuestLabDirectory {
    param(
        [hashtable]$Config,
        [pscustomobject]$Definition,
        [string]$LogPath
    )

    $existsLog = [System.IO.Path]::ChangeExtension($LogPath, '.exists.log')
    $exists = Invoke-Vmrun -Config $Config -Guest -Arguments @(
        'directoryExistsInGuest', $Definition.Vmx, 'C:\MasterDeskLab'
    ) -LogPath $existsLog
    if ($exists.ExitCode -eq 0) {
        return $exists
    }

    return Invoke-Vmrun -Config $Config -Guest -Arguments @(
        'createDirectoryInGuest', $Definition.Vmx, 'C:\MasterDeskLab'
    ) -LogPath $LogPath
}

function Copy-CandidateToGuest {
    param(
        [hashtable]$Config,
        [pscustomobject]$Definition,
        [string]$ResolvedExePath,
        [AllowNull()][string]$ResolvedInstalledPayloadPath,
        [string]$LogDirectory
    )

    $initialize = Initialize-GuestLabDirectory -Config $Config -Definition $Definition `
        -LogPath (Join-Path $LogDirectory 'guest-directory.log')
    if ($initialize.ExitCode -ne 0) {
        return [pscustomobject]@{ Success = $false; Stage = 'guest-directory'; Response = $initialize }
    }

    $guestExe = "C:\MasterDeskLab\$([System.IO.Path]::GetFileName($ResolvedExePath))"
    $copy = Invoke-Vmrun -Config $Config -Guest -Arguments @(
        'copyFileFromHostToGuest', $Definition.Vmx, $ResolvedExePath, $guestExe
    ) -LogPath (Join-Path $LogDirectory 'deploy-exe.log')
    if ($copy.ExitCode -ne 0) {
        return [pscustomobject]@{ Success = $false; Stage = 'copy-exe'; Response = $copy }
    }

    $hostMarker = Join-Path $LogDirectory 'candidate-path.txt'
    $guestMarker = 'C:\MasterDeskLab\candidate-path.txt'
    $guestExe | Set-Content -LiteralPath $hostMarker -Encoding ASCII
    $copyMarker = Invoke-Vmrun -Config $Config -Guest -Arguments @(
        'copyFileFromHostToGuest', $Definition.Vmx, $hostMarker, $guestMarker
    ) -LogPath (Join-Path $LogDirectory 'deploy-marker.log')
    if ($copyMarker.ExitCode -ne 0) {
        return [pscustomobject]@{ Success = $false; Stage = 'copy-marker'; Response = $copyMarker }
    }

    $hostSha256 = (Get-FileHash -LiteralPath $ResolvedExePath -Algorithm SHA256).Hash
    $hostMetadata = Join-Path $LogDirectory 'candidate-metadata.json'
    [ordered]@{
        GuestPath = $guestExe
        HostSha256 = $hostSha256
        Length = (Get-Item -LiteralPath $ResolvedExePath).Length
        ExpectedInstalledSha256 = if ([string]::IsNullOrWhiteSpace($ResolvedInstalledPayloadPath)) {
            $null
        } else {
            (Get-FileHash -LiteralPath $ResolvedInstalledPayloadPath -Algorithm SHA256).Hash
        }
        ExpectedInstalledLength = if ([string]::IsNullOrWhiteSpace($ResolvedInstalledPayloadPath)) {
            $null
        } else {
            (Get-Item -LiteralPath $ResolvedInstalledPayloadPath).Length
        }
    } | ConvertTo-Json | Set-Content -LiteralPath $hostMetadata -Encoding UTF8
    $copyMetadata = Invoke-Vmrun -Config $Config -Guest -Arguments @(
        'copyFileFromHostToGuest', $Definition.Vmx, $hostMetadata,
        'C:\MasterDeskLab\candidate-metadata.json'
    ) -LogPath (Join-Path $LogDirectory 'deploy-metadata.log')
    if ($copyMetadata.ExitCode -ne 0) {
        return [pscustomobject]@{ Success = $false; Stage = 'copy-metadata'; Response = $copyMetadata }
    }

    return [pscustomobject]@{
        Success = $true
        Stage = 'complete'
        Response = $copyMetadata
        GuestExe = $guestExe
        HostSha256 = $hostSha256
    }
}

function Invoke-GuestProbe {
    param(
        [hashtable]$Config,
        [pscustomobject]$Definition,
        [ValidateSet('Status', 'Smoke')]
        [string]$Mode,
        [string]$LogDirectory
    )

    $guestScript = 'C:\MasterDeskLab\Invoke-MasterDeskGuestProbe.ps1'
    $guestResult = "C:\MasterDeskLab\probe-$($script:RunId)-$($Definition.Label)-$Mode.json"
    $guestLogs = "C:\MasterDeskLab\logs-$($script:RunId)-$($Definition.Label).zip"
    $hostResult = Join-Path $LogDirectory ("probe-{0}.json" -f $Mode.ToLowerInvariant())
    $hostLogs = Join-Path $LogDirectory 'MasterDesk-logs.zip'

    $initialize = Initialize-GuestLabDirectory -Config $Config -Definition $Definition `
        -LogPath (Join-Path $LogDirectory 'guest-directory.log')
    if ($initialize.ExitCode -ne 0) {
        return [pscustomobject]@{ Success = $false; Stage = 'guest-directory'; Response = $initialize }
    }

    $copyScript = Invoke-Vmrun -Config $Config -Guest -Arguments @(
        'copyFileFromHostToGuest', $Definition.Vmx,
        (Join-Path $PSScriptRoot 'Invoke-MasterDeskGuestProbe.ps1'), $guestScript
    ) -LogPath (Join-Path $LogDirectory 'copy-probe.log')
    if ($copyScript.ExitCode -ne 0) {
        return [pscustomobject]@{ Success = $false; Stage = 'copy-probe'; Response = $copyScript }
    }

    $guestPowerShell = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
    $arguments = @(
        'runProgramInGuest', $Definition.Vmx, $guestPowerShell,
        '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
        '-File', $guestScript, '-Mode', $Mode, '-OutputPath', $guestResult
    )
    if ($Mode -eq 'Smoke') {
        $arguments += @('-LogArchivePath', $guestLogs)
    }
    $runProbe = Invoke-Vmrun -Config $Config -Guest -Arguments $arguments `
        -LogPath (Join-Path $LogDirectory ("run-probe-{0}.log" -f $Mode.ToLowerInvariant()))
    if ($runProbe.ExitCode -ne 0) {
        return [pscustomobject]@{ Success = $false; Stage = 'run-probe'; Response = $runProbe }
    }

    $copyResult = Invoke-Vmrun -Config $Config -Guest -Arguments @(
        'copyFileFromGuestToHost', $Definition.Vmx, $guestResult, $hostResult
    ) -LogPath (Join-Path $LogDirectory 'copy-result.log')
    if ($copyResult.ExitCode -ne 0) {
        return [pscustomobject]@{ Success = $false; Stage = 'copy-result'; Response = $copyResult }
    }

    try {
        $probe = Get-Content -LiteralPath $hostResult -Raw | ConvertFrom-Json
    } catch {
        $parseLog = Join-Path $LogDirectory 'parse-result.log'
        (ConvertTo-SafeText $_.Exception.Message) | Set-Content -LiteralPath $parseLog -Encoding UTF8
        return [pscustomobject]@{
            Success = $false
            Stage = 'parse-result'
            Response = [pscustomobject]@{ ExitCode = 1; Output = @($_.Exception.Message); LogPath = $parseLog }
        }
    }

    if ($Mode -eq 'Smoke' -and -not [string]::IsNullOrWhiteSpace([string]$probe.LogArchive)) {
        $copyLogs = Invoke-Vmrun -Config $Config -Guest -Arguments @(
            'copyFileFromGuestToHost', $Definition.Vmx, $guestLogs, $hostLogs
        ) -LogPath (Join-Path $LogDirectory 'copy-logs.log')
        if ($copyLogs.ExitCode -ne 0) {
            return [pscustomobject]@{ Success = $false; Stage = 'copy-logs'; Response = $copyLogs; Probe = $probe }
        }
    }

    return [pscustomobject]@{
        Success = $true
        Stage = 'complete'
        Response = $copyResult
        Probe = $probe
        ResultPath = $hostResult
        LogArchivePath = if (Test-Path -LiteralPath $hostLogs) { $hostLogs } else { $null }
    }
}

function Wait-InteractiveDesktop {
    param(
        [hashtable]$Config,
        [pscustomobject]$Definition,
        [string]$LogDirectory,
        [int]$Seconds
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
    $last = $null
    do {
        $last = Invoke-GuestProbe -Config $Config -Definition $Definition `
            -Mode Status -LogDirectory $LogDirectory
        if ($last.Success -and @($last.Probe.DesktopSessions).Count -gt 0) {
            Start-Sleep -Seconds 3
            return [pscustomobject]@{ Success = $true; Response = $last.Response }
        }
        Start-Sleep -Seconds 2
    } while ([DateTime]::UtcNow -lt $deadline)

    if ($null -ne $last) {
        return [pscustomobject]@{ Success = $false; Response = $last.Response }
    }
    $log = Join-Path $LogDirectory 'desktop-session-timeout.log'
    'No interactive desktop session appeared before timeout.' |
        Set-Content -LiteralPath $log -Encoding UTF8
    return [pscustomobject]@{
        Success = $false
        Response = [pscustomobject]@{ ExitCode = 1; Output = @(); LogPath = $log }
    }
}

function Invoke-GuestScenario {
    param(
        [hashtable]$Config,
        [pscustomobject]$Definition,
        [string]$ScenarioName,
        [string]$LogDirectory,
        [string]$ResultLabel = $ScenarioName
    )

    $guestScript = 'C:\MasterDeskLab\Invoke-MasterDeskGuestScenario.ps1'
    $guestResult = "C:\MasterDeskLab\scenario-$($script:RunId)-$($Definition.Label)-$ResultLabel.json"
    $guestLogs = "C:\MasterDeskLab\scenario-logs-$($script:RunId)-$($Definition.Label)-$ResultLabel.zip"
    $hostResult = Join-Path $LogDirectory ("scenario-{0}.json" -f $ResultLabel.ToLowerInvariant())
    $hostLogs = Join-Path $LogDirectory ("MasterDesk-{0}-logs.zip" -f $ResultLabel)

    $initialize = Initialize-GuestLabDirectory -Config $Config -Definition $Definition `
        -LogPath (Join-Path $LogDirectory 'guest-directory.log')
    if ($initialize.ExitCode -ne 0) {
        return [pscustomobject]@{ Success = $false; Stage = 'guest-directory'; Response = $initialize }
    }

    $copyScript = Invoke-Vmrun -Config $Config -Guest -Arguments @(
        'copyFileFromHostToGuest', $Definition.Vmx,
        (Join-Path $PSScriptRoot 'Invoke-MasterDeskGuestScenario.ps1'), $guestScript
    ) -LogPath (Join-Path $LogDirectory 'copy-scenario-probe.log')
    if ($copyScript.ExitCode -ne 0) {
        return [pscustomobject]@{ Success = $false; Stage = 'copy-scenario-probe'; Response = $copyScript }
    }

    $guestPowerShell = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
    $arguments = @('runProgramInGuest', $Definition.Vmx)
    if ($ScenarioName -in @('Portable', 'SingleGui')) {
        $arguments += '-interactive'
    }
    $arguments += @(
        $guestPowerShell, '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
        '-File', $guestScript, '-Scenario', $ScenarioName,
        '-OutputPath', $guestResult, '-LogArchivePath', $guestLogs,
        '-ExpectedHostname', ("MD-W10-{0}" -f $Definition.Label)
    )
    $runScenario = Invoke-Vmrun -Config $Config -Guest -Arguments $arguments `
        -LogPath (Join-Path $LogDirectory ("run-scenario-{0}.log" -f $ResultLabel.ToLowerInvariant()))
    if ($runScenario.ExitCode -ne 0) {
        return [pscustomobject]@{ Success = $false; Stage = 'run-scenario'; Response = $runScenario }
    }

    $copyResult = Invoke-Vmrun -Config $Config -Guest -Arguments @(
        'copyFileFromGuestToHost', $Definition.Vmx, $guestResult, $hostResult
    ) -LogPath (Join-Path $LogDirectory 'copy-scenario-result.log')
    if ($copyResult.ExitCode -ne 0) {
        return [pscustomobject]@{ Success = $false; Stage = 'copy-scenario-result'; Response = $copyResult }
    }

    try {
        $scenarioResult = Get-Content -LiteralPath $hostResult -Raw | ConvertFrom-Json
    } catch {
        $parseLog = Join-Path $LogDirectory 'parse-scenario-result.log'
        (ConvertTo-SafeText $_.Exception.Message) | Set-Content -LiteralPath $parseLog -Encoding UTF8
        return [pscustomobject]@{
            Success = $false
            Stage = 'parse-scenario-result'
            Response = [pscustomobject]@{ ExitCode = 1; Output = @($_.Exception.Message); LogPath = $parseLog }
        }
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$scenarioResult.LogArchive)) {
        $copyLogs = Invoke-Vmrun -Config $Config -Guest -Arguments @(
            'copyFileFromGuestToHost', $Definition.Vmx, $guestLogs, $hostLogs
        ) -LogPath (Join-Path $LogDirectory 'copy-scenario-logs.log')
        if ($copyLogs.ExitCode -ne 0) {
            return [pscustomobject]@{
                Success = $false
                Stage = 'copy-scenario-logs'
                Response = $copyLogs
                ScenarioResult = $scenarioResult
            }
        }
    }

    return [pscustomobject]@{
        Success = $true
        Stage = 'complete'
        Response = $copyResult
        ScenarioResult = $scenarioResult
        ResultPath = $hostResult
        LogArchivePath = if (Test-Path -LiteralPath $hostLogs) { $hostLogs } else { $null }
    }
}

function Invoke-StatusAction {
    param(
        [hashtable]$Config,
        [pscustomobject]$Definition
    )

    $directory = New-VmArtifactDirectory -Definition $Definition
    $power = Test-VmPoweredOn -Config $Config -Definition $Definition `
        -LogPath (Join-Path $directory 'power.log')
    if (-not $power.Success) {
        Write-Fail -CurrentAction 'Status' -VmLabel $Definition.Label -Stage 'power-state' `
            -ExitCode $power.Response.ExitCode -LogPath $power.Response.LogPath -Fallback $power.Response.Output
        return
    }
    if (-not $power.PoweredOn) {
        Write-Pass -CurrentAction 'Status' -VmLabel $Definition.Label `
            -Details ("name={0} power=off tools=n/a guest=n/a ip=n/a host=n/a service=n/a processes=0" -f $Definition.Name)
        return
    }

    $tools = Get-ToolsState -Config $Config -Definition $Definition `
        -LogPath (Join-Path $directory 'tools.log')
    if (-not $tools.Success -or $tools.State -ne 'running') {
        Write-Fail -CurrentAction 'Status' -VmLabel $Definition.Label -Stage 'tools' `
            -ExitCode $tools.Response.ExitCode -LogPath $tools.Response.LogPath -Fallback $tools.Response.Output
        return
    }

    $guest = Test-GuestAccess -Config $Config -Definition $Definition `
        -LogPath (Join-Path $directory 'guest-access.log')
    if ($guest.ExitCode -ne 0) {
        Write-Fail -CurrentAction 'Status' -VmLabel $Definition.Label -Stage 'guest-access' `
            -ExitCode $guest.ExitCode -LogPath $guest.LogPath -Fallback $guest.Output
        return
    }

    $probeResult = Invoke-GuestProbe -Config $Config -Definition $Definition `
        -Mode Status -LogDirectory $directory
    if (-not $probeResult.Success) {
        Write-Fail -CurrentAction 'Status' -VmLabel $Definition.Label -Stage $probeResult.Stage `
            -ExitCode $probeResult.Response.ExitCode -LogPath $probeResult.Response.LogPath `
            -Fallback $probeResult.Response.Output
        return
    }

    $probe = $probeResult.Probe
    $ip = if (@($probe.IpAddresses).Count -gt 0) { @($probe.IpAddresses) -join ',' } else { 'none' }
    $service = if ($null -ne $probe.Service) { [string]$probe.Service.State } else { 'missing' }
    Write-Pass -CurrentAction 'Status' -VmLabel $Definition.Label -Details (
        "name={0} power=on tools=running guest=ok ip={1} host={2} service={3} processes={4}" -f `
        $Definition.Name, $ip, $probe.Hostname, $service, @($probe.Processes).Count
    )
}

function Invoke-StartAction {
    param([hashtable]$Config, [pscustomobject]$Definition)

    $directory = New-VmArtifactDirectory -Definition $Definition
    $result = Ensure-VmStarted -Config $Config -Definition $Definition -LogDirectory $directory
    if ($result.Success) {
        Write-Pass -CurrentAction 'Start' -VmLabel $Definition.Label -Details 'power=on tools=running'
    } else {
        Write-Fail -CurrentAction 'Start' -VmLabel $Definition.Label -Stage $result.Stage `
            -ExitCode $result.Response.ExitCode -LogPath $result.Response.LogPath -Fallback $result.Response.Output
    }
}

function Invoke-StopAction {
    param([hashtable]$Config, [pscustomobject]$Definition)

    $directory = New-VmArtifactDirectory -Definition $Definition
    $result = Stop-VmSoft -Config $Config -Definition $Definition -LogDirectory $directory
    if ($result.Success) {
        Write-Pass -CurrentAction 'Stop' -VmLabel $Definition.Label -Details 'power=off mode=soft'
    } else {
        Write-Fail -CurrentAction 'Stop' -VmLabel $Definition.Label -Stage $result.Stage `
            -ExitCode $result.Response.ExitCode -LogPath $result.Response.LogPath -Fallback $result.Response.Output
    }
}

function Invoke-ResetAction {
    param([hashtable]$Config, [pscustomobject]$Definition)

    $directory = New-VmArtifactDirectory -Definition $Definition
    $snapshot = if ([string]::IsNullOrWhiteSpace($SnapshotName)) {
        $Definition.DefaultSnapshot
    } else {
        $SnapshotName
    }
    $reset = Reset-VmToSnapshot -Config $Config -Definition $Definition `
        -Snapshot $snapshot -LogDirectory $directory
    if ($reset.Success) {
        Write-Pass -CurrentAction 'Reset' -VmLabel $Definition.Label `
            -Details ("power=off snapshot={0}" -f $snapshot)
    } else {
        Write-Fail -CurrentAction 'Reset' -VmLabel $Definition.Label -Stage $reset.Stage `
            -ExitCode $reset.Response.ExitCode -LogPath $reset.Response.LogPath -Fallback $reset.Response.Output
    }
}

function Invoke-DeployAction {
    param([hashtable]$Config, [pscustomobject]$Definition, [string]$ResolvedExePath)

    $directory = New-VmArtifactDirectory -Definition $Definition
    $ready = Ensure-VmStarted -Config $Config -Definition $Definition -LogDirectory $directory
    if (-not $ready.Success) {
        Write-Fail -CurrentAction 'Deploy' -VmLabel $Definition.Label -Stage $ready.Stage `
            -ExitCode $ready.Response.ExitCode -LogPath $ready.Response.LogPath -Fallback $ready.Response.Output
        return
    }

    $guest = Test-GuestAccess -Config $Config -Definition $Definition `
        -LogPath (Join-Path $directory 'guest-access.log')
    if ($guest.ExitCode -ne 0) {
        Write-Fail -CurrentAction 'Deploy' -VmLabel $Definition.Label -Stage 'guest-access' `
            -ExitCode $guest.ExitCode -LogPath $guest.LogPath -Fallback $guest.Output
        return
    }

    $copy = Copy-CandidateToGuest -Config $Config -Definition $Definition `
        -ResolvedExePath $ResolvedExePath -ResolvedInstalledPayloadPath $null -LogDirectory $directory
    if ($copy.Success) {
        Write-Pass -CurrentAction 'Deploy' -VmLabel $Definition.Label `
            -Details ("file={0} destination={1}" -f ([System.IO.Path]::GetFileName($ResolvedExePath)), $copy.GuestExe)
    } else {
        Write-Fail -CurrentAction 'Deploy' -VmLabel $Definition.Label -Stage $copy.Stage `
            -ExitCode $copy.Response.ExitCode -LogPath $copy.Response.LogPath -Fallback $copy.Response.Output
    }
}

function Invoke-SmokeAction {
    param([hashtable]$Config, [pscustomobject]$Definition)

    $directory = New-VmArtifactDirectory -Definition $Definition
    $ready = Ensure-VmStarted -Config $Config -Definition $Definition -LogDirectory $directory
    if (-not $ready.Success) {
        Write-Fail -CurrentAction 'Smoke' -VmLabel $Definition.Label -Stage $ready.Stage `
            -ExitCode $ready.Response.ExitCode -LogPath $ready.Response.LogPath -Fallback $ready.Response.Output
        return
    }

    $guest = Test-GuestAccess -Config $Config -Definition $Definition `
        -LogPath (Join-Path $directory 'guest-access.log')
    if ($guest.ExitCode -ne 0) {
        Write-Fail -CurrentAction 'Smoke' -VmLabel $Definition.Label -Stage 'guest-access' `
            -ExitCode $guest.ExitCode -LogPath $guest.LogPath -Fallback $guest.Output
        return
    }

    $probeResult = Invoke-GuestProbe -Config $Config -Definition $Definition `
        -Mode Smoke -LogDirectory $directory

    $screen = Invoke-Vmrun -Config $Config -Guest -Arguments @(
        'captureScreen', $Definition.Vmx, (Join-Path $directory 'screen.png')
    ) -LogPath (Join-Path $directory 'capture-screen.log')
    if ($screen.ExitCode -ne 0) {
        Write-Fail -CurrentAction 'Smoke' -VmLabel $Definition.Label -Stage 'capture-screen' `
            -ExitCode $screen.ExitCode -LogPath $screen.LogPath -Fallback $screen.Output
        return
    }

    if (-not $probeResult.Success) {
        Write-Fail -CurrentAction 'Smoke' -VmLabel $Definition.Label -Stage $probeResult.Stage `
            -ExitCode $probeResult.Response.ExitCode -LogPath $probeResult.Response.LogPath `
            -Fallback $probeResult.Response.Output
        return
    }

    $probe = $probeResult.Probe
    if (-not [bool]$probe.Passed) {
        $failureLog = Join-Path $directory 'smoke-failures.log'
        @($probe.Failures | ForEach-Object { ConvertTo-SafeText $_ }) |
            Set-Content -LiteralPath $failureLog -Encoding UTF8
        Write-Fail -CurrentAction 'Smoke' -VmLabel $Definition.Label -Stage 'guest-checks' `
            -ExitCode 1 -LogPath $failureLog -Fallback $probe.Failures
        return
    }

    $endpointCount = @($probe.Endpoints.psobject.Properties | Where-Object { [bool]$_.Value }).Count
    Write-Pass -CurrentAction 'Smoke' -VmLabel $Definition.Label -Details (
        "boot=ok tools=running desktop={0} service={1} processes={2} network=ok dns=2/2 endpoints={3}/4 artifacts={4}" -f `
        @($probe.DesktopSessions).Count, $probe.Service.State, @($probe.Processes).Count,
        $endpointCount, $directory
    )
}

function Invoke-ScenarioAction {
    param(
        [hashtable]$Config,
        [pscustomobject]$Definition,
        [string]$ScenarioName,
        [AllowNull()][string]$ResolvedCandidatePath,
        [AllowNull()][string]$ResolvedInstalledPayloadPath
    )

    $directory = New-VmArtifactDirectory -Definition $Definition
    if (-not $SkipScenarioReset -and
            [string]::IsNullOrWhiteSpace([string]$Definition.CleanSnapshot)) {
        $setupLog = Join-Path $directory 'scenario-baseline-required.log'
        "Scenario '$ScenarioName' requires a configured clean snapshot for VM $($Definition.Label)." |
            Set-Content -LiteralPath $setupLog -Encoding UTF8
        Write-Fail -CurrentAction 'Scenario' -VmLabel $Definition.Label `
            -Stage ("{0}:setup-required" -f $ScenarioName) -ExitCode 1 -LogPath $setupLog
        return
    }
    if ([string]::IsNullOrWhiteSpace($ResolvedCandidatePath)) {
        $setupLog = Join-Path $directory 'scenario-candidate-required.log'
        'An isolated scenario requires an explicit -ExePath so Reset can be followed by deterministic Deploy.' |
            Set-Content -LiteralPath $setupLog -Encoding UTF8
        Write-Fail -CurrentAction 'Scenario' -VmLabel $Definition.Label `
            -Stage ("{0}:setup-required" -f $ScenarioName) -ExitCode 1 -LogPath $setupLog
        return
    }

    $baseline = if ($SkipScenarioReset) { 'current-state' } else {
        [string]$Definition.CleanSnapshot
    }
    if (-not $SkipScenarioReset) {
        $reset = Reset-VmToSnapshot -Config $Config -Definition $Definition `
            -Snapshot $baseline -LogDirectory $directory
        if (-not $reset.Success) {
            Write-Fail -CurrentAction 'Scenario' -VmLabel $Definition.Label `
                -Stage ("{0}:{1}" -f $ScenarioName, $reset.Stage) `
                -ExitCode $reset.Response.ExitCode -LogPath $reset.Response.LogPath -Fallback $reset.Response.Output
            return
        }
    }

    $ready = Ensure-VmStarted -Config $Config -Definition $Definition -LogDirectory $directory
    if (-not $ready.Success) {
        Write-Fail -CurrentAction 'Scenario' -VmLabel $Definition.Label `
            -Stage ("{0}:ready" -f $ScenarioName) -ExitCode $ready.Response.ExitCode `
            -LogPath $ready.Response.LogPath -Fallback $ready.Response.Output
        return
    }

    $guest = Test-GuestAccess -Config $Config -Definition $Definition `
        -LogPath (Join-Path $directory 'guest-access.log')
    if ($guest.ExitCode -ne 0) {
        Write-Fail -CurrentAction 'Scenario' -VmLabel $Definition.Label `
            -Stage ("{0}:guest-access" -f $ScenarioName) -ExitCode $guest.ExitCode `
            -LogPath $guest.LogPath -Fallback $guest.Output
        return
    }

    $deploy = Copy-CandidateToGuest -Config $Config -Definition $Definition `
        -ResolvedExePath $ResolvedCandidatePath `
        -ResolvedInstalledPayloadPath $ResolvedInstalledPayloadPath -LogDirectory $directory
    if (-not $deploy.Success) {
        Write-Fail -CurrentAction 'Scenario' -VmLabel $Definition.Label `
            -Stage ("{0}:{1}" -f $ScenarioName, $deploy.Stage) `
            -ExitCode $deploy.Response.ExitCode -LogPath $deploy.Response.LogPath `
            -Fallback $deploy.Response.Output
        return
    }

    if ($ScenarioName -in @('Service', 'SingleGui', 'Wss')) {
        $installRun = Invoke-GuestScenario -Config $Config -Definition $Definition `
            -ScenarioName 'Install' -ResultLabel 'prerequisite-install' -LogDirectory $directory
        if (-not $installRun.Success -or -not [bool]$installRun.ScenarioResult.Passed) {
            $installFailures = if ($null -ne $installRun.ScenarioResult) {
                @($installRun.ScenarioResult.Failures)
            } else {
                @($installRun.Response.Output)
            }
            $failureLog = Join-Path $directory 'prerequisite-install-failures.log'
            $installFailures | Set-Content -LiteralPath $failureLog -Encoding UTF8
            Write-Fail -CurrentAction 'Scenario' -VmLabel $Definition.Label `
                -Stage ("{0}:prepare-installed-candidate" -f $ScenarioName) -ExitCode 1 `
                -LogPath $failureLog -Fallback $installFailures
            return
        }
    }

    if ($ScenarioName -in @('Portable', 'SingleGui')) {
        $desktop = Wait-InteractiveDesktop -Config $Config -Definition $Definition `
            -LogDirectory $directory -Seconds $TimeoutSeconds
        if (-not $desktop.Success) {
            Write-Fail -CurrentAction 'Scenario' -VmLabel $Definition.Label `
                -Stage ("{0}:desktop-session" -f $ScenarioName) -ExitCode $desktop.Response.ExitCode `
                -LogPath $desktop.Response.LogPath -Fallback $desktop.Response.Output
            return
        }
    }

    $scenarioRun = Invoke-GuestScenario -Config $Config -Definition $Definition `
        -ScenarioName $ScenarioName -LogDirectory $directory

    $screen = Invoke-Vmrun -Config $Config -Guest -Arguments @(
        'captureScreen', $Definition.Vmx, (Join-Path $directory 'screen.png')
    ) -LogPath (Join-Path $directory 'capture-screen.log')
    if ($screen.ExitCode -ne 0) {
        Write-Fail -CurrentAction 'Scenario' -VmLabel $Definition.Label `
            -Stage ("{0}:capture-screen" -f $ScenarioName) -ExitCode $screen.ExitCode `
            -LogPath $screen.LogPath -Fallback $screen.Output
        return
    }

    if (-not $scenarioRun.Success) {
        Write-Fail -CurrentAction 'Scenario' -VmLabel $Definition.Label `
            -Stage ("{0}:{1}" -f $ScenarioName, $scenarioRun.Stage) `
            -ExitCode $scenarioRun.Response.ExitCode -LogPath $scenarioRun.Response.LogPath `
            -Fallback $scenarioRun.Response.Output
        return
    }

    $result = $scenarioRun.ScenarioResult
    $wssClassification = $null
    if ($ScenarioName -eq 'Wss') {
        $wssSummary = & (Join-Path $PSScriptRoot 'Write-MasterDeskWssDiagnostic.ps1') `
            -ScenarioJsonPath $scenarioRun.ResultPath `
            -LogArchivePath $scenarioRun.LogArchivePath `
            -OutputDirectory $directory
        $wssClassification = [string]$wssSummary.Classification
    }
    if (-not [bool]$result.Passed) {
        $failureLog = Join-Path $directory ("scenario-{0}-failures.log" -f $ScenarioName.ToLowerInvariant())
        @($result.Failures | ForEach-Object { ConvertTo-SafeText $_ }) |
            Set-Content -LiteralPath $failureLog -Encoding UTF8
        $failureStage = if ($wssClassification) {
            "Wss:$wssClassification"
        } else {
            "{0}:guest-checks" -f $ScenarioName
        }
        Write-Fail -CurrentAction 'Scenario' -VmLabel $Definition.Label `
            -Stage $failureStage -ExitCode 1 `
            -LogPath $failureLog -Fallback $result.Failures
        return
    }

    Write-Pass -CurrentAction 'Scenario' -VmLabel $Definition.Label -Details (
        "scenario={0} baseline={1} hostSha256={2} {3} artifacts={4}" -f `
        $ScenarioName, $baseline, $deploy.HostSha256, $result.Summary, $directory
    )
}

try {
    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        throw "Lab configuration file was not found: $ConfigPath"
    }
    $config = Import-PowerShellDataFile -LiteralPath $ConfigPath
    Assert-LabConfig -Config $config
    $definitions = @(Get-VmDefinitions -Config $config)
    foreach ($definition in $definitions) {
        if (-not (Test-Path -LiteralPath $definition.Vmx -PathType Leaf)) {
            throw "VMX was not found for VM $($definition.Label): $($definition.Vmx)"
        }
    }

    if ($Action -in @('Status', 'Deploy', 'Smoke', 'Scenario')) {
        $script:GuestPassword = [Environment]::GetEnvironmentVariable('MASTERDESK_LAB_PASSWORD')
        if ([string]::IsNullOrWhiteSpace($script:GuestPassword)) {
            throw 'MASTERDESK_LAB_PASSWORD is not set.'
        }
    }

    $resolvedExePath = $null
    $resolvedInstalledPayloadPath = $null
    if ($Action -in @('Deploy', 'Scenario')) {
        if ([string]::IsNullOrWhiteSpace($ExePath)) {
            throw "$Action requires -ExePath. Isolated scenarios reset the VM and cannot reuse a previous candidate marker."
        }
        try {
            $resolvedExePath = (Resolve-Path -LiteralPath $ExePath -ErrorAction Stop).ProviderPath
        } catch {
            throw "Deploy EXE was not found: $ExePath (PowerShell location: $((Get-Location).ProviderPath))"
        }
        if (-not (Test-Path -LiteralPath $resolvedExePath -PathType Leaf)) {
            throw "Deploy EXE is not a file: $resolvedExePath"
        }
        if ([System.IO.Path]::GetExtension($resolvedExePath) -ine '.exe') {
            throw "Deploy accepts a MasterDesk .exe file: $resolvedExePath"
        }
        if ($Action -eq 'Scenario' -and $Scenario -ne 'Portable') {
            $payloadInput = if ([string]::IsNullOrWhiteSpace($InstalledPayloadPath)) {
                Join-Path $script:RepoRoot 'flutter\build\windows\x64\runner\Release\rustdesk.exe'
            } else {
                $InstalledPayloadPath
            }
            try {
                $resolvedInstalledPayloadPath = (Resolve-Path -LiteralPath $payloadInput -ErrorAction Stop).ProviderPath
            } catch {
                throw "Installed payload reference was not found: $payloadInput. Pass -InstalledPayloadPath for this candidate."
            }
            if ([System.IO.Path]::GetExtension($resolvedInstalledPayloadPath) -ine '.exe') {
                throw "Installed payload reference must be an .exe: $resolvedInstalledPayloadPath"
            }
        }
    }

    if ($Action -eq 'Scenario' -and [string]::IsNullOrWhiteSpace($Scenario)) {
        throw 'Scenario action requires -Scenario.'
    }

    foreach ($definition in $definitions) {
        switch ($Action) {
            'Status' { Invoke-StatusAction -Config $config -Definition $definition }
            'Start'  { Invoke-StartAction -Config $config -Definition $definition }
            'Stop'   { Invoke-StopAction -Config $config -Definition $definition }
            'Reset'  { Invoke-ResetAction -Config $config -Definition $definition }
            'Deploy' { Invoke-DeployAction -Config $config -Definition $definition -ResolvedExePath $resolvedExePath }
            'Smoke'  { Invoke-SmokeAction -Config $config -Definition $definition }
            'Scenario' {
                Invoke-ScenarioAction -Config $config -Definition $definition `
                    -ScenarioName $Scenario -ResolvedCandidatePath $resolvedExePath `
                    -ResolvedInstalledPayloadPath $resolvedInstalledPayloadPath
            }
        }
    }
} catch {
    $script:Failures++
    $fatalLog = Join-Path $script:ArtifactRoot 'fatal.log'
    (ConvertTo-SafeText $_.Exception.Message) | Set-Content -LiteralPath $fatalLog -Encoding UTF8
    Write-Output ("FAIL action={0} vm={1} stage=setup exit=1 log={2} tail=""{3}""" -f `
        $Action, $Vm, $fatalLog, (Get-ShortTail -LogPath $fatalLog))
} finally {
    $script:GuestPassword = $null
}

if ($script:Failures -gt 0) {
    exit 1
}
exit 0
