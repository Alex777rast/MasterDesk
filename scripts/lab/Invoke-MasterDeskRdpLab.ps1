[CmdletBinding()]
param(
    [ValidateSet('Status', 'Restore', 'Deploy', 'Install', 'Prepare', 'Open', 'Test', 'InputTest', 'PasswordTest', 'IdentityTest', 'DiagnosticDll', 'Trace', 'ReconnectTrace')]
    [string]$Action = 'Status',

    [ValidateSet('A', 'B', 'All')]
    [string]$Vm = 'All',

    [string]$ExePath,

    [string]$DllPath,

    [string]$ConfigPath = 'D:\Vms\MasterDeskLab\lab-config.psd1',

    [ValidateRange(30, 900)]
    [int]$TimeoutSeconds = 240,

    [switch]$NoRdpLaunch,

    [switch]$KeepVmState,

    [switch]$UseCurrentPreparedState
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$script:RepoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$script:RunId = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
$script:ArtifactRoot = if ($Action -in @('InputTest', 'PasswordTest')) {
    Join-Path $script:RepoRoot "artifacts\gui-runs\$($script:RunId)\wrapper"
} else {
    Join-Path $script:RepoRoot "artifacts\lab\$($script:RunId)\rdp"
}
$script:GuestPassword = [Environment]::GetEnvironmentVariable('MASTERDESK_LAB_PASSWORD')
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
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    return ((Get-Content -LiteralPath $Path -Tail 4 -ErrorAction SilentlyContinue |
        ForEach-Object { ConvertTo-SafeText $_ }) -join ' | ') -replace '[\r\n\t]+', ' '
}

function Resolve-CandidatePath {
    if (-not [string]::IsNullOrWhiteSpace($ExePath)) {
        return (Resolve-Path -LiteralPath $ExePath -ErrorAction Stop).ProviderPath
    }

    $candidate = Get-ChildItem -LiteralPath (Join-Path $script:RepoRoot 'dist') `
        -Filter 'MasterDesk-*-beta-*-RDS-x86_64.exe' -File -ErrorAction Stop |
        ForEach-Object {
            $beta = if ($_.Name -match '-beta-(\d+)-') { [int]$matches[1] } else { -1 }
            [pscustomobject]@{ File = $_; Beta = $beta }
        } |
        Sort-Object Beta, @{ Expression = { $_.File.LastWriteTimeUtc }; Descending = $true } -Descending |
        Select-Object -First 1
    if ($null -eq $candidate -or $candidate.Beta -lt 0) {
        throw 'No dated MasterDesk beta candidate was found under dist.'
    }
    return $candidate.File.FullName
}

function Test-TcpPort {
    param([string]$Address, [int]$Port, [int]$TimeoutMilliseconds = 3000)

    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $task = $client.ConnectAsync($Address, $Port)
        if (-not $task.Wait($TimeoutMilliseconds)) { return $false }
        return $client.Connected
    } catch {
        return $false
    } finally {
        $client.Dispose()
    }
}

function Invoke-Vmrun {
    param(
        [hashtable]$Config,
        [object[]]$Arguments,
        [string]$LogPath,
        [switch]$Guest
    )

    $actual = New-Object System.Collections.Generic.List[object]
    $safe = New-Object System.Collections.Generic.List[string]
    $actual.Add('-T'); $actual.Add('ws'); $safe.Add('-T'); $safe.Add('ws')
    if ($Guest) {
        if ([string]::IsNullOrWhiteSpace($script:GuestPassword)) {
            throw 'MASTERDESK_LAB_PASSWORD is not set.'
        }
        $actual.Add('-gu'); $actual.Add([string]$Config.GuestUser)
        $actual.Add('-gp'); $actual.Add($script:GuestPassword)
        $safe.Add('-gu'); $safe.Add([string]$Config.GuestUser)
        $safe.Add('-gp'); $safe.Add('<redacted>')
    }
    foreach ($argument in $Arguments) {
        $actual.Add($argument)
        $safe.Add((ConvertTo-SafeText $argument))
    }

    $raw = @(& $Config.Vmrun @actual 2>&1)
    $code = $LASTEXITCODE
    @("command=vmrun $($safe -join ' ')", "exitCode=$code", 'output:') +
        @($raw | ForEach-Object { ConvertTo-SafeText $_ }) |
        Set-Content -LiteralPath $LogPath -Encoding UTF8
    return [pscustomobject]@{ ExitCode = [int]$code; Output = @($raw); LogPath = $LogPath }
}

function Invoke-LabStep {
    param([string]$Name, [hashtable]$Parameters)

    $logPath = Join-Path $script:ArtifactRoot "$Name.log"
    $childArguments = New-Object System.Collections.Generic.List[object]
    $childArguments.Add('-NoProfile')
    $childArguments.Add('-ExecutionPolicy')
    $childArguments.Add('Bypass')
    $childArguments.Add('-File')
    $childArguments.Add((Join-Path $PSScriptRoot 'Test-MasterDeskLab.ps1'))
    foreach ($key in @($Parameters.Keys | Sort-Object)) {
        if ($Parameters[$key] -is [bool]) {
            if ([bool]$Parameters[$key]) { $childArguments.Add("-$key") }
            continue
        }
        $childArguments.Add("-$key")
        $childArguments.Add($Parameters[$key])
    }
    $powershell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $output = @(& $powershell @childArguments 2>&1)
    $code = $LASTEXITCODE
    @($output | ForEach-Object { ConvertTo-SafeText $_ }) |
        Set-Content -LiteralPath $logPath -Encoding UTF8
    if ($code -ne 0) {
        throw "$Name failed; log=$logPath tail=$(Get-ShortTail -Path $logPath)"
    }
}

function Get-Definitions {
    param([hashtable]$Config)

    $snapshotA = if ($Action -in @('InputTest', 'PasswordTest', 'IdentityTest')) {
        [string]$Config.VmASnapshotMcpOn
    } else { [string]$Config.VmASnapshotRdpOn }
    $snapshotB = if ($Action -in @('InputTest', 'PasswordTest', 'IdentityTest')) {
        [string]$Config.VmBSnapshotMcpOn
    } else { [string]$Config.VmBSnapshotRdpOn }

    $items = @(
        [pscustomobject]@{
            Label = 'A'; Name = [string]$Config.VmAName; Vmx = [string]$Config.VmA
            Address = [string]$Config.VmAAddress; Snapshot = $snapshotA
        },
        [pscustomobject]@{
            Label = 'B'; Name = [string]$Config.VmBName; Vmx = [string]$Config.VmB
            Address = [string]$Config.VmBAddress; Snapshot = $snapshotB
        }
    )
    if ($Vm -eq 'All') { return $items }
    return @($items | Where-Object Label -eq $Vm)
}

function Wait-Rdp {
    param([pscustomobject]$Definition)

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        if (Test-TcpPort -Address $Definition.Address -Port 3389) { return }
        Start-Sleep -Seconds 2
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "RDP timeout for VM $($Definition.Label) at $($Definition.Address):3389"
}

function Initialize-GuestHelper {
    param([hashtable]$Config, [pscustomobject]$Definition)

    $directoryLog = Join-Path $script:ArtifactRoot "helper-directory-$($Definition.Label).log"
    $exists = Invoke-Vmrun -Config $Config -Guest -Arguments @(
        'directoryExistsInGuest', $Definition.Vmx, 'C:\MasterDeskLab'
    ) -LogPath "$directoryLog.exists"
    if ($exists.ExitCode -ne 0) {
        $created = Invoke-Vmrun -Config $Config -Guest -Arguments @(
            'createDirectoryInGuest', $Definition.Vmx, 'C:\MasterDeskLab'
        ) -LogPath $directoryLog
        if ($created.ExitCode -ne 0) { throw "Guest lab directory failed for VM $($Definition.Label)." }
    }

    $copy = Invoke-Vmrun -Config $Config -Guest -Arguments @(
        'copyFileFromHostToGuest', $Definition.Vmx,
        (Join-Path $PSScriptRoot 'Invoke-MasterDeskKeyboardGuest.ps1'),
        'C:\MasterDeskLab\Invoke-MasterDeskKeyboardGuest.ps1'
    ) -LogPath (Join-Path $script:ArtifactRoot "helper-copy-$($Definition.Label).log")
    if ($copy.ExitCode -ne 0) { throw "Guest helper copy failed for VM $($Definition.Label)." }
}

function Invoke-GuestAction {
    param(
        [hashtable]$Config,
        [pscustomobject]$Definition,
        [string]$GuestAction,
        [string[]]$Arguments = @()
    )

    Initialize-GuestHelper -Config $Config -Definition $Definition
    $guestResult = "C:\MasterDeskLab\rdp-$($script:RunId)-$GuestAction.json"
    $hostResult = Join-Path $script:ArtifactRoot "$($Definition.Label)-$GuestAction.json"
    $runArgs = @('runProgramInGuest', $Definition.Vmx)
    if ($GuestAction -notin @('Identity', 'InstallDiagnosticDll', 'Trace', 'ReconnectTrace')) {
        $runArgs += '-interactive'
    }
    $runArgs += @(
        'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe',
        '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
        '-File', 'C:\MasterDeskLab\Invoke-MasterDeskKeyboardGuest.ps1',
        '-Action', $GuestAction, '-OutputPath', $guestResult
    ) + $Arguments
    $run = Invoke-Vmrun -Config $Config -Guest -Arguments $runArgs `
        -LogPath (Join-Path $script:ArtifactRoot "$($Definition.Label)-$GuestAction-run.log")
    $copy = Invoke-Vmrun -Config $Config -Guest -Arguments @(
        'copyFileFromGuestToHost', $Definition.Vmx, $guestResult, $hostResult
    ) -LogPath (Join-Path $script:ArtifactRoot "$($Definition.Label)-$GuestAction-copy.log")
    if ($run.ExitCode -ne 0 -or $copy.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $hostResult)) {
        throw "Guest action $GuestAction failed for VM $($Definition.Label)."
    }
    $result = Get-Content -LiteralPath $hostResult -Raw | ConvertFrom-Json
    if (-not [bool]$result.Passed) {
        throw "Guest action $GuestAction failed for VM $($Definition.Label): $($result.Error)"
    }
    return $result
}

function Invoke-Restore {
    param([pscustomobject[]]$Definitions)

    foreach ($definition in $Definitions) {
        Invoke-LabStep -Name "restore-$($definition.Label)" -Parameters @{
            Action = 'Reset'; Vm = $definition.Label; SnapshotName = $definition.Snapshot
            ConfigPath = $ConfigPath; TimeoutSeconds = $TimeoutSeconds
        }
        Invoke-LabStep -Name "start-$($definition.Label)" -Parameters @{
            Action = 'Start'; Vm = $definition.Label; ConfigPath = $ConfigPath
            TimeoutSeconds = $TimeoutSeconds
        }
        Wait-Rdp -Definition $definition
        Write-Output ("PASS action=Restore vm={0} snapshot={1} rdp={2}:3389" -f `
            $definition.Label, $definition.Snapshot, $definition.Address)
    }
}

function Invoke-Deploy {
    param([pscustomobject[]]$Definitions, [string]$CandidatePath)

    foreach ($definition in $Definitions) {
        Invoke-LabStep -Name "deploy-$($definition.Label)" -Parameters @{
            Action = 'Deploy'; Vm = $definition.Label; ExePath = $CandidatePath
            ConfigPath = $ConfigPath; TimeoutSeconds = $TimeoutSeconds
        }
        Write-Output ("PASS action=Deploy vm={0} sha256={1}" -f $definition.Label,
            (Get-FileHash -LiteralPath $CandidatePath -Algorithm SHA256).Hash)
    }
}

function Invoke-Install {
    param(
        [hashtable]$Config,
        [pscustomobject[]]$Definitions,
        [string]$CandidatePath,
        [switch]$UseCurrentState
    )

    $runner = Join-Path $script:RepoRoot 'flutter\build\windows\x64\runner\Release\MasterDesk.exe'
    $dll = Join-Path $script:RepoRoot 'flutter\build\windows\x64\runner\Release\libmasterdesk.dll'
    if (-not (Test-Path -LiteralPath $runner) -or -not (Test-Path -LiteralPath $dll)) {
        throw 'Installed-payload references are missing; run the normal candidate build first.'
    }
    foreach ($definition in $Definitions) {
        $installParameters = @{
            Action = 'Scenario'; Scenario = 'Install'; Vm = $definition.Label
            ExePath = $CandidatePath; InstalledPayloadPath = $runner
            ConfigPath = $ConfigPath; TimeoutSeconds = $TimeoutSeconds
        }
        if ($UseCurrentState) { $installParameters.SkipScenarioReset = $true }
        Invoke-LabStep -Name "install-$($definition.Label)" -Parameters $installParameters
        Write-Output ("PASS action=Install vm={0} candidateSha256={1} runnerSha256={2} expectedDllSha256={3}" -f `
            $definition.Label,
            (Get-FileHash -LiteralPath $CandidatePath -Algorithm SHA256).Hash,
            (Get-FileHash -LiteralPath $runner -Algorithm SHA256).Hash,
            (Get-FileHash -LiteralPath $dll -Algorithm SHA256).Hash)
    }
}

try {
    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        throw "Lab configuration file was not found: $ConfigPath"
    }
    $config = Import-PowerShellDataFile -LiteralPath $ConfigPath
    foreach ($key in @('Vmrun', 'VmA', 'VmB', 'VmAName', 'VmBName', 'GuestUser',
            'VmAAddress', 'VmBAddress', 'VmASnapshotRdpOn', 'VmBSnapshotRdpOn')) {
        if (-not $config.ContainsKey($key) -or [string]::IsNullOrWhiteSpace([string]$config[$key])) {
            throw "Missing required RDP lab configuration key: $key"
        }
    }
    if ($Action -in @('InputTest', 'PasswordTest', 'IdentityTest')) {
        foreach ($key in @('VmASnapshotMcpOn', 'VmBSnapshotMcpOn')) {
            if (-not $config.ContainsKey($key) -or
                    [string]::IsNullOrWhiteSpace([string]$config[$key])) {
                throw "Missing required MCP lab configuration key: $key"
            }
        }
    }
    $definitions = @(Get-Definitions -Config $config)

    switch ($Action) {
        'Status' {
            $list = Invoke-Vmrun -Config $config -Arguments @('list') `
                -LogPath (Join-Path $script:ArtifactRoot 'vm-list.log')
            if ($list.ExitCode -ne 0) { throw 'vmrun list failed.' }
            foreach ($definition in $definitions) {
                $powered = @($list.Output | Where-Object {
                    [string]::Equals(([string]$_).Trim(), $definition.Vmx,
                        [StringComparison]::OrdinalIgnoreCase)
                }).Count -gt 0
                $rdp = $powered -and (Test-TcpPort -Address $definition.Address -Port 3389)
                $activeRdp = 'unknown'
                if ($powered -and -not [string]::IsNullOrWhiteSpace($script:GuestPassword)) {
                    try {
                        $session = Invoke-GuestAction -Config $config -Definition $definition `
                            -GuestAction 'Session'
                        $activeRdp = [string][bool]$session.ActiveRdp
                    } catch {
                        $activeRdp = 'unavailable'
                    }
                }
                Write-Output ("PASS action=Status vm={0} power={1} rdpPort={2} activeRdp={3} address={4}" -f `
                    $definition.Label, $powered, $rdp, $activeRdp, $definition.Address)
            }
        }
        'Restore' { Invoke-Restore -Definitions $definitions }
        'Deploy' {
            $candidatePath = Resolve-CandidatePath
            Invoke-Deploy -Definitions $definitions -CandidatePath $candidatePath
        }
        'Install' {
            $candidatePath = Resolve-CandidatePath
            Invoke-Install -Config $config -Definitions $definitions -CandidatePath $candidatePath `
                -UseCurrentState:$UseCurrentPreparedState
        }
        'Prepare' {
            $candidatePath = Resolve-CandidatePath
            Invoke-Install -Config $config -Definitions $definitions -CandidatePath $candidatePath `
                -UseCurrentState:$UseCurrentPreparedState
            & (Join-Path $PSScriptRoot 'Open-MasterDeskLabRdp.ps1') -Vm $Vm `
                -ConfigPath $ConfigPath -NoLaunch:$NoRdpLaunch
        }
        'Open' {
            & (Join-Path $PSScriptRoot 'Open-MasterDeskLabRdp.ps1') -Vm $Vm `
                -ConfigPath $ConfigPath -NoLaunch:$NoRdpLaunch
        }
        'Test' {
            if ($Vm -ne 'All') { throw 'The two-VM RDP session test requires -Vm All.' }
            $candidatePath = Resolve-CandidatePath
            $testArguments = @(
                '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
                (Join-Path $PSScriptRoot 'Test-MasterDeskKeyboard.ps1'),
                '-ExePath', $candidatePath, '-ConfigPath', $ConfigPath,
                '-UseCurrentPreparedState', '-RequireRdpSession'
            )
            if ($KeepVmState) { $testArguments += '-KeepVmState' }
            $powershell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
            $testOutput = @(& $powershell @testArguments 2>&1)
            $testCode = $LASTEXITCODE
            $testOutput | ForEach-Object { ConvertTo-SafeText $_ } |
                Set-Content -LiteralPath (Join-Path $script:ArtifactRoot 'session-test.log') -Encoding UTF8
            $testOutput | ForEach-Object { Write-Output (ConvertTo-SafeText $_) }
            if ($testCode -ne 0 -and @($testOutput | Where-Object {
                [string]$_ -match '^INCONCLUSIVE\s'
            }).Count -gt 0) {
                exit 2
            }
            if ($testCode -ne 0) { throw 'The two-VM RDP session test failed.' }
        }
        'InputTest' {
            if ($Vm -ne 'All') { throw 'The MCP input test requires -Vm All.' }
            $candidatePath = Resolve-CandidatePath
            Get-Process mstsc -ErrorAction SilentlyContinue | Where-Object {
                $_.MainWindowTitle -match [regex]::Escape([string]$config.VmAAddress) -or
                $_.MainWindowTitle -match [regex]::Escape([string]$config.VmBAddress)
            } | Stop-Process -Force
            Invoke-Restore -Definitions $definitions
            & (Join-Path $PSScriptRoot 'Open-MasterDeskLabRdp.ps1') -Vm All `
                -ConfigPath $ConfigPath -NoLaunch:$NoRdpLaunch
            if ($NoRdpLaunch) {
                throw 'InputTest requires active RDP sessions; omit -NoRdpLaunch.'
            }
            Start-Sleep -Seconds 6
            Invoke-Install -Config $config -Definitions $definitions `
                -CandidatePath $candidatePath -UseCurrentState
            Get-Process mstsc -ErrorAction SilentlyContinue | Where-Object {
                $_.MainWindowTitle -match [regex]::Escape([string]$config.VmAAddress) -or
                $_.MainWindowTitle -match [regex]::Escape([string]$config.VmBAddress)
            } | Stop-Process -Force
            foreach ($definition in $definitions) {
                $reboot = Invoke-Vmrun -Config $config -Arguments @(
                    'reset', $definition.Vmx, 'soft'
                ) -LogPath (Join-Path $script:ArtifactRoot "reboot-$($definition.Label).log")
                if ($reboot.ExitCode -ne 0) { throw "VM $($definition.Label) reboot failed." }
            }
            Start-Sleep -Seconds 12
            foreach ($definition in $definitions) { Wait-Rdp -Definition $definition }
            & (Join-Path $PSScriptRoot 'Open-MasterDeskLabRdp.ps1') -Vm All `
                -ConfigPath $ConfigPath
            Start-Sleep -Seconds 8
            $mcpRestartOutput = @(& (Join-Path $PSScriptRoot 'Install-MasterDeskWindowsMcp.ps1') `
                -Action Restart -Vm All -ConfigPath $ConfigPath 2>&1)
            $mcpRestartCode = $LASTEXITCODE
            $mcpRestartOutput | ForEach-Object { ConvertTo-SafeText $_ } |
                Set-Content -LiteralPath (Join-Path $script:ArtifactRoot 'mcp-restart.log') -Encoding UTF8
            if ($mcpRestartCode -ne 0) { throw 'Windows-MCP restart failed after RDP activation.' }
            $inputArguments = @(
                '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
                (Join-Path $PSScriptRoot 'Test-MasterDeskMcpInput.ps1'),
                '-ExePath', $candidatePath, '-ConfigPath', $ConfigPath,
                '-OutputDirectory', (Join-Path $script:ArtifactRoot 'input-test')
            )
            $powershell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
            $inputOutput = @(& $powershell @inputArguments 2>&1)
            $inputCode = $LASTEXITCODE
            $inputOutput | ForEach-Object { ConvertTo-SafeText $_ } |
                Set-Content -LiteralPath (Join-Path $script:ArtifactRoot 'input-test.log') -Encoding UTF8
            $inputOutput | ForEach-Object { Write-Output (ConvertTo-SafeText $_) }
            if ($inputCode -eq 2) { exit 2 }
            if ($inputCode -ne 0) { throw 'The MCP input test failed.' }
        }
        'PasswordTest' {
            if ($Vm -ne 'All') { throw 'The MCP temporary-password test requires -Vm All.' }
            $candidatePath = Resolve-CandidatePath
            Get-Process mstsc -ErrorAction SilentlyContinue | Where-Object {
                $_.MainWindowTitle -match [regex]::Escape([string]$config.VmAAddress) -or
                $_.MainWindowTitle -match [regex]::Escape([string]$config.VmBAddress)
            } | Stop-Process -Force
            Invoke-Restore -Definitions $definitions
            & (Join-Path $PSScriptRoot 'Open-MasterDeskLabRdp.ps1') -Vm All `
                -ConfigPath $ConfigPath -NoLaunch:$NoRdpLaunch
            if ($NoRdpLaunch) {
                throw 'PasswordTest requires active RDP sessions; omit -NoRdpLaunch.'
            }
            Start-Sleep -Seconds 6
            Invoke-Install -Config $config -Definitions $definitions `
                -CandidatePath $candidatePath -UseCurrentState
            Get-Process mstsc -ErrorAction SilentlyContinue | Where-Object {
                $_.MainWindowTitle -match [regex]::Escape([string]$config.VmAAddress) -or
                $_.MainWindowTitle -match [regex]::Escape([string]$config.VmBAddress)
            } | Stop-Process -Force
            foreach ($definition in $definitions) {
                $reboot = Invoke-Vmrun -Config $config -Arguments @(
                    'reset', $definition.Vmx, 'soft'
                ) -LogPath (Join-Path $script:ArtifactRoot "reboot-$($definition.Label).log")
                if ($reboot.ExitCode -ne 0) { throw "VM $($definition.Label) reboot failed." }
            }
            Start-Sleep -Seconds 12
            foreach ($definition in $definitions) { Wait-Rdp -Definition $definition }
            & (Join-Path $PSScriptRoot 'Open-MasterDeskLabRdp.ps1') -Vm All `
                -ConfigPath $ConfigPath
            Start-Sleep -Seconds 8
            $mcpRestartOutput = @(& (Join-Path $PSScriptRoot 'Install-MasterDeskWindowsMcp.ps1') `
                -Action Restart -Vm All -ConfigPath $ConfigPath 2>&1)
            $mcpRestartCode = $LASTEXITCODE
            $mcpRestartOutput | ForEach-Object { ConvertTo-SafeText $_ } |
                Set-Content -LiteralPath (Join-Path $script:ArtifactRoot 'mcp-restart.log') -Encoding UTF8
            if ($mcpRestartCode -ne 0) { throw 'Windows-MCP restart failed after RDP activation.' }
            $testArguments = @(
                '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
                (Join-Path $PSScriptRoot 'Test-MasterDeskMcpInput.ps1'),
                '-ExePath', $candidatePath, '-ConfigPath', $ConfigPath,
                '-OutputDirectory', (Join-Path $script:ArtifactRoot 'password-test'),
                '-AuthorizationMode', 'TemporaryPassword'
            )
            $powershell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
            $testOutput = @(& $powershell @testArguments 2>&1)
            $testCode = $LASTEXITCODE
            $testOutput | ForEach-Object { ConvertTo-SafeText $_ } |
                Set-Content -LiteralPath (Join-Path $script:ArtifactRoot 'password-test.log') -Encoding UTF8
            $testOutput | ForEach-Object { Write-Output (ConvertTo-SafeText $_) }
            if ($testCode -eq 2) { exit 2 }
            if ($testCode -ne 0) { throw 'The MCP temporary-password test failed.' }
        }
        'IdentityTest' {
            $candidatePath = Resolve-CandidatePath
            if (-not $UseCurrentPreparedState) {
                Invoke-Restore -Definitions $definitions
                Invoke-Install -Config $config -Definitions $definitions `
                    -CandidatePath $candidatePath -UseCurrentState
            }
            foreach ($definition in $definitions) {
                $identity = Invoke-GuestAction -Config $config -Definition $definition `
                    -GuestAction 'Identity' -Arguments @('-Cycles', '3')
                Write-Output ("PASS action=IdentityTest vm={0} id={1} cycles={2}" -f `
                    $definition.Label, $identity.Id, $identity.Cycles)
            }
        }
        'DiagnosticDll' {
            if ([string]::IsNullOrWhiteSpace($DllPath)) {
                throw 'DiagnosticDll requires -DllPath.'
            }
            $resolvedDll = (Resolve-Path -LiteralPath $DllPath -ErrorAction Stop).ProviderPath
            $expectedHash = (Get-FileHash -LiteralPath $resolvedDll -Algorithm SHA256).Hash
            foreach ($definition in $definitions) {
                Initialize-GuestHelper -Config $config -Definition $definition
                $guestDll = 'C:\MasterDeskLab\librustdesk-diagnostic.dll'
                $copy = Invoke-Vmrun -Config $config -Guest -Arguments @(
                    'copyFileFromHostToGuest', $definition.Vmx, $resolvedDll, $guestDll
                ) -LogPath (Join-Path $script:ArtifactRoot "diagnostic-dll-copy-$($definition.Label).log")
                if ($copy.ExitCode -ne 0) {
                    throw "Diagnostic DLL copy failed for VM $($definition.Label)."
                }
                $install = Invoke-GuestAction -Config $config -Definition $definition `
                    -GuestAction 'InstallDiagnosticDll' -Arguments @(
                        '-PayloadPath', $guestDll, '-ExpectedDllSha256', $expectedHash
                    )
                Write-Output ("PASS action=DiagnosticDll vm={0} sha256={1} backup={2} service={3}" -f `
                    $definition.Label, $install.AfterSha256, $install.BackupPath, $install.ServiceState)
            }
        }
        'Trace' {
            foreach ($definition in $definitions) {
                $trace = Invoke-GuestAction -Config $config -Definition $definition `
                    -GuestAction 'Trace'
                Write-Output ("PASS action=Trace vm={0} lines={1}" -f `
                    $definition.Label, @($trace.TraceLines).Count)
            }
        }
        'ReconnectTrace' {
            foreach ($definition in $definitions) {
                $trace = Invoke-GuestAction -Config $config -Definition $definition `
                    -GuestAction 'ReconnectTrace'
                Write-Output ("PASS action=ReconnectTrace vm={0} id={1} T0-T1={2}ms T1-T2={3}ms T2-T3={4}ms" -f `
                    $definition.Label, $trace.Id, $trace.DeltaT0T1Ms,
                    $trace.DeltaT1T2Ms, $trace.DeltaT2T3Ms)
            }
        }
    }
} catch {
    $message = ConvertTo-SafeText $_.Exception.Message
    $fatalPath = Join-Path $script:ArtifactRoot 'fatal.log'
    $message | Set-Content -LiteralPath $fatalPath -Encoding UTF8
    Write-Output "FAIL action=$Action vm=$Vm error=$message artifacts=$script:ArtifactRoot"
    exit 1
} finally {
    $script:GuestPassword = $null
}

exit 0
