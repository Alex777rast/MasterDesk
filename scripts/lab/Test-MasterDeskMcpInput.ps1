[CmdletBinding()]
param(
    [string]$ExePath = '.\dist\MasterDesk-1.4.9-10-beta-16-2026-08-19-RDS-x86_64.exe',

    [string]$ConfigPath = 'D:\Vms\MasterDeskLab\lab-config.psd1',

    [string]$OutputDirectory,

    [ValidateSet('Approval', 'TemporaryPassword')]
    [string]$AuthorizationMode = 'Approval'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
if (-not $OutputDirectory) {
    $OutputDirectory = Join-Path $repoRoot (
        'artifacts\gui-runs\{0}\input-test' -f (Get-Date -Format 'yyyyMMdd-HHmmss-fff')
    )
}
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$guestPassword = [Environment]::GetEnvironmentVariable('MASTERDESK_LAB_PASSWORD')
$infrastructureReady = $false
$connectionEstablished = $false
$authorizationAttemptReached = $false
$rdpSessionSelected = $false
$expected = 'MD_E2E_{0}' -f (Get-Date -Format 'yyyyMMdd_HHmmssfff')

function ConvertTo-SafeText([object]$Value) {
    $text = [string]$Value
    if ($guestPassword) { $text = $text.Replace($guestPassword, '<redacted>') }
    return $text
}

function Invoke-McpTool {
    param(
        [ValidateSet('A', 'B')][string]$Vm,
        [string]$Tool,
        [hashtable]$Arguments,
        [string]$ArtifactName
    )

    $json = $Arguments | ConvertTo-Json -Depth 8 -Compress
    $output = @(& (Join-Path $PSScriptRoot 'Invoke-MasterDeskWindowsMcpTool.ps1') `
        -Vm $Vm -Tool $Tool -ArgumentsJson $json -OutputDirectory $OutputDirectory `
        -ArtifactName $ArtifactName -ConfigPath $ConfigPath 2>&1)
    $output | ForEach-Object { ConvertTo-SafeText $_ } | Add-Content -LiteralPath (
        Join-Path $OutputDirectory 'mcp-calls.log'
    ) -Encoding UTF8
    $reportPath = Join-Path $OutputDirectory "$ArtifactName-$Vm.json"
    if (-not (Test-Path -LiteralPath $reportPath -PathType Leaf)) {
        throw "MCP $Tool did not create its report for VM $Vm."
    }
    return Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json
}

function Invoke-GuestKeyboardState {
    param(
        [hashtable]$Config,
        [ValidateSet('A', 'B')][string]$Vm,
        [string]$PeerId,
        [string]$ArtifactName,
        [ValidateSet('State', 'Foreground', 'ReadTarget', 'Accept')][string]$Action = 'State'
    )

    if (-not $guestPassword) { throw 'MASTERDESK_LAB_PASSWORD is not set.' }
    $vmx = if ($Vm -eq 'A') { [string]$Config.VmA } else { [string]$Config.VmB }
    $role = if ($Vm -eq 'A') { 'Target' } else { 'Controller' }
    $guestResult = "C:\MasterDeskLab\$ArtifactName-$Vm.json"
    $arguments = @(
        '-T', 'ws', '-gu', [string]$Config.GuestUser, '-gp', $guestPassword,
        'runProgramInGuest', $vmx, '-interactive',
        'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe',
        '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
        '-File', 'C:\MasterDeskLab\Invoke-MasterDeskKeyboardGuest.ps1',
        '-Action', $Action, '-OutputPath', $guestResult, '-Role', $role
    )
    if ($Vm -eq 'B') { $arguments += @('-PeerId', $PeerId) }
    $raw = @(& $Config.Vmrun @arguments 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "Guest keyboard state failed for VM ${Vm}: $(@($raw | Select-Object -Last 2) -join ' | ')"
    }
    $hostResult = Join-Path $OutputDirectory "$ArtifactName-$Vm.json"
    & $Config.Vmrun -T ws -gu $Config.GuestUser -gp $guestPassword `
        copyFileFromGuestToHost $vmx $guestResult $hostResult 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $hostResult)) {
        throw "Guest keyboard state copy failed for VM $Vm."
    }
    return Get-Content -LiteralPath $hostResult -Raw | ConvertFrom-Json
}

function Save-GuestRuntimeState {
    param(
        [hashtable]$Config,
        [ValidateSet('A', 'B')][string]$Vm,
        [string]$ArtifactName
    )

    if (-not $guestPassword) { throw 'MASTERDESK_LAB_PASSWORD is not set.' }
    $vmx = if ($Vm -eq 'A') { [string]$Config.VmA } else { [string]$Config.VmB }
    $source = Join-Path $PSScriptRoot 'Get-MasterDeskGuestRuntimeState.ps1'
    $guestScript = 'C:\MasterDeskLab\Get-MasterDeskGuestRuntimeState.ps1'
    $guestResult = "C:\MasterDeskLab\$ArtifactName-$Vm.json"
    $hostResult = Join-Path $OutputDirectory "$ArtifactName-$Vm.json"
    & $Config.Vmrun -T ws -gu $Config.GuestUser -gp $guestPassword `
        copyFileFromHostToGuest $vmx $source $guestScript 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Guest runtime helper copy failed for VM $Vm." }
    & $Config.Vmrun -T ws -gu $Config.GuestUser -gp $guestPassword `
        runProgramInGuest $vmx 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' `
        -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $guestScript `
        -OutputPath $guestResult 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Guest runtime collection failed for VM $Vm." }
    & $Config.Vmrun -T ws -gu $Config.GuestUser -gp $guestPassword `
        copyFileFromGuestToHost $vmx $guestResult $hostResult 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $hostResult)) {
        throw "Guest runtime state copy failed for VM $Vm."
    }
}

try {
    $candidate = (Resolve-Path -LiteralPath $ExePath -ErrorAction Stop).ProviderPath
    $config = Import-PowerShellDataFile -LiteralPath $ConfigPath
    foreach ($key in @('Vmrun', 'VmA', 'VmB', 'VmAComputerName', 'GuestUser')) {
        if (-not $config.ContainsKey($key) -or
                [string]::IsNullOrWhiteSpace([string]$config[$key])) {
            throw "Missing lab configuration key: $key"
        }
    }

    & (Join-Path $PSScriptRoot 'Test-MasterDeskWindowsMcpEndpoint.ps1') -Vm All `
        -ConfigPath $ConfigPath -OutputDirectory (Join-Path $OutputDirectory 'protocol')
    Save-GuestRuntimeState -Config $config -Vm A -ArtifactName '00-runtime-before'
    Save-GuestRuntimeState -Config $config -Vm B -ArtifactName '00-runtime-before'
    [void](Invoke-McpTool -Vm A -Tool Screenshot -Arguments @{
        display = @(0); use_annotation = $false
    } -ArtifactName '01-before-connection')
    [void](Invoke-McpTool -Vm B -Tool Screenshot -Arguments @{
        display = @(0); use_annotation = $false
    } -ArtifactName '01-before-connection')
    $infrastructureReady = $true

    $prepareOutput = @(& (Join-Path $PSScriptRoot 'Test-MasterDeskKeyboard.ps1') `
        -ExePath $candidate -ConfigPath $ConfigPath -UseCurrentPreparedState `
        -KeepVmState -RequireRdpSession -ManualStep Prepare -NoRdpLaunch `
        -NoGuestAccept `
        -CloseTargetMainBeforeConnect:($AuthorizationMode -eq 'TemporaryPassword') 2>&1)
    $prepareCode = $LASTEXITCODE
    $prepareOutput | ForEach-Object { ConvertTo-SafeText $_ } |
        Set-Content -LiteralPath (Join-Path $OutputDirectory 'prepare.log') -Encoding UTF8
    if ($prepareCode -ne 0) { throw 'MasterDesk connection preparation failed.' }
    $readyLine = @($prepareOutput | Where-Object { [string]$_ -match '^READY\s' } | Select-Object -Last 1)
    if ($readyLine.Count -ne 1 -or [string]$readyLine[0] -notmatch 'session=(.+)$') {
        throw 'Connection preparation did not return a manual-session artifact.'
    }
    $manualSessionPath = $matches[1].Trim()
    $manualSession = Get-Content -LiteralPath $manualSessionPath -Raw | ConvertFrom-Json
    $peerId = [string]$manualSession.PeerId
    $viewerName = '{0}@{1} - Remote Desktop - MasterDesk' -f `
        $peerId, [string]$config.VmAComputerName

    if ($AuthorizationMode -eq 'TemporaryPassword') {
        [void](Invoke-McpTool -Vm B -Tool Wait -Arguments @{ duration = 5 } `
            -ArtifactName '02-wait-authorization')
        $controllerAuth = Invoke-McpTool -Vm B -Tool Snapshot -Arguments @{
            display = @(0); use_vision = $true; use_annotation = $false
        } -ArtifactName '02-password-prompt-controller'
        $controllerText = @($controllerAuth.Text) -join "`n"
        $passwordRequiredRu = -join [char[]]@(
            0x0412,0x0432,0x0435,0x0434,0x0438,0x0442,0x0435,0x0020,
            0x043F,0x0430,0x0440,0x043E,0x043B,0x044C
        )
        $confirmMasterDeskPasswordRu = -join [char[]]@(
            0x041F,0x043E,0x0434,0x0442,0x0432,0x0435,0x0440,0x0434,0x0438,0x0442,0x044C,
            0x0020,0x043F,0x0430,0x0440,0x043E,0x043B,0x044C,0x0020,
            0x004D,0x0061,0x0073,0x0074,0x0065,0x0072,0x0044,0x0065,0x0073,0x006B
        )
        $waitApprovalRu = -join [char[]]@(
            0x041F,0x043E,0x0434,0x043E,0x0436,0x0434,0x0438,0x0442,0x0435,0x002C,0x0020,
            0x043F,0x043E,0x043A,0x0430,0x0020,0x0443,0x0434,0x0430,0x043B,0x0451,0x043D,
            0x043D,0x0430,0x044F,0x0020,0x0441,0x0442,0x043E,0x0440,0x043E,0x043D,0x0430
        )
        $authorizationAttemptReached = $controllerText -match [regex]::Escape($peerId)
        $passwordPromptShown = $controllerText -match '(?i)Password Required|Please enter your password' -or
            $controllerText -match [regex]::Escape($passwordRequiredRu) -or
            $controllerText -match [regex]::Escape($confirmMasterDeskPasswordRu)
        $approvalWaitShown = $controllerText -match '(?i)Please wait for the remote side to accept' -or
            $controllerText -match [regex]::Escape($waitApprovalRu)

        [void](Invoke-McpTool -Vm A -Tool Process -Arguments @{
            mode = 'list'; name = 'masterdesk'; limit = 20; sort_by = 'name'
        } -ArtifactName '03-processes-target')
        [void](Invoke-McpTool -Vm B -Tool Process -Arguments @{
            mode = 'list'; name = 'masterdesk'; limit = 20; sort_by = 'name'
        } -ArtifactName '03-processes-controller')
        Save-GuestRuntimeState -Config $config -Vm A -ArtifactName '04-runtime-after'
        Save-GuestRuntimeState -Config $config -Vm B -ArtifactName '04-runtime-after'

        if (-not $authorizationAttemptReached) {
            throw 'The controller authorization window was not detected.'
        }
        if ($approvalWaitShown) {
            throw 'MasterDesk selected mandatory local approval instead of temporary-password authorization.'
        }
        if (-not $passwordPromptShown) {
            throw 'The temporary-password entry prompt was not detected on VM B.'
        }

        [ordered]@{
            Classification = 'PASS'
            CompletedUtc = [DateTime]::UtcNow.ToString('o')
            Candidate = Split-Path -Leaf $candidate
            CandidateSha256 = (Get-FileHash -LiteralPath $candidate -Algorithm SHA256).Hash
            Controller = 'VM10-B'
            Target = 'VM10-A'
            Authorization = 'TemporaryPassword'
            PasswordPromptShown = $passwordPromptShown
            ApprovalWaitShown = $approvalWaitShown
            TargetAcceptClicked = $false
            TemporaryPasswordReadOrUsed = $false
        } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (
            Join-Path $OutputDirectory 'result.json'
        ) -Encoding UTF8
        Write-Output "PASS scenario=PasswordTest controller=B target=A prompt=temporary-password targetAcceptClicked=False artifacts=$OutputDirectory"
        exit 0
    }

    $target = Invoke-McpTool -Vm A -Tool Snapshot -Arguments @{
        display = @(0); use_vision = $true; use_annotation = $false
    } -ArtifactName '02-request-on-target'
    $targetText = @($target.Text) -join "`n"
    $incomingMatch = [regex]::Match($targetText, '\b\d+ - MasterDesk\b')
    if ($incomingMatch.Success) {
        $incomingTitle = $incomingMatch.Value
        [void](Invoke-McpTool -Vm A -Tool App -Arguments @{
            mode = 'switch'; name = $incomingTitle
        } -ArtifactName '02-focus-request-on-target')
        # The button is custom drawn and absent from UIAutomation. StartTarget
        # closes OneDrive so this stable lab coordinate cannot be obscured.
        [void](Invoke-McpTool -Vm A -Tool Click -Arguments @{
            loc = @(684, 451); button = 'left'; clicks = 1
        } -ArtifactName '02-accept-on-target')
    }
    [void](Invoke-McpTool -Vm B -Tool Wait -Arguments @{ duration = 5 } `
        -ArtifactName '02-wait-accept')
    [void](Invoke-McpTool -Vm A -Tool Screenshot -Arguments @{
        display = @(0); use_annotation = $false
    } -ArtifactName '02-after-connection')
    $viewer = Invoke-McpTool -Vm B -Tool Snapshot -Arguments @{
        display = @(0); use_vision = $true; use_annotation = $false
    } -ArtifactName '02-after-connection'
    $viewerText = @($viewer.Text) -join "`n"
    if ($viewerText -match 'Error capturing desktop state') {
        Start-Sleep -Seconds 3
        $viewer = Invoke-McpTool -Vm B -Tool Snapshot -Arguments @{
            display = @(0); use_vision = $true; use_annotation = $false
        } -ArtifactName '02-after-connection-retry'
        $viewerText = @($viewer.Text) -join "`n"
    }
    $connectionEstablished = $viewerText -match [regex]::Escape($peerId) -and
        $viewerText -match 'Console'
    if (-not $connectionEstablished) {
        throw 'Accepted MasterDesk connection and Windows session picker were not detected on VM B.'
    }

    $sessionPickerMatch = [regex]::Match(
        $viewerText,
        '\((\d+),\s*(\d+)\)[^\r\n]*"[^"\r\n]*\r?\nConsole"',
        'IgnoreCase'
    )
    if (-not $sessionPickerMatch.Success) {
        throw 'Windows session picker controls were not detected on VM B.'
    }
    # Flutter reports the closed combo box above its visual hit target. The
    # Connect button is accurate, so anchor the combo click to that dialog.
    $sessionPickerLocation = @(
        [int]$sessionPickerMatch.Groups[1].Value,
        ([int]$sessionPickerMatch.Groups[2].Value + 40)
    )
    $connectLocation = @(
        ([int]$sessionPickerMatch.Groups[1].Value + 131),
        ([int]$sessionPickerMatch.Groups[2].Value + 98)
    )

    [void](Invoke-McpTool -Vm B -Tool App -Arguments @{
        mode = 'switch'; name = $viewerName
    } -ArtifactName '03-focus-viewer')
    [void](Invoke-McpTool -Vm B -Tool Click -Arguments @{
        loc = $sessionPickerLocation; button = 'left'; clicks = 1
    } -ArtifactName '03-open-session-list')
    $sessionList = Invoke-McpTool -Vm B -Tool Snapshot -Arguments @{
        display = @(0); use_vision = $true; use_annotation = $false
    } -ArtifactName '03-session-list'
    $sessionListText = @($sessionList.Text) -join "`n"
    $rdpSessionMatch = [regex]::Match(
        $sessionListText,
        '\((\d+),\s*(\d+)\)[^\r\n]*"RDP:[^"]*"',
        'IgnoreCase'
    )
    if (-not $rdpSessionMatch.Success) {
        throw 'Active RDP session option was not detected on VM B.'
    }
    $rdpSessionLocation = @(
        [int]$rdpSessionMatch.Groups[1].Value,
        [int]$rdpSessionMatch.Groups[2].Value
    )
    [void](Invoke-McpTool -Vm B -Tool Click -Arguments @{
        loc = $rdpSessionLocation; button = 'left'; clicks = 1
    } -ArtifactName '03-select-rdp-session')
    [void](Invoke-McpTool -Vm B -Tool Click -Arguments @{
        loc = $connectLocation; button = 'left'; clicks = 1
    } -ArtifactName '03-connect-rdp-session')
    [void](Invoke-McpTool -Vm B -Tool Wait -Arguments @{ duration = 5 } `
        -ArtifactName '03-wait-rdp-session')
    $selectedViewer = Invoke-McpTool -Vm B -Tool Snapshot -Arguments @{
        display = @(0); use_vision = $true; use_annotation = $false
    } -ArtifactName '03-after-rdp-session'
    [void](Invoke-McpTool -Vm A -Tool Screenshot -Arguments @{
        display = @(0); use_annotation = $false
    } -ArtifactName '03-after-rdp-session')
    $selectedText = @($selectedViewer.Text) -join "`n"
    $rdpSessionSelected = $selectedText -match [regex]::Escape($peerId) -and
        $selectedText -notmatch 'Console'
    if (-not $rdpSessionSelected) { throw 'Viewer did not switch to the active RDP session on VM A.' }

    [void](Invoke-McpTool -Vm B -Tool App -Arguments @{
        mode = 'switch'; name = $viewerName
    } -ArtifactName '04-refocus-viewer')
    [void](Invoke-McpTool -Vm B -Tool Click -Arguments @{
        loc = @(400, 300); button = 'left'; clicks = 1
    } -ArtifactName '04-focus-remote-edit')
    [void](Invoke-McpTool -Vm B -Tool Wait -Arguments @{ duration = 1 } `
        -ArtifactName '04-wait-focus')
    $focused = Invoke-McpTool -Vm A -Tool Snapshot -Arguments @{
        display = @(0); use_vision = $true; use_annotation = $false
    } -ArtifactName '04-before-input'
    [void](Invoke-McpTool -Vm B -Tool Screenshot -Arguments @{
        display = @(0); use_annotation = $false
    } -ArtifactName '04-before-input')
    $focusText = @($focused.Text) -join "`n"
    $foreground = Invoke-GuestKeyboardState -Config $config -Vm A -PeerId $peerId `
        -ArtifactName '04-foreground-after-remote-click' -Action Foreground
    $mouseFocusProven = $focusText -match '\[focused\]' -and
        [string]$foreground.Window.ProcessName -eq 'notepad'
    if (-not $mouseFocusProven) { throw 'Remote Notepad edit did not receive mouse focus.' }

    [void](Invoke-McpTool -Vm B -Tool Type -Arguments @{
        loc = @(400, 300); text = $expected; clear = $true
        press_enter = $false; caret_position = 'idle'
    } -ArtifactName '05-type-from-controller')
    [void](Invoke-McpTool -Vm A -Tool WaitFor -Arguments @{
        condition = 'text_exists'; text = $expected; timeout = 10; interval = 0.5
    } -ArtifactName '05-wait-target-text')
    [void](Invoke-McpTool -Vm A -Tool Screenshot -Arguments @{
        display = @(0); use_annotation = $false
    } -ArtifactName '05-after-input')
    [void](Invoke-McpTool -Vm B -Tool Screenshot -Arguments @{
        display = @(0); use_annotation = $false
    } -ArtifactName '05-after-input')
    $verified = Invoke-McpTool -Vm A -Tool Snapshot -Arguments @{
        display = @(0); use_vision = $true; use_annotation = $false
    } -ArtifactName '06-after-verification'
    [void](Invoke-McpTool -Vm B -Tool Snapshot -Arguments @{
        display = @(0); use_vision = $true; use_annotation = $false
    } -ArtifactName '06-after-verification')
    $verifiedText = @($verified.Text) -join "`n"
    $readTarget = Invoke-GuestKeyboardState -Config $config -Vm A -PeerId $peerId `
        -ArtifactName '06-read-target' -Action ReadTarget
    $exactTargetText = [string]$readTarget.Text -ceq $expected -and
        $verifiedText.Contains("[value:`"$expected`"]")
    if (-not $exactTargetText) { throw 'Target Notepad value did not exactly match the probe.' }

    [void](Invoke-McpTool -Vm A -Tool Screenshot -Arguments @{
        display = @(0); use_annotation = $false
    } -ArtifactName '07-layout-before')
    [void](Invoke-McpTool -Vm B -Tool Screenshot -Arguments @{
        display = @(0); use_annotation = $false
    } -ArtifactName '07-layout-before')
    $layoutBeforeA = Invoke-GuestKeyboardState -Config $config -Vm A -PeerId $peerId `
        -ArtifactName '07-layout-before-state'
    $layoutBeforeB = Invoke-GuestKeyboardState -Config $config -Vm B -PeerId $peerId `
        -ArtifactName '07-layout-before-state'

    [void](Invoke-McpTool -Vm B -Tool App -Arguments @{
        mode = 'switch'; name = $viewerName
    } -ArtifactName '07-focus-viewer-before-layout')
    [void](Invoke-McpTool -Vm B -Tool Click -Arguments @{
        loc = @(400, 300); button = 'left'; clicks = 1
    } -ArtifactName '07-focus-remote-edit-before-layout')
    [void](Invoke-McpTool -Vm B -Tool Shortcut -Arguments @{ shortcut = 'alt+shift' } `
        -ArtifactName '07-layout-alt-shift')
    [void](Invoke-McpTool -Vm B -Tool Wait -Arguments @{ duration = 1 } `
        -ArtifactName '07-wait-layout')
    [void](Invoke-McpTool -Vm A -Tool Snapshot -Arguments @{
        display = @(0); use_vision = $true; use_annotation = $false
    } -ArtifactName '07-layout-ru')
    [void](Invoke-McpTool -Vm B -Tool Snapshot -Arguments @{
        display = @(0); use_vision = $true; use_annotation = $false
    } -ArtifactName '07-layout-ru')
    $layoutA = Invoke-GuestKeyboardState -Config $config -Vm A -PeerId $peerId `
        -ArtifactName '07-layout-after-state'
    $layoutB = Invoke-GuestKeyboardState -Config $config -Vm B -PeerId $peerId `
        -ArtifactName '07-layout-after-state'
    $layoutRemotePassed = [string]$layoutBeforeA.Klid -eq '04090409' -and
        [string]$layoutBeforeB.Klid -eq '04090409' -and
        [string]$layoutA.Klid -eq '04190419' -and
        [string]$layoutB.Klid -eq '04190419'
    if (-not $layoutRemotePassed) {
        throw 'Alt+Shift in the Viewer did not synchronize both Windows desktops to Russian.'
    }

    [void](Invoke-McpTool -Vm B -Tool App -Arguments @{
        mode = 'switch'; name = $viewerName
    } -ArtifactName '07-focus-viewer-before-restore')
    [void](Invoke-McpTool -Vm B -Tool Click -Arguments @{
        loc = @(400, 300); button = 'left'; clicks = 1
    } -ArtifactName '07-focus-remote-edit-before-restore')
    [void](Invoke-McpTool -Vm B -Tool Shortcut -Arguments @{ shortcut = 'alt+shift' } `
        -ArtifactName '07-layout-restore-alt-shift')
    [void](Invoke-McpTool -Vm B -Tool Wait -Arguments @{ duration = 1 } `
        -ArtifactName '07-wait-layout-restore')
    [void](Invoke-McpTool -Vm A -Tool Screenshot -Arguments @{
        display = @(0); use_annotation = $false
    } -ArtifactName '07-layout-restored')
    [void](Invoke-McpTool -Vm B -Tool Screenshot -Arguments @{
        display = @(0); use_annotation = $false
    } -ArtifactName '07-layout-restored')
    $layoutRestoredA = Invoke-GuestKeyboardState -Config $config -Vm A -PeerId $peerId `
        -ArtifactName '07-layout-restored-state'
    $layoutRestoredB = Invoke-GuestKeyboardState -Config $config -Vm B -PeerId $peerId `
        -ArtifactName '07-layout-restored-state'
    $layoutRestorePassed = [string]$layoutRestoredA.Klid -eq '04090409' -and
        [string]$layoutRestoredB.Klid -eq '04090409'
    if (-not $layoutRestorePassed) { throw 'Second Alt+Shift did not restore both layouts.' }

    [void](Invoke-McpTool -Vm A -Tool Process -Arguments @{
        mode = 'list'; name = 'masterdesk'; limit = 20; sort_by = 'name'
    } -ArtifactName '08-final-processes')
    [void](Invoke-McpTool -Vm B -Tool Process -Arguments @{
        mode = 'list'; name = 'masterdesk'; limit = 20; sort_by = 'name'
    } -ArtifactName '08-final-processes')
    Save-GuestRuntimeState -Config $config -Vm A -ArtifactName '09-runtime-after'
    Save-GuestRuntimeState -Config $config -Vm B -ArtifactName '09-runtime-after'

    $runtimeAfterA = Get-Content -LiteralPath (
        Join-Path $OutputDirectory '09-runtime-after-A.json') -Raw | ConvertFrom-Json
    $runtimeAfterB = Get-Content -LiteralPath (
        Join-Path $OutputDirectory '09-runtime-after-B.json') -Raw | ConvertFrom-Json
    $hungProcesses = @($runtimeAfterA.Processes + $runtimeAfterB.Processes | Where-Object {
        -not [bool]$_.Responding
    })
    if ($hungProcesses.Count -gt 0) { throw 'A non-responsive MasterDesk process remained after input.' }

    [ordered]@{
        Classification = 'PASS'
        CompletedUtc = [DateTime]::UtcNow.ToString('o')
        Candidate = Split-Path -Leaf $candidate
        CandidateSha256 = (Get-FileHash -LiteralPath $candidate -Algorithm SHA256).Hash
        Controller = 'VM10-B'
        Target = 'VM10-A'
        InputPath = 'Windows-MCP B -> MasterDesk Viewer -> RDP session A -> Notepad'
        Expected = $expected
        ExactTargetText = $exactTargetText
        MouseFocusProven = $mouseFocusProven
        ConnectionStable = $true
        RdpSessionSelected = $rdpSessionSelected
        NonResponsiveProcesses = $hungProcesses.Count
        McpAUsedForTextInput = $false
        RemoteLayoutAltShift = [ordered]@{
            Passed = $layoutRemotePassed -and $layoutRestorePassed
            BeforeTarget = [string]$layoutBeforeA.Klid
            BeforeController = [string]$layoutBeforeB.Klid
            AfterTarget = [string]$layoutA.Klid
            AfterController = [string]$layoutB.Klid
            RestoredTarget = [string]$layoutRestoredA.Klid
            RestoredController = [string]$layoutRestoredB.Klid
        }
    } | ConvertTo-Json -Depth 7 | Set-Content -LiteralPath (
        Join-Path $OutputDirectory 'result.json'
    ) -Encoding UTF8
    Write-Output "PASS scenario=InputTest controller=B target=A exactText=True mouse=True remoteLayout=True artifacts=$OutputDirectory"
    exit 0
} catch {
    $message = ConvertTo-SafeText $_.Exception.Message
    $classification = if ($infrastructureReady -and
            ($connectionEstablished -or $authorizationAttemptReached)) {
        'FAIL'
    } else { 'INCONCLUSIVE' }
    [ordered]@{
        Classification = $classification
        CompletedUtc = [DateTime]::UtcNow.ToString('o')
        InfrastructureReady = $infrastructureReady
        ConnectionEstablished = $connectionEstablished
        AuthorizationAttemptReached = $authorizationAttemptReached
        AuthorizationMode = $AuthorizationMode
        Expected = $expected
        Error = $message
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (
        Join-Path $OutputDirectory 'result.json'
    ) -Encoding UTF8
    $scenarioName = if ($AuthorizationMode -eq 'TemporaryPassword') {
        'PasswordTest'
    } else { 'InputTest' }
    Write-Output "$classification scenario=$scenarioName error=$message artifacts=$OutputDirectory"
    if ($classification -eq 'INCONCLUSIVE') { exit 2 }
    exit 1
} finally {
    $guestPassword = $null
}
