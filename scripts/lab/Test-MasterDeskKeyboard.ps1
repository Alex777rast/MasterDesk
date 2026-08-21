[CmdletBinding()]
param(
    [string]$ExePath = '.\dist\MasterDesk-1.4.9-10-beta-16-2026-08-19-RDS-x86_64.exe',
    [string]$ConfigPath = 'D:\Vms\MasterDeskLab\lab-config.psd1',
    [switch]$UseCurrentPreparedState,
    [switch]$KeepVmState,
    [switch]$RequireRdpSession,
    [switch]$NoRdpLaunch,
    [switch]$NoGuestAccept,
    [switch]$CloseTargetMainBeforeConnect,
    [ValidateSet('None', 'Prepare', 'Verify')]
    [string]$ManualStep = 'None',
    [string]$ManualSessionPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$runId = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
$artifactRoot = Join-Path $repoRoot "artifacts\lab\$runId\keyboard"
New-Item -ItemType Directory -Path $artifactRoot -Force | Out-Null
$guestPassword = [Environment]::GetEnvironmentVariable('MASTERDESK_LAB_PASSWORD')
$failures = New-Object System.Collections.Generic.List[string]
$script:GuestActionCounter = 0
$script:RequireHostRdpFocus = [bool]$RequireRdpSession

if (-not ('MasterDeskHostInput' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class MasterDeskHostInput {
    [DllImport("user32.dll")]
    public static extern void keybd_event(byte key, byte scan, uint flags, UIntPtr extraInfo);
    [DllImport("wtsapi32.dll", SetLastError = true)]
    private static extern bool WTSQuerySessionInformation(IntPtr server, int sessionId, int infoClass, out IntPtr buffer, out int bytes);
    [DllImport("wtsapi32.dll")]
    private static extern void WTSFreeMemory(IntPtr memory);
    public static string GetCurrentSessionState() {
        IntPtr buffer = IntPtr.Zero;
        int bytes = 0;
        int sessionId = System.Diagnostics.Process.GetCurrentProcess().SessionId;
        if (!WTSQuerySessionInformation(IntPtr.Zero, sessionId, 8, out buffer, out bytes)) {
            throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        }
        try {
            int state = Marshal.ReadInt32(buffer);
            string[] names = { "Active", "Connected", "ConnectQuery", "Shadow", "Disconnected", "Idle", "Listen", "Reset", "Down", "Init" };
            return state >= 0 && state < names.Length ? names[state] : state.ToString();
        } finally {
            WTSFreeMemory(buffer);
        }
    }
}
'@
}

function ConvertTo-SafeText([object]$Value) {
    $text = if ($null -eq $Value) { '' } else { [string]$Value }
    foreach ($secret in @($guestPassword)) {
        if ($secret) { $text = $text.Replace($secret, '<redacted>') }
    }
    return $text
}

function Invoke-Vmrun {
    param([hashtable]$Config, [object[]]$Arguments, [string]$LogPath, [switch]$Guest)
    $actual = New-Object System.Collections.Generic.List[object]
    $safe = New-Object System.Collections.Generic.List[string]
    $actual.Add('-T'); $actual.Add('ws'); $safe.Add('-T'); $safe.Add('ws')
    if ($Guest) {
        $actual.Add('-gu'); $actual.Add([string]$Config.GuestUser)
        $actual.Add('-gp'); $actual.Add($guestPassword)
        $safe.Add('-gu'); $safe.Add([string]$Config.GuestUser)
        $safe.Add('-gp'); $safe.Add('<redacted>')
    }
    foreach ($argument in $Arguments) { $actual.Add($argument); $safe.Add((ConvertTo-SafeText $argument)) }
    $raw = @(& $Config.Vmrun @actual 2>&1)
    $code = $LASTEXITCODE
    @("command=vmrun $($safe -join ' ')", "exitCode=$code", 'output:') +
        @($raw | ForEach-Object { ConvertTo-SafeText $_ }) |
        Set-Content -LiteralPath $LogPath -Encoding UTF8
    return [pscustomobject]@{
        ExitCode = [int]$code
        Output = @($raw | ForEach-Object { ConvertTo-SafeText $_ })
        LogPath = $LogPath
    }
}

function Wait-VmTools([hashtable]$Config, [hashtable]$Vm, [int]$Seconds = 90) {
    $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
    $attempt = 0
    do {
        $attempt++
        $state = Invoke-Vmrun -Config $Config -Arguments @('checkToolsState', $Vm.Vmx) `
            -LogPath (Join-Path $artifactRoot "$($Vm.Label)-tools-retry-$attempt.log")
        if ($state.ExitCode -eq 0 -and @($state.Output | Where-Object { $_.Trim() -eq 'running' }).Count -gt 0) {
            Start-Sleep -Seconds 10
            return
        }
        Start-Sleep -Seconds 3
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "VM $($Vm.Label) did not return to running VMware Tools state."
}

function Wait-ActiveRdpSession([hashtable]$Config, [hashtable]$Vm, [int]$Seconds = 90) {
    $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
    do {
        try {
            $session = Invoke-GuestAction $Config $Vm 'Session'
            if ([bool]$session.ActiveRdp) { return }
        } catch {
            # Keep polling until the bounded deadline; the caller reports a hard failure.
        }
        Start-Sleep -Seconds 3
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "VM $($Vm.Label) did not return to an active RDP session."
}

function Set-HostRdpActive([hashtable]$Vm) {
    if (-not $script:RequireHostRdpFocus) { return }
    $hostSessionState = [MasterDeskHostInput]::GetCurrentSessionState()
    if ($hostSessionState -ne 'Active') {
        throw "INCONCLUSIVE: host Windows session became $hostSessionState before VM $($Vm.Label) input; run the RDP input test from a persistently active interactive desktop."
    }
    $markerPath = Join-Path $repoRoot "artifacts\lab\rdp\$($Vm.Name).process.json"
    if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf)) {
        throw "RDP process marker is missing for VM $($Vm.Label): $markerPath"
    }
    $marker = Get-Content -LiteralPath $markerPath -Raw | ConvertFrom-Json
    $process = Get-Process -Id ([int]$marker.ProcessId) -ErrorAction SilentlyContinue
    if ($null -eq $process -or $process.ProcessName -ne 'mstsc') {
        throw "The recorded RDP client is not running for VM $($Vm.Label)."
    }
    $process.Refresh()
    if ($process.MainWindowHandle -eq [IntPtr]::Zero) {
        throw "INCONCLUSIVE: the mstsc client for VM $($Vm.Label) has no top-level window in the host session; run the RDP input test from a visible interactive desktop."
    }
    $shell = New-Object -ComObject WScript.Shell
    if (-not $shell.AppActivate([int]$marker.ProcessId)) {
        throw "Failed to activate the host RDP client for VM $($Vm.Label)."
    }
    Start-Sleep -Milliseconds 700
}

function Send-HostRdpInput {
    param(
        [hashtable]$Vm,
        [ValidateSet('A', 'CtrlShift', 'AltShift')]
        [string]$Input
    )

    Set-HostRdpActive -Vm $Vm
    switch ($Input) {
        'A' {
            [MasterDeskHostInput]::keybd_event(0x41, 0, 0, [UIntPtr]::Zero)
            Start-Sleep -Milliseconds 80
            [MasterDeskHostInput]::keybd_event(0x41, 0, 2, [UIntPtr]::Zero)
        }
        'CtrlShift' {
            [MasterDeskHostInput]::keybd_event(0x11, 0, 0, [UIntPtr]::Zero)
            Start-Sleep -Milliseconds 60
            [MasterDeskHostInput]::keybd_event(0x10, 0, 0, [UIntPtr]::Zero)
            Start-Sleep -Milliseconds 120
            [MasterDeskHostInput]::keybd_event(0x10, 0, 2, [UIntPtr]::Zero)
            Start-Sleep -Milliseconds 60
            [MasterDeskHostInput]::keybd_event(0x11, 0, 2, [UIntPtr]::Zero)
        }
        'AltShift' {
            [MasterDeskHostInput]::keybd_event(0x12, 0, 0, [UIntPtr]::Zero)
            Start-Sleep -Milliseconds 60
            [MasterDeskHostInput]::keybd_event(0x10, 0, 0, [UIntPtr]::Zero)
            Start-Sleep -Milliseconds 120
            [MasterDeskHostInput]::keybd_event(0x10, 0, 2, [UIntPtr]::Zero)
            Start-Sleep -Milliseconds 60
            [MasterDeskHostInput]::keybd_event(0x12, 0, 2, [UIntPtr]::Zero)
        }
    }
    Start-Sleep -Seconds 3
}

function Invoke-LabStep([string]$Name, [string[]]$Arguments) {
    $log = Join-Path $artifactRoot "$Name.log"
    $childArguments = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
        (Join-Path $PSScriptRoot 'Test-MasterDeskLab.ps1')
    ) + $Arguments
    $powershell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $output = @(& $powershell @childArguments 2>&1)
    $code = $LASTEXITCODE
    @($output | ForEach-Object { ConvertTo-SafeText $_ }) | Set-Content -LiteralPath $log -Encoding UTF8
    if ($code -ne 0) { throw "$Name failed; log=$log" }
}

function Copy-GuestProbe([hashtable]$Config, [hashtable]$Vm) {
    foreach ($attempt in 1..3) {
        $log = Join-Path $artifactRoot "copy-probe-$($Vm.Label)-$attempt.log"
        $response = Invoke-Vmrun -Config $Config -Guest -Arguments @(
            'copyFileFromHostToGuest', $Vm.Vmx, (Join-Path $PSScriptRoot 'Invoke-MasterDeskKeyboardGuest.ps1'),
            'C:\MasterDeskLab\Invoke-MasterDeskKeyboardGuest.ps1') -LogPath $log
        if ($response.ExitCode -eq 0) { return }
        $failureText = @($response.Output) -join "`n"
        if ($attempt -lt 3 -and $failureText -match '(?i)not powered on') {
            Wait-VmTools -Config $Config -Vm $Vm
            continue
        }
        throw "copy probe failed for VM $($Vm.Label); log=$log"
    }
}

function Invoke-GuestAction {
    param([hashtable]$Config, [hashtable]$Vm, [string]$Name, [string[]]$Arguments = @())
    $script:GuestActionCounter++
    $actionId = "{0:D3}-{1}" -f $script:GuestActionCounter, $Name
    foreach ($attempt in 1..2) {
        if ($Name -ne 'Session') { Set-HostRdpActive -Vm $Vm }
        $guestResult = "C:\MasterDeskLab\keyboard-$runId-$actionId-$attempt.json"
        $hostResult = Join-Path $artifactRoot "$($Vm.Label)-$actionId-$attempt.json"
        $runLog = Join-Path $artifactRoot "$($Vm.Label)-$actionId-$attempt-run.log"
        $copyLog = Join-Path $artifactRoot "$($Vm.Label)-$actionId-$attempt-copy.log"
        $interactiveArguments = if ($Name -eq 'Session') { @() } else { @('-interactive') }
        $guestArgs = @(
            'runProgramInGuest', $Vm.Vmx
        ) + $interactiveArguments + @(
            'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe',
            '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
            '-File', 'C:\MasterDeskLab\Invoke-MasterDeskKeyboardGuest.ps1',
            '-Action', $Name, '-OutputPath', $guestResult) + $Arguments
        $run = Invoke-Vmrun -Config $Config -Guest -Arguments $guestArgs -LogPath $runLog
        $copy = Invoke-Vmrun -Config $Config -Guest -Arguments @(
            'copyFileFromGuestToHost', $Vm.Vmx, $guestResult, $hostResult
        ) -LogPath $copyLog
        if ($copy.ExitCode -eq 0 -and (Test-Path -LiteralPath $hostResult)) {
            $result = Get-Content -LiteralPath $hostResult -Raw | ConvertFrom-Json
            if (-not [bool]$result.Passed) {
                throw "VM $($Vm.Label) action $Name failed: $($result.Error)"
            }
            if ($run.ExitCode -ne 0) {
                throw "VM $($Vm.Label) action $Name returned exit code $($run.ExitCode)."
            }
            return $result
        }

        $transientText = @(
            Get-Content -LiteralPath $runLog -Raw -ErrorAction SilentlyContinue
            Get-Content -LiteralPath $copyLog -Raw -ErrorAction SilentlyContinue
        ) -join "`n"
        if ($attempt -eq 1 -and $transientText -match
            '(?i)not powered on|tools.*not running|guest operations.*not available|must be logged in interactively') {
            if ($transientText -match '(?i)not powered on|tools.*not running|guest operations.*not available') {
                Wait-VmTools -Config $Config -Vm $Vm
            }
            if ($Name -ne 'Session') {
                Wait-ActiveRdpSession -Config $Config -Vm $Vm
            }
            continue
        }
        throw "guest result missing for VM $($Vm.Label) action $Name"
    }
}

function Test-Layouts([string]$Name, [object]$A, [object]$B, [string]$Expected) {
    $passed = [string]$A.Klid -eq $Expected -and [string]$B.Klid -eq $Expected
    if (-not $passed) { $failures.Add("$Name expected=$Expected controller=$($A.Klid) target=$($B.Klid)") }
    return $passed
}

try {
    if (-not $guestPassword) { throw 'MASTERDESK_LAB_PASSWORD is not set.' }
    if ($RequireRdpSession) {
        $hostSessionState = [MasterDeskHostInput]::GetCurrentSessionState()
        if ($hostSessionState -ne 'Active') {
            throw "INCONCLUSIVE: host Windows session is $hostSessionState; run the RDP input test from an active interactive desktop."
        }
    }
    $config = Import-PowerShellDataFile -LiteralPath $ConfigPath
    $candidate = (Resolve-Path -LiteralPath $ExePath).ProviderPath
    $runner = Join-Path $repoRoot 'flutter\build\windows\x64\runner\Release\rustdesk.exe'
    $dll = Join-Path $repoRoot 'flutter\build\windows\x64\runner\Release\librustdesk.dll'
    $runnerHash = (Get-FileHash -LiteralPath $runner -Algorithm SHA256).Hash
    $dllHash = (Get-FileHash -LiteralPath $dll -Algorithm SHA256).Hash
    $vmA = @{ Label='A'; Name=[string]$config.VmAName; Vmx=[string]$config.VmA }
    $vmB = @{ Label='B'; Name=[string]$config.VmBName; Vmx=[string]$config.VmB }

    if ($ManualStep -eq 'Verify') {
        if (-not $ManualSessionPath) {
            $ManualSessionPath = Get-ChildItem (Join-Path $repoRoot 'artifacts\lab') `
                -Filter 'manual-session.json' -Recurse -File -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1 -ExpandProperty FullName
        }
        if (-not $ManualSessionPath -or -not (Test-Path -LiteralPath $ManualSessionPath)) {
            throw 'Manual keyboard session artifact was not found.'
        }
        $manualSession = Get-Content -LiteralPath $ManualSessionPath -Raw | ConvertFrom-Json
        Copy-GuestProbe $config $vmA
        Copy-GuestProbe $config $vmB
        if ($RequireRdpSession) {
            $sessionA = Invoke-GuestAction $config $vmA 'Session'
            $sessionB = Invoke-GuestAction $config $vmB 'Session'
            if (-not [bool]$sessionA.ActiveRdp -or -not [bool]$sessionB.ActiveRdp) {
                throw 'Active RDP sessions are required on both VM A and VM B.'
            }
        }
        $stateA = Invoke-GuestAction $config $vmA 'State' @('-Role','Target')
        $stateB = Invoke-GuestAction $config $vmB 'State' @(
            '-Role','Controller','-PeerId',[string]$manualSession.PeerId)
        $stuck = @(@($stateB.Modifiers, $stateA.Modifiers) | Where-Object {
            [bool]$_.Alt -or [bool]$_.Shift -or [bool]$_.LeftShift -or [bool]$_.RightShift
        }).Count -gt 0
        $synced = [string]$stateB.Klid -eq '04190419' -and [string]$stateA.Klid -eq '04190419'
        foreach ($vm in @($vmA, $vmB)) {
            [void](Invoke-Vmrun -Config $config -Guest -Arguments @(
                'captureScreen', $vm.Vmx, (Join-Path $artifactRoot "manual-screen-$($vm.Label).png")
            ) -LogPath (Join-Path $artifactRoot "manual-screen-$($vm.Label).log"))
        }
        [ordered]@{
            Passed = $synced -and -not $stuck
            Expected = '04190419'
            Controller = [string]$stateB.Klid
            Target = [string]$stateA.Klid
            StuckModifiers = $stuck
            Session = $ManualSessionPath
        } | ConvertTo-Json -Depth 6 |
            Set-Content -LiteralPath (Join-Path $artifactRoot 'manual-verify.json') -Encoding UTF8
        if ($synced -and -not $stuck) {
            Write-Output "PASS scenario=Keyboard step=physical-verify controller=B target=A layout=RU modifiers=clear artifacts=$artifactRoot"
            exit 0
        }
        Write-Output "FAIL scenario=Keyboard step=physical-verify controller=B:$($stateB.Klid) target=A:$($stateA.Klid) modifiersStuck=$stuck artifacts=$artifactRoot"
        exit 1
    }

    if (-not $UseCurrentPreparedState) {
        Invoke-LabStep 'install-A-clean' @('-Action','Scenario','-Scenario','Install','-Vm','A','-ExePath',$candidate)
        Invoke-LabStep 'reset-B' @('-Action','Reset','-Vm','B')
        Invoke-LabStep 'start-B' @('-Action','Start','-Vm','B')
        Invoke-LabStep 'deploy-B' @('-Action','Deploy','-Vm','B','-ExePath',$candidate)
    }
    Copy-GuestProbe $config $vmA
    Copy-GuestProbe $config $vmB

    if ($RequireRdpSession -and $ManualStep -ne 'Prepare') {
        $sessionA = Invoke-GuestAction $config $vmA 'Session'
        $sessionB = Invoke-GuestAction $config $vmB 'Session'
        if (-not [bool]$sessionA.ActiveRdp -or -not [bool]$sessionB.ActiveRdp) {
            throw 'Active RDP sessions are required on both VM A and VM B.'
        }
    }

    $prepareAArguments = @(
        '-ExpectedRunnerSha256',$runnerHash,'-ExpectedDllSha256',$dllHash,'-InstallOrUpgrade')
    $prepareA = Invoke-GuestAction $config $vmA 'Prepare' $prepareAArguments
    $prepareB = Invoke-GuestAction $config $vmB 'Prepare' @(
        '-ExpectedRunnerSha256',$runnerHash,'-ExpectedDllSha256',$dllHash,'-InstallOrUpgrade')
    if ($prepareA.Id -eq $prepareB.Id) { throw 'VM A and B have the same MasterDesk ID.' }

    [void](Invoke-GuestAction $config $vmA 'StartTarget')
    if ($CloseTargetMainBeforeConnect) {
        [void](Invoke-GuestAction $config $vmA 'CloseMain')
    }
    $connectArguments = @('-PeerId', [string]$prepareA.Id)
    [void](Invoke-GuestAction $config $vmB 'Connect' $connectArguments)
    if (-not $NoGuestAccept) {
        [void](Invoke-GuestAction $config $vmA 'Accept')
    }
    [void](Invoke-GuestAction $config $vmB 'SelectRdpSession' @(
        '-Role','Controller','-PeerId',[string]$prepareA.Id))
    [void](Invoke-GuestAction $config $vmA 'SetLayout' @('-Role','Target','-Layout','00000409'))
    [void](Invoke-GuestAction $config $vmB 'SetLayout' @('-Role','Controller','-PeerId',[string]$prepareA.Id,'-Layout','00000409'))

    $a0 = Invoke-GuestAction $config $vmA 'State' @('-Role','Target')
    $b0 = Invoke-GuestAction $config $vmB 'State' @('-Role','Controller','-PeerId',[string]$prepareA.Id)
    [void](Test-Layouts 'initial' $b0 $a0 '04090409')

    if ($ManualStep -eq 'Prepare') {
        if ($failures.Count -gt 0) { throw "Manual baseline failed: $($failures -join '; ')" }
        [void](Invoke-GuestAction $config $vmB 'Focus' @(
            '-Role','Controller','-PeerId',[string]$prepareA.Id))
        $manualPath = Join-Path $artifactRoot 'manual-session.json'
        [ordered]@{
            TimestampUtc = [DateTime]::UtcNow.ToString('o')
            PeerId = [string]$prepareA.Id
            CandidateSha256 = (Get-FileHash -LiteralPath $candidate -Algorithm SHA256).Hash
            DllSha256 = $dllHash
            InitialController = [string]$b0.Klid
            InitialTarget = [string]$a0.Klid
        } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $manualPath -Encoding UTF8
        if (-not $NoRdpLaunch) {
            & (Join-Path $PSScriptRoot 'Open-MasterDeskLabRdp.ps1') -Vm All `
                -ConfigPath $ConfigPath
        }
        $KeepVmState = $true
        Write-Output "READY scenario=Keyboard step=physical-alt-shift controller=B target=A layout=EN session=$manualPath"
        exit 0
    }

    [void](Invoke-GuestAction $config $vmB 'Focus' @('-Role','Controller','-PeerId',[string]$prepareA.Id))
    [void](Invoke-GuestAction $config $vmA 'Focus' @('-Role','Target'))
    Send-HostRdpInput -Vm $vmB -Input 'A'
    $typed = Invoke-GuestAction $config $vmA 'ReadTarget'
    $remoteInputProven = [string]$typed.Text -match '(?i)a'
    if (-not $remoteInputProven) { throw 'Host RDP A key did not reach remote Notepad; keyboard hotkey result is inconclusive.' }

    [void](Invoke-GuestAction $config $vmB 'Focus' @('-Role','Controller','-PeerId',[string]$prepareA.Id))
    [void](Invoke-GuestAction $config $vmA 'Focus' @('-Role','Target'))
    Send-HostRdpInput -Vm $vmB -Input 'CtrlShift'
    $a1 = Invoke-GuestAction $config $vmA 'State' @('-Role','Target')
    $b1 = Invoke-GuestAction $config $vmB 'State' @('-Role','Controller','-PeerId',[string]$prepareA.Id)
    $controllerToRu = Test-Layouts 'controller-to-RU' $b1 $a1 '04190419'

    [void](Invoke-GuestAction $config $vmB 'Focus' @('-Role','Controller','-PeerId',[string]$prepareA.Id))
    [void](Invoke-GuestAction $config $vmA 'Focus' @('-Role','Target'))
    Send-HostRdpInput -Vm $vmB -Input 'AltShift'
    $a2 = Invoke-GuestAction $config $vmA 'State' @('-Role','Target')
    $b2 = Invoke-GuestAction $config $vmB 'State' @('-Role','Controller','-PeerId',[string]$prepareA.Id)
    $controllerToEn = Test-Layouts 'controller-to-EN' $b2 $a2 '04090409'

    [void](Invoke-GuestAction $config $vmA 'Focus' @('-Role','Target'))
    Send-HostRdpInput -Vm $vmA -Input 'AltShift'
    $a3 = Invoke-GuestAction $config $vmA 'State' @('-Role','Target')
    $b3 = Invoke-GuestAction $config $vmB 'State' @('-Role','Controller','-PeerId',[string]$prepareA.Id)
    $targetToRu = Test-Layouts 'target-to-RU' $b3 $a3 '04190419'
    [void](Invoke-GuestAction $config $vmA 'Focus' @('-Role','Target'))
    Send-HostRdpInput -Vm $vmA -Input 'AltShift'

    $modifierObjects = @($a1.Modifiers, $b1.Modifiers, $a2.Modifiers, $b2.Modifiers,
        $a3.Modifiers, $b3.Modifiers)
    $stuckModifiers = @($modifierObjects | Where-Object {
        [bool]$_.Alt -or [bool]$_.Shift -or [bool]$_.LeftShift -or [bool]$_.RightShift
    }).Count -gt 0
    if ($stuckModifiers) { $failures.Add('Alt/Shift modifier remained pressed.') }

    foreach ($vm in @($vmA, $vmB)) {
        [void](Invoke-Vmrun -Config $config -Guest -Arguments @(
            'captureScreen', $vm.Vmx, (Join-Path $artifactRoot "screen-$($vm.Label).png")
        ) -LogPath (Join-Path $artifactRoot "screen-$($vm.Label).log"))
    }

    [ordered]@{
        Passed=$failures.Count -eq 0
        CandidateSha256=(Get-FileHash -LiteralPath $candidate -Algorithm SHA256).Hash
        RunnerSha256=$runnerHash; DllSha256=$dllHash
        Baselines=@{ A=[string]$config.VmASnapshotRdpOn; B=[string]$config.VmBSnapshotRdpOn }
        ExactCandidate=@{ A=$prepareA.DllSha256 -eq $dllHash; B=$prepareB.DllSha256 -eq $dllHash }
        RemoteInputProven=$remoteInputProven
        InputPath='host-mstsc-to-B-to-MasterDesk-to-A'
        ControllerChords=@('CtrlShift','AltShift')
        ControllerToRu=$controllerToRu; ControllerToEn=$controllerToEn
        TargetToRu=$targetToRu; StuckModifiers=$stuckModifiers
        Roles=@{ Controller='B'; Target='A' }
        States=@{ Initial=@{A=$a0.Klid;B=$b0.Klid}; ControllerRu=@{A=$a1.Klid;B=$b1.Klid}; ControllerEn=@{A=$a2.Klid;B=$b2.Klid}; TargetRu=@{A=$a3.Klid;B=$b3.Klid} }
        Failures=@($failures)
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $artifactRoot 'summary.json') -Encoding UTF8

    if ($failures.Count -eq 0) {
        Write-Output "PASS scenario=Keyboard vm=A+B controller=B:EN-RU-EN target=A:EN-RU sync=ok modifiers=clear artifacts=$artifactRoot"
        exit 0
    }
    Write-Output ("FAIL scenario=Keyboard vm=A+B stage=layout-sync failures={0} artifacts={1}" -f ($failures -join '; '), $artifactRoot)
    exit 1
} catch {
    $safeError = ConvertTo-SafeText $_.Exception.Message
    $safeError | Set-Content -LiteralPath (Join-Path $artifactRoot 'fatal.log') -Encoding UTF8
    $classification = if ($safeError -match '(?i)inconclusive') { 'INCONCLUSIVE' } else { 'FAIL' }
    Write-Output "$classification scenario=Keyboard vm=A+B stage=orchestration error=$safeError artifacts=$artifactRoot"
    exit 1
} finally {
    if (-not $KeepVmState) {
        try {
            $resetConfig = Import-PowerShellDataFile -LiteralPath $ConfigPath
            $resetCommands = @(
                @('-Action','Reset','-Vm','A','-SnapshotName',[string]$resetConfig.VmASnapshotRegistered),
                @('-Action','Reset','-Vm','B')
            )
            foreach ($resetArguments in $resetCommands) {
                $vmLabel = $resetArguments[3]
                $resetParameters = @{}
                for ($index = 0; $index -lt $resetArguments.Count; $index += 2) {
                    $resetParameters[$resetArguments[$index].TrimStart('-')] = $resetArguments[$index + 1]
                }
                $resetChildArguments = @(
                    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
                    (Join-Path $PSScriptRoot 'Test-MasterDeskLab.ps1')
                )
                foreach ($key in @($resetParameters.Keys | Sort-Object)) {
                    $resetChildArguments += @("-$key", $resetParameters[$key])
                }
                $powershell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
                @(& $powershell @resetChildArguments 2>&1) |
                    ForEach-Object { ConvertTo-SafeText $_ } |
                    Set-Content -LiteralPath (Join-Path $artifactRoot "restore-$vmLabel.log") -Encoding UTF8
            }
        } catch {
            (ConvertTo-SafeText $_.Exception.Message) |
                Set-Content -LiteralPath (Join-Path $artifactRoot 'restore-failure.log') -Encoding UTF8
        }
    }
    $guestPassword = $null
}
