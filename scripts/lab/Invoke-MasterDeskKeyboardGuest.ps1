[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Prepare', 'CloseMain', 'StartTarget', 'Connect', 'StopController', 'Accept', 'SelectRdpSession', 'SetLayout', 'Focus', 'Toggle', 'TypeProbe', 'ReadTarget', 'State', 'Session', 'Foreground', 'PeerConfig', 'Runtime', 'Identity', 'LayoutApi', 'InstallDiagnosticDll', 'Trace', 'ReconnectTrace')]
    [string]$Action,
    [Parameter(Mandatory)]
    [string]$OutputPath,
    [ValidateSet('Controller', 'Target')]
    [string]$Role = 'Controller',
    [string]$PeerId,
    [string]$ExpectedRunnerSha256,
    [string]$ExpectedDllSha256,
    [string]$PayloadPath,
    [ValidateSet('00000409', '00000419')]
    [string]$Layout = '00000409',
    [ValidateRange(1, 10)]
    [int]$Cycles = 3,
    [switch]$InstallOrUpgrade
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public static class MasterDeskLabInput {
    public sealed class SessionInfo {
        public int SessionId { get; set; }
        public string StationName { get; set; }
        public string State { get; set; }
    }
    private enum WtsConnectState {
        Active, Connected, ConnectQuery, Shadow, Disconnected, Idle, Listen, Reset, Down, Init
    }
    [StructLayout(LayoutKind.Sequential)] private struct WtsSessionInfo {
        public int SessionId;
        public IntPtr StationName;
        public WtsConnectState State;
    }
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
    public delegate bool EnumWindowsProc(IntPtr hwnd, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc callback, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hwnd);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr hwnd, StringBuilder text, int count);
    [DllImport("user32.dll")] public static extern int GetWindowTextLength(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint processId);
    [DllImport("user32.dll")] public static extern IntPtr GetKeyboardLayout(uint threadId);
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)] public static extern IntPtr LoadKeyboardLayout(string id, uint flags);
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr hwnd, uint message, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool ShowWindowAsync(IntPtr hwnd, int command);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern IntPtr SetFocus(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint first, uint second, bool attach);
    [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hwnd, IntPtr insertAfter, int x, int y, int width, int height, uint flags);
    [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int key);
    [DllImport("user32.dll")] public static extern void keybd_event(byte key, byte scan, uint flags, UIntPtr extraInfo);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hwnd, out RECT rect);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern bool ScreenToClient(IntPtr hwnd, ref POINT point);
    [DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extraInfo);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string className, string title);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr SendMessage(IntPtr hwnd, uint message, IntPtr wParam, StringBuilder text);
    [DllImport("wtsapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern bool WTSEnumerateSessions(IntPtr server, int reserved, int version, out IntPtr sessions, out int count);
    [DllImport("wtsapi32.dll")] private static extern void WTSFreeMemory(IntPtr memory);

    public static SessionInfo[] GetSessions() {
        IntPtr buffer = IntPtr.Zero;
        int count = 0;
        var result = new List<SessionInfo>();
        if (!WTSEnumerateSessions(IntPtr.Zero, 0, 1, out buffer, out count)) {
            throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        }
        try {
            int size = Marshal.SizeOf(typeof(WtsSessionInfo));
            for (int index = 0; index < count; index++) {
                IntPtr current = IntPtr.Add(buffer, index * size);
                var item = (WtsSessionInfo)Marshal.PtrToStructure(current, typeof(WtsSessionInfo));
                result.Add(new SessionInfo {
                    SessionId = item.SessionId,
                    StationName = Marshal.PtrToStringUni(item.StationName) ?? string.Empty,
                    State = item.State.ToString()
                });
            }
        } finally {
            WTSFreeMemory(buffer);
        }
        return result.ToArray();
    }
}
'@

function Save-Result([hashtable]$Value) {
    $directory = Split-Path -Parent $OutputPath
    if ($directory) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
    $Value | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $OutputPath -Encoding UTF8
}

function Get-InstalledPath {
    $pathName = [string](Get-ItemPropertyValue `
        -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Services\MasterDesk' `
        -Name ImagePath -ErrorAction Stop)
    if ($pathName -match '^\s*"([^"]+)"') { return $matches[1] }
    if ($pathName -match '^\s*(\S+)') { return $matches[1] }
    throw 'Cannot parse MasterDesk service path.'
}

function Invoke-ClientCli([string]$Executable, [string[]]$Arguments, [string]$Prefix) {
    $stdout = "C:\MasterDeskLab\keyboard-$Prefix.stdout.txt"
    $stderr = "C:\MasterDeskLab\keyboard-$Prefix.stderr.txt"
    Remove-Item -LiteralPath $stdout, $stderr -Force -ErrorAction SilentlyContinue
    $process = Start-Process -FilePath $Executable -ArgumentList $Arguments -PassThru `
        -RedirectStandardOutput $stdout -RedirectStandardError $stderr -ErrorAction Stop
    if (-not $process.WaitForExit(30000)) {
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        throw "MasterDesk CLI timeout: $Prefix"
    }
    $output = @()
    if (Test-Path -LiteralPath $stdout) { $output += @(Get-Content -LiteralPath $stdout) }
    if (Test-Path -LiteralPath $stderr) { $output += @(Get-Content -LiteralPath $stderr) }
    if ($null -ne $process.ExitCode -and [int]$process.ExitCode -ne 0) {
        throw "MasterDesk CLI failed: $Prefix exit=$($process.ExitCode)"
    }
    return ($output -join "`n").Trim()
}

function Get-WindowInventory {
    $items = New-Object System.Collections.Generic.List[object]
    $callback = [MasterDeskLabInput+EnumWindowsProc]{
        param([IntPtr]$hwnd, [IntPtr]$unused)
        if (-not [MasterDeskLabInput]::IsWindowVisible($hwnd)) { return $true }
        $pidValue = [uint32]0
        [void][MasterDeskLabInput]::GetWindowThreadProcessId($hwnd, [ref]$pidValue)
        try { $process = Get-Process -Id ([int]$pidValue) -ErrorAction Stop } catch { return $true }
        if ($process.ProcessName -notin @('MasterDesk', 'rustdesk', 'notepad')) { return $true }
        $length = [MasterDeskLabInput]::GetWindowTextLength($hwnd)
        $builder = New-Object System.Text.StringBuilder ([Math]::Max(2, $length + 1))
        [void][MasterDeskLabInput]::GetWindowText($hwnd, $builder, $builder.Capacity)
        $threadId = [MasterDeskLabInput]::GetWindowThreadProcessId($hwnd, [ref]$pidValue)
        $layoutValue = [uint32]([MasterDeskLabInput]::GetKeyboardLayout($threadId).ToInt64() -band 0xffffffffL)
        $languageId = [uint16]($layoutValue -band 0xffff)
        $rect = New-Object MasterDeskLabInput+RECT
        [void][MasterDeskLabInput]::GetWindowRect($hwnd, [ref]$rect)
        $items.Add([pscustomobject]@{
            Handle = $hwnd.ToInt64(); ProcessId = [int]$pidValue
            ProcessName = [string]$process.ProcessName; Title = $builder.ToString()
            Hkl = ('{0:X8}' -f $layoutValue)
            # Keep Klid backward-compatible with existing lab artifacts and
            # comparisons; CanonicalKlid is the value accepted by KLID APIs.
            Klid = ('{0:X8}' -f $layoutValue)
            CanonicalKlid = ('{0:X8}' -f $languageId)
            Left = $rect.Left; Top = $rect.Top
            Width = $rect.Right - $rect.Left; Height = $rect.Bottom - $rect.Top
        })
        return $true
    }
    [void][MasterDeskLabInput]::EnumWindows($callback, [IntPtr]::Zero)
    return [object[]]$items.ToArray()
}

function Get-RoleWindow([string]$WindowRole, [string]$Id) {
    $deadline = [DateTime]::UtcNow.AddSeconds(45)
    do {
        $windows = @(Get-WindowInventory)
        if ($WindowRole -eq 'Target') {
            $selected = $windows | Where-Object ProcessName -eq 'notepad' | Select-Object -First 1
        } else {
            $selected = $windows | Where-Object {
                $_.ProcessName -in @('MasterDesk', 'rustdesk') -and
                $Id -and $_.Title -like "*$Id*"
            } | Select-Object -First 1
            if ($null -eq $selected) {
                $connectionPids = @(Get-CimInstance Win32_Process |
                    Where-Object { $_.Name -in @('MasterDesk.exe', 'rustdesk.exe') } |
                    Where-Object { [string]$_.CommandLine -match '(?i)--connect' } |
                    Select-Object -ExpandProperty ProcessId)
                $selected = $windows | Where-Object {
                    $_.ProcessName -in @('MasterDesk', 'rustdesk') -and
                    $connectionPids -contains $_.ProcessId
                } | Select-Object -First 1
            }
        }
        if ($null -ne $selected) { return $selected }
        Start-Sleep -Milliseconds 500
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "No $WindowRole test window appeared."
}

function Get-WindowLayout([object]$Window) {
    $pidValue = [uint32]0
    $threadId = [MasterDeskLabInput]::GetWindowThreadProcessId([IntPtr]([long]$Window.Handle), [ref]$pidValue)
    $value = [uint32]([MasterDeskLabInput]::GetKeyboardLayout($threadId).ToInt64() -band 0xffffffffL)
    return ('{0:X8}' -f $value)
}

function Set-ActiveWindow([object]$Window) {
    $handle = [IntPtr]([long]$Window.Handle)
    $pidValue = [uint32]0
    $targetThread = [MasterDeskLabInput]::GetWindowThreadProcessId($handle, [ref]$pidValue)
    $currentThread = [MasterDeskLabInput]::GetCurrentThreadId()
    $foregroundPid = [uint32]0
    $foregroundThread = [MasterDeskLabInput]::GetWindowThreadProcessId(
        [MasterDeskLabInput]::GetForegroundWindow(), [ref]$foregroundPid)
    $attachedTarget = $false
    $attachedForeground = $false
    if ($targetThread -ne $currentThread) {
        $attachedTarget = [MasterDeskLabInput]::AttachThreadInput($currentThread, $targetThread, $true)
    }
    if ($foregroundThread -ne 0 -and $foregroundThread -ne $currentThread -and $foregroundThread -ne $targetThread) {
        $attachedForeground = [MasterDeskLabInput]::AttachThreadInput($currentThread, $foregroundThread, $true)
    }
    try {
        [void][MasterDeskLabInput]::ShowWindowAsync($handle, 9)
        [void][MasterDeskLabInput]::BringWindowToTop($handle)
        [void][MasterDeskLabInput]::SetForegroundWindow($handle)
        [void][MasterDeskLabInput]::SetFocus($handle)
    } finally {
        if ($attachedForeground) { [void][MasterDeskLabInput]::AttachThreadInput($currentThread, $foregroundThread, $false) }
        if ($attachedTarget) { [void][MasterDeskLabInput]::AttachThreadInput($currentThread, $targetThread, $false) }
    }
    Start-Sleep -Milliseconds 350
    if ([MasterDeskLabInput]::GetForegroundWindow() -ne $handle) {
        [MasterDeskLabInput]::keybd_event(0x12, 0, 0, [UIntPtr]::Zero)
        Start-Sleep -Milliseconds 50
        [MasterDeskLabInput]::keybd_event(0x12, 0, 2, [UIntPtr]::Zero)
        [void][MasterDeskLabInput]::ShowWindowAsync($handle, 9)
        [void][MasterDeskLabInput]::BringWindowToTop($handle)
        [void][MasterDeskLabInput]::SetForegroundWindow($handle)
        Start-Sleep -Milliseconds 350
    }
    if ([MasterDeskLabInput]::GetForegroundWindow() -ne $handle) {
        $noMoveNoSizeShow = [uint32](0x0001 -bor 0x0002 -bor 0x0040)
        [void][MasterDeskLabInput]::SetWindowPos($handle, [IntPtr](-1), 0, 0, 0, 0, $noMoveNoSizeShow)
        [void][MasterDeskLabInput]::SetWindowPos($handle, [IntPtr](-2), 0, 0, 0, 0, $noMoveNoSizeShow)
        $rect = New-Object MasterDeskLabInput+RECT
        if ([MasterDeskLabInput]::GetWindowRect($handle, [ref]$rect)) {
            $x = [int]($rect.Left + (($rect.Right - $rect.Left) / 2))
            $y = [int]($rect.Top + [Math]::Min(18, [Math]::Max(4, $rect.Bottom - $rect.Top - 4)))
            [void][MasterDeskLabInput]::SetCursorPos($x, $y)
            [MasterDeskLabInput]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
            Start-Sleep -Milliseconds 80
            [MasterDeskLabInput]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
        }
        [void][MasterDeskLabInput]::SetForegroundWindow($handle)
        Start-Sleep -Milliseconds 350
    }
    if ([MasterDeskLabInput]::GetForegroundWindow() -ne $handle) {
        throw "Failed to foreground test window handle=$($Window.Handle)."
    }
}

function Set-WindowLayout([object]$Window, [string]$Klid) {
    $hkl = [MasterDeskLabInput]::LoadKeyboardLayout($Klid, 1)
    if ($hkl -eq [IntPtr]::Zero) { throw "LoadKeyboardLayout failed for $Klid." }
    Set-ActiveWindow $Window
    if (-not [MasterDeskLabInput]::PostMessage([IntPtr]([long]$Window.Handle), 0x0050, [IntPtr]::Zero, $hkl)) {
        throw "WM_INPUTLANGCHANGEREQUEST failed for $Klid."
    }
    Start-Sleep -Seconds 1
    return Get-WindowLayout $Window
}

function Send-AltShift {
    [MasterDeskLabInput]::keybd_event(0x12, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 60
    [MasterDeskLabInput]::keybd_event(0x10, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 120
    [MasterDeskLabInput]::keybd_event(0x10, 0, 2, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 60
    [MasterDeskLabInput]::keybd_event(0x12, 0, 2, [UIntPtr]::Zero)
}

function Get-ModifierState {
    return [ordered]@{
        Alt = ([MasterDeskLabInput]::GetAsyncKeyState(0x12) -band 0x8000) -ne 0
        Shift = ([MasterDeskLabInput]::GetAsyncKeyState(0x10) -band 0x8000) -ne 0
        LeftShift = ([MasterDeskLabInput]::GetAsyncKeyState(0xA0) -band 0x8000) -ne 0
        RightShift = ([MasterDeskLabInput]::GetAsyncKeyState(0xA1) -band 0x8000) -ne 0
    }
}

try {
    $result = [ordered]@{ Passed = $false; Action = $Action; Role = $Role; TimestampUtc = [DateTime]::UtcNow.ToString('o') }
    switch ($Action) {
        'Prepare' {
            if ($InstallOrUpgrade) {
                $needsInstall = $true
                try {
                    $current = Get-InstalledPath
                    $currentDll = Join-Path (Split-Path -Parent $current) 'libmasterdesk.dll'
                    $needsInstall = (Get-FileHash $current -Algorithm SHA256).Hash -ne $ExpectedRunnerSha256 -or
                        (Get-FileHash $currentDll -Algorithm SHA256).Hash -ne $ExpectedDllSha256
                } catch { $needsInstall = $true }
                if ($needsInstall) {
                    $candidate = (Get-Content -LiteralPath 'C:\MasterDeskLab\candidate-path.txt' -Raw).Trim()
                    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { throw 'Candidate is missing.' }
                    Start-Process -FilePath $candidate -ArgumentList '--silent-install' | Out-Null
                    $deadline = [DateTime]::UtcNow.AddSeconds(180)
                    do {
                        Start-Sleep -Seconds 3
                        $service = Get-CimInstance Win32_Service -Filter "Name='MasterDesk'" -ErrorAction SilentlyContinue
                        $silent = @(Get-CimInstance Win32_Process | Where-Object { [string]$_.CommandLine -match '(?i)--silent-install' })
                        if ($null -ne $service -and $service.State -eq 'Running' -and $silent.Count -eq 0) { break }
                    } while ([DateTime]::UtcNow -lt $deadline)
                }
            }
            $installed = Get-InstalledPath
            $dll = Join-Path (Split-Path -Parent $installed) 'libmasterdesk.dll'
            $runnerHash = (Get-FileHash -LiteralPath $installed -Algorithm SHA256).Hash
            $dllHash = (Get-FileHash -LiteralPath $dll -Algorithm SHA256).Hash
            if ($runnerHash -ne $ExpectedRunnerSha256) { throw 'Installed runner SHA256 mismatch.' }
            if ($dllHash -ne $ExpectedDllSha256) { throw 'Installed libmasterdesk.dll SHA256 mismatch.' }
            [void](Invoke-ClientCli $installed @('--option','allow-websocket','N') 'disable-wss')
            $id = Invoke-ClientCli $installed @('--get-id') 'get-id'
            if (-not $id) { throw 'MasterDesk ID is empty.' }
            # An installed machine already has interactive background descendants
            # (for example --server). Their presence does not mean that the main
            # GUI, which owns temporary-password availability, is open. A no-arg
            # installed launch is single-instance safe and explicitly opens or
            # activates that GUI.
            Start-Process -FilePath $installed | Out-Null
            Start-Sleep -Seconds 4
            $result.InstalledPath = $installed; $result.RunnerSha256 = $runnerHash
            $result.DllSha256 = $dllHash; $result.Id = $id; $result.WebSocket = 'N'
            $result.MainGuiLaunchRequested = $true
        }
        'CloseMain' {
            $mainWindows = @(Get-WindowInventory | Where-Object {
                $_.ProcessName -in @('MasterDesk', 'rustdesk') -and
                $_.Title -eq 'MasterDesk' -and $_.Width -ge 500 -and $_.Height -ge 400
            })
            $processIds = @($mainWindows | Select-Object -ExpandProperty ProcessId -Unique)
            foreach ($processId in $processIds) {
                Stop-Process -Id ([int]$processId) -Force -ErrorAction Stop
            }
            Start-Sleep -Seconds 2
            $result.ClosedProcessIds = $processIds
            $result.TrayProcessIds = @(Get-CimInstance Win32_Process -Filter "Name='MasterDesk.exe'" |
                Where-Object { [string]$_.CommandLine -match '(?i)\s--tray(?:\s|$)' } |
                Select-Object -ExpandProperty ProcessId)
            if ($result.TrayProcessIds.Count -eq 0) {
                throw 'Interactive MasterDesk tray was not running after the main GUI closed.'
            }
        }
        'StartTarget' {
            Get-Process notepad -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
            Get-Process OneDrive -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
            Start-Process notepad.exe | Out-Null
            $window = Get-RoleWindow Target ''
            $result.Window = $window; $result.Klid = Set-WindowLayout $window '00000409'
        }
        'Connect' {
            if (-not $PeerId) { throw 'PeerId is required.' }
            $installed = Get-InstalledPath
            Get-CimInstance Win32_Process -Filter "Name='MasterDesk.exe'" |
                Where-Object { [string]$_.CommandLine -match '(?i)--connect' } |
                ForEach-Object { Stop-Process -Id ([int]$_.ProcessId) -Force -ErrorAction SilentlyContinue }
            $connectArguments = @('--connect', $PeerId)
            Start-Process -FilePath $installed -ArgumentList $connectArguments | Out-Null
            $window = Get-RoleWindow Controller $PeerId
            Start-Sleep -Seconds 2
            $result.Window = $window; $result.Klid = Get-WindowLayout $window
        }
        'StopController' {
            $processes = @(Get-CimInstance Win32_Process -Filter "Name='MasterDesk.exe'" |
                Where-Object { [string]$_.CommandLine -match '(?i)--connect' })
            foreach ($process in $processes) {
                Stop-Process -Id ([int]$process.ProcessId) -Force -ErrorAction SilentlyContinue
            }
            Start-Sleep -Seconds 2
            $result.Stopped = @($processes | ForEach-Object { [int]$_.ProcessId })
        }
        'Accept' {
            Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
            $deadline = [DateTime]::UtcNow.AddSeconds(3)
            $seen = @()
            $clicked = $null
            $acceptRu = -join [char[]]@(0x041F,0x0440,0x0438,0x043D,0x044F,0x0442,0x044C)
            $allowRu = -join [char[]]@(0x0420,0x0430,0x0437,0x0440,0x0435,0x0448,0x0438,0x0442,0x044C)
            do {
                $elements = [System.Windows.Automation.AutomationElement]::RootElement.FindAll(
                    [System.Windows.Automation.TreeScope]::Descendants,
                    [System.Windows.Automation.Condition]::TrueCondition)
                foreach ($element in $elements) {
                    try {
                        if ($element.Current.ControlType -ne [System.Windows.Automation.ControlType]::Button) { continue }
                        $pidValue = [int]$element.Current.ProcessId
                        $process = Get-Process -Id $pidValue -ErrorAction Stop
                        if ($process.ProcessName -ne 'MasterDesk') { continue }
                        $name = [string]$element.Current.Name
                        if ($name) { $seen += $name }
                        if ($name -in @($acceptRu, $allowRu) -or $name -match '(?i)Accept|Allow') {
                            $pattern = $element.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
                            ([System.Windows.Automation.InvokePattern]$pattern).Invoke()
                            $clicked = $name
                            break
                        }
                    } catch { continue }
                }
                if ($clicked) { break }
                Start-Sleep -Milliseconds 500
            } while ([DateTime]::UtcNow -lt $deadline -and $seen.Count -eq 0)
            if (-not $clicked) {
                $manager = @(Get-WindowInventory | Where-Object {
                    $_.ProcessName -eq 'MasterDesk' -and $_.Width -ge 180 -and $_.Width -le 500 -and
                    $_.Height -ge 250 -and $_.Height -le 700
                } | Sort-Object Width | Select-Object -First 1)
                if ($manager.Count -ne 1) {
                    # A remembered/trusted controller can already be authorized,
                    # so absence of an incoming request is not itself a failure.
                    # The caller verifies the Viewer and remote input next.
                    $result.Clicked = $null
                    $result.NoRequestFound = $true
                    $result.Buttons = @($seen | Select-Object -Unique)
                    break
                }
                $window = $manager[0]
                Set-ActiveWindow $window
                $x = [int]($window.Left + ($window.Width * 0.26))
                $y = [int]($window.Top + $window.Height - 32)
                if (-not [MasterDeskLabInput]::SetCursorPos($x, $y)) {
                    throw 'Failed to position the pointer over the Accept button.'
                }
                [MasterDeskLabInput]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
                Start-Sleep -Milliseconds 100
                [MasterDeskLabInput]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
                $clicked = 'foreground-mouse-fallback'
            }
            Start-Sleep -Seconds 8
            $result.Clicked = $clicked
            $result.Buttons = @($seen | Select-Object -Unique)
        }
        'SelectRdpSession' {
            $window = Get-RoleWindow Controller $PeerId
            Set-ActiveWindow $window
            $clickScreen = {
                param([int]$X, [int]$Y)
                if (-not [MasterDeskLabInput]::SetCursorPos($X, $Y)) {
                    throw "Failed to position the pointer at $X,$Y."
                }
                [MasterDeskLabInput]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
                Start-Sleep -Milliseconds 80
                [MasterDeskLabInput]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
            }
            # Installed lab machines expose Console plus the active RDP session.
            # Flutter semantics are not visible to UIAutomation from the vmrun
            # helper, so use stable positions relative to the maximized Viewer.
            & $clickScreen ([int]($window.Left + $window.Width * 0.50)) `
                ([int]($window.Top + $window.Height * 0.483))
            Start-Sleep -Milliseconds 500
            & $clickScreen ([int]($window.Left + $window.Width * 0.505)) `
                ([int]($window.Top + $window.Height * 0.603))
            Start-Sleep -Milliseconds 500
            & $clickScreen ([int]($window.Left + $window.Width * 0.642)) `
                ([int]($window.Top + $window.Height * 0.619))
            Start-Sleep -Seconds 5
            $result.Picker = 'multi-session'
            $result.Selected = 'active-rdp'
        }
        'SetLayout' {
            $window = Get-RoleWindow $Role $PeerId
            $result.Before = Get-WindowLayout $window
            $result.After = Set-WindowLayout $window $Layout
            $result.Window = $window
        }
        'Focus' {
            $window = Get-RoleWindow $Role $PeerId
            Set-ActiveWindow $window
            $result.Klid = Get-WindowLayout $window; $result.Window = $window
        }
        'Toggle' {
            $window = Get-RoleWindow $Role $PeerId
            Set-ActiveWindow $window
            $result.Before = Get-WindowLayout $window
            Send-AltShift
            Start-Sleep -Milliseconds 200
            $result.Immediate = Get-WindowLayout $window
            Start-Sleep -Seconds 3
            $result.After = Get-WindowLayout $window
            $result.Modifiers = Get-ModifierState; $result.Window = $window
        }
        'TypeProbe' {
            $window = Get-RoleWindow $Role $PeerId
            Set-ActiveWindow $window
            Add-Type -AssemblyName System.Windows.Forms
            [System.Windows.Forms.SendKeys]::SendWait('a')
            Start-Sleep -Seconds 2
            $result.Modifiers = Get-ModifierState; $result.Window = $window
        }
        'ReadTarget' {
            $window = Get-RoleWindow Target ''
            $edit = [MasterDeskLabInput]::FindWindowEx([IntPtr]([long]$window.Handle), [IntPtr]::Zero, 'Edit', $null)
            if ($edit -eq [IntPtr]::Zero) { throw 'Notepad Edit control was not found.' }
            $length = [MasterDeskLabInput]::SendMessage($edit, 0x000E, [IntPtr]::Zero, $null).ToInt32()
            $text = New-Object System.Text.StringBuilder ([Math]::Max(2, $length + 1))
            [void][MasterDeskLabInput]::SendMessage($edit, 0x000D, [IntPtr]$text.Capacity, $text)
            $result.Text = $text.ToString(); $result.Window = $window
        }
        'State' {
            $window = Get-RoleWindow $Role $PeerId
            $result.Klid = Get-WindowLayout $window
            $result.Modifiers = Get-ModifierState; $result.Window = $window
            $result.Windows = @(Get-WindowInventory)
        }
        'Foreground' {
            $handle = [MasterDeskLabInput]::GetForegroundWindow()
            $result.Handle = $handle.ToInt64()
            $result.Window = @(Get-WindowInventory | Where-Object {
                [long]$_.Handle -eq $handle.ToInt64()
            } | Select-Object -First 1)
            $result.Windows = @(Get-WindowInventory)
        }
        'PeerConfig' {
            $peerRoots = @(
                (Join-Path $env:APPDATA 'MasterDesk\config\peers'),
                (Join-Path $env:APPDATA 'RustDesk\config\peers')
            )
            $peerFiles = @($peerRoots | Where-Object { Test-Path -LiteralPath $_ } |
                ForEach-Object { Get-ChildItem -LiteralPath $_ -File -ErrorAction SilentlyContinue })
            if ($PeerId) {
                $compactId = $PeerId -replace '\s', ''
                $peerFiles = @($peerFiles | Where-Object {
                    $_.BaseName -eq $compactId -or $_.BaseName -eq $PeerId
                })
            }
            $result.Files = @($peerFiles | ForEach-Object {
                $safeLines = @(Get-Content -LiteralPath $_.FullName | Where-Object {
                    $_ -match '(?i)keyboard_mode|input-source|masterdesk-windows-map-mode'
                } | ForEach-Object { [string]$_ })
                [ordered]@{ Path = $_.FullName; Lines = $safeLines }
            })
            $configRoot = Join-Path $env:APPDATA 'MasterDesk\config'
            $result.LocalLines = if (Test-Path -LiteralPath $configRoot) {
                @(Get-ChildItem -LiteralPath $configRoot -File -Filter '*.toml' |
                    ForEach-Object {
                        Get-Content -LiteralPath $_.FullName | Where-Object {
                            $_ -match '(?i)input-source'
                        } | ForEach-Object { [string]$_ }
                    })
            } else { @() }
        }
        'LayoutApi' {
            $window = Get-RoleWindow $Role $PeerId
            Set-ActiveWindow $window
            $pidValue = [uint32]0
            $threadId = [MasterDeskLabInput]::GetWindowThreadProcessId(
                [IntPtr]([long]$window.Handle), [ref]$pidValue)
            $hklValue = [uint32]([MasterDeskLabInput]::GetKeyboardLayout($threadId).ToInt64() -band 0xffffffffL)
            $klid = '{0:X8}' -f [uint16]($hklValue -band 0xffff)
            $rawHklText = '{0:X8}' -f $hklValue
            $rawLoad = [MasterDeskLabInput]::LoadKeyboardLayout($rawHklText, 0)
            $rawLoadError = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
            $canonicalLoad = [MasterDeskLabInput]::LoadKeyboardLayout($klid, 0)
            $canonicalLoadError = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
            $result.Window = $window
            $result.ThreadId = $threadId
            $result.ObservedHkl = $rawHklText
            $result.CanonicalKlid = $klid
            $result.RawHklAcceptedAsKlid = $rawLoad -ne [IntPtr]::Zero
            $result.RawHklLoadError = $rawLoadError
            $result.CanonicalKlidAccepted = $canonicalLoad -ne [IntPtr]::Zero
            $result.CanonicalKlidLoadError = $canonicalLoadError
        }
        'Session' {
            $sessionLines = @(query.exe session 2>&1 | ForEach-Object { [string]$_ })
            $rdpLines = @($sessionLines | Where-Object { $_ -match '(?i)rdp-tcp#' })
            $processSessionId = (Get-Process -Id $PID).SessionId
            $wtsSessions = @([MasterDeskLabInput]::GetSessions())
            $activeRdpSessions = @($wtsSessions | Where-Object {
                $_.StationName -like 'rdp-tcp#*' -and $_.State -eq 'Active'
            })
            $activeRdp = $activeRdpSessions.Count -gt 0
            $result.ComputerName = $env:COMPUTERNAME
            $result.ProcessSessionId = $processSessionId
            $result.ActiveRdp = $activeRdp
            $result.ActiveRdpSessionIds = @($activeRdpSessions | ForEach-Object { $_.SessionId })
            $result.WtsSessions = $wtsSessions
            $result.RdpSessions = $rdpLines
            $result.Sessions = $sessionLines
            try {
                $operatingSystem = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
                $result.LastBootUpTimeUtc = $operatingSystem.LastBootUpTime.ToUniversalTime().ToString('o')
            } catch {
                $result.LastBootUpTimeUtc = $null
            }
            try {
                $result.PowerEvents = @(Get-WinEvent -FilterHashtable @{
                    LogName = 'System'; Id = @(41, 1074, 6005, 6006, 6008)
                    StartTime = (Get-Date).AddHours(-2)
                } -ErrorAction Stop | Select-Object -First 12 |
                    ForEach-Object {
                        [ordered]@{
                            Id = $_.Id
                            TimeCreatedUtc = $_.TimeCreated.ToUniversalTime().ToString('o')
                            Provider = $_.ProviderName
                            Message = [string]$_.Message
                        }
                    })
            } catch {
                $result.PowerEvents = @()
            }
        }
        'Runtime' {
            $service = Get-CimInstance Win32_Service -Filter "Name='MasterDesk'" `
                -ErrorAction SilentlyContinue
            $result.Service = if ($null -eq $service) { $null } else {
                [ordered]@{
                    State = [string]$service.State
                    ProcessId = [int]$service.ProcessId
                    PathName = [string]$service.PathName
                    StartMode = [string]$service.StartMode
                }
            }
            $result.Processes = @(Get-CimInstance Win32_Process |
                Where-Object { $_.Name -in @('MasterDesk.exe', 'rustdesk.exe') } |
                ForEach-Object {
                    $owner = Invoke-CimMethod -InputObject $_ -MethodName GetOwner `
                        -ErrorAction SilentlyContinue
                    [ordered]@{
                        ProcessId = [int]$_.ProcessId
                        ParentProcessId = [int]$_.ParentProcessId
                        SessionId = [int]$_.SessionId
                        CommandLine = [string]$_.CommandLine
                        Owner = if ($null -eq $owner) { $null } else { [string]$owner.User }
                    }
                })
            $result.Windows = @(Get-WindowInventory)
            $result.Sessions = @(query.exe session 2>&1 | ForEach-Object { [string]$_ })
            $result.TotalCommander = @(
                'C:\totalcmd\TOTALCMD64.EXE',
                'C:\totalcmd\TOTALCMD.EXE',
                'C:\Program Files\totalcmd\TOTALCMD64.EXE',
                'C:\Program Files (x86)\totalcmd\TOTALCMD.EXE'
            ) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf }
            # A recursive scan from C:\ can take minutes and leave the Runtime
            # probe looking hung. TestDisk distributions normally live in a
            # top-level testdisk* directory or in the lab user's Downloads.
            $testDiskRoots = @(
                'C:\MasterDeskLab',
                (Join-Path $env:USERPROFILE 'Downloads')
            ) + @(Get-ChildItem -LiteralPath 'C:\' -Directory -Filter 'testdisk*' `
                -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName)
            $result.TestDisk = @($testDiskRoots |
                Where-Object { Test-Path -LiteralPath $_ -PathType Container } |
                ForEach-Object {
                    Get-ChildItem -LiteralPath $_ -Filter 'testdisk*.exe' -File -Recurse `
                        -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName
                } | Select-Object -Unique)
            $logFiles = foreach ($logRoot in @(
                'C:\Windows\ServiceProfiles\LocalService\AppData\Roaming\MasterDesk\log',
                'C:\Windows\ServiceProfiles\LocalSystem\AppData\Roaming\MasterDesk\log',
                'C:\Users\MasterDeskTest\AppData\Roaming\MasterDesk\log'
            )) {
                if (-not [System.IO.Directory]::Exists($logRoot)) { continue }
                try {
                    Get-ChildItem -LiteralPath $logRoot -File -Recurse `
                        -ErrorAction SilentlyContinue
                } catch {
                    # Interactive lab probes can run without access to service
                    # profile logs. Runtime state remains useful without them.
                }
            }
            $result.Logs = @($logFiles |
                Sort-Object LastWriteTimeUtc -Descending |
                Select-Object -First 20 FullName, Length, LastWriteTimeUtc)
        }
        'Identity' {
            $installed = 'C:\Program Files\MasterDesk\MasterDesk.exe'
            if (-not (Test-Path -LiteralPath $installed -PathType Leaf)) {
                throw 'Installed MasterDesk executable was not found.'
            }
            $samples = @()
            $ids = @()
            for ($cycle = 0; $cycle -le $Cycles; $cycle++) {
                if ($cycle -gt 0) {
                    Restart-Service -Name MasterDesk -Force -ErrorAction Stop
                    (Get-Service -Name MasterDesk -ErrorAction Stop).WaitForStatus(
                        [System.ServiceProcess.ServiceControllerStatus]::Running,
                        [TimeSpan]::FromSeconds(30)
                    )
                    Start-Sleep -Seconds 3
                }
                $id = Invoke-ClientCli $installed @('--get-id') "identity-$cycle"
                if ($id -notmatch '^\d{6,}$') {
                    throw "MasterDesk returned an invalid ID after cycle ${cycle}: $id"
                }
                $ids += $id
                $service = Get-CimInstance Win32_Service -Filter "Name='MasterDesk'" `
                    -ErrorAction Stop
                $servers = @(Get-CimInstance Win32_Process -Filter "Name='MasterDesk.exe'" |
                    Where-Object { [string]$_.CommandLine -match '(?i)\s--server(?:\s|$)' })
                $samples += [pscustomobject][ordered]@{
                    Cycle = $cycle
                    TimestampUtc = [DateTime]::UtcNow.ToString('o')
                    Id = $id
                    ServiceState = [string]$service.State
                    ServiceProcessId = [int]$service.ProcessId
                    ServerProcessIds = @($servers | ForEach-Object { [int]$_.ProcessId })
                }
            }
            $uniqueIds = @($ids | Select-Object -Unique)
            if ($uniqueIds.Count -ne 1) {
                throw "MasterDesk ID changed across service restarts: $($uniqueIds -join ', ')"
            }
            $result.Id = $uniqueIds[0]
            $result.Cycles = $Cycles
            $result.Samples = $samples
        }
        'InstallDiagnosticDll' {
            if (-not (Test-Path -LiteralPath $PayloadPath -PathType Leaf)) {
                throw "Diagnostic DLL payload was not found: $PayloadPath"
            }
            if ($ExpectedDllSha256 -notmatch '^[A-Fa-f0-9]{64}$') {
                throw 'ExpectedDllSha256 must be a SHA256 value.'
            }
            $installed = Get-InstalledPath
            $installedDirectory = Split-Path -Parent $installed
            $installedDll = Join-Path $installedDirectory 'libmasterdesk.dll'
            if (-not (Test-Path -LiteralPath $installedDll -PathType Leaf)) {
                throw "Installed libmasterdesk.dll was not found: $installedDll"
            }
            $beforeHash = (Get-FileHash -LiteralPath $installedDll -Algorithm SHA256).Hash
            $backup = "C:\MasterDeskLab\libmasterdesk-before-diagnostic-$($beforeHash.Substring(0, 12)).dll"
            if (-not (Test-Path -LiteralPath $backup -PathType Leaf)) {
                Copy-Item -LiteralPath $installedDll -Destination $backup -Force
            }
            try {
                Stop-Service -Name MasterDesk -Force -ErrorAction Stop
                (Get-Service -Name MasterDesk -ErrorAction Stop).WaitForStatus(
                    [System.ServiceProcess.ServiceControllerStatus]::Stopped,
                    [TimeSpan]::FromSeconds(30)
                )
                Get-CimInstance Win32_Process -Filter "Name='MasterDesk.exe'" |
                    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
                $copied = $false
                for ($attempt = 1; $attempt -le 10 -and -not $copied; $attempt++) {
                    try {
                        Copy-Item -LiteralPath $PayloadPath -Destination $installedDll -Force `
                            -ErrorAction Stop
                        $copied = $true
                    } catch {
                        if ($attempt -eq 10) { throw }
                        Start-Sleep -Milliseconds 500
                    }
                }
                $afterHash = (Get-FileHash -LiteralPath $installedDll -Algorithm SHA256).Hash
                if ($afterHash -ne $ExpectedDllSha256.ToUpperInvariant()) {
                    throw "Diagnostic DLL hash mismatch: $afterHash"
                }
            } catch {
                Start-Service -Name MasterDesk -ErrorAction SilentlyContinue
                throw
            }
            Start-Service -Name MasterDesk -ErrorAction Stop
            (Get-Service -Name MasterDesk -ErrorAction Stop).WaitForStatus(
                [System.ServiceProcess.ServiceControllerStatus]::Running,
                [TimeSpan]::FromSeconds(30)
            )
            $service = Get-CimInstance Win32_Service -Filter "Name='MasterDesk'" -ErrorAction Stop
            $result.InstalledPath = $installed
            $result.InstalledDll = $installedDll
            $result.BackupPath = $backup
            $result.BeforeSha256 = $beforeHash
            $result.AfterSha256 = $afterHash
            $result.ServiceState = [string]$service.State
            $result.ServiceProcessId = [int]$service.ProcessId
        }
        'Trace' {
            $traceFiles = @(
                Get-ChildItem -Path @(
                    'C:\Windows\ServiceProfiles\LocalService\AppData\Roaming\MasterDesk\log',
                    'C:\Windows\ServiceProfiles\LocalSystem\AppData\Roaming\MasterDesk\log',
                    'C:\Users\MasterDeskTest\AppData\Roaming\MasterDesk\log'
                ) -File -Recurse -ErrorAction SilentlyContinue |
                    Sort-Object LastWriteTimeUtc -Descending |
                    Select-Object -First 20
            )
            $traceLines = @(
                $traceFiles | Select-String -Pattern 'MD_LAYOUT|MD_RECONNECT' -ErrorAction SilentlyContinue |
                    Select-Object -Last 500 |
                    ForEach-Object {
                        [ordered]@{
                            File = $_.Path
                            LineNumber = $_.LineNumber
                            Text = $_.Line.Trim()
                        }
                    }
            )
            $result.Files = @($traceFiles | ForEach-Object {
                [ordered]@{
                    FullName = $_.FullName
                    Length = $_.Length
                    LastWriteTimeUtc = $_.LastWriteTimeUtc.ToString('o')
                }
            })
            $result.TraceLines = $traceLines
        }
        'ReconnectTrace' {
            $installed = Get-InstalledPath
            $idBefore = Invoke-ClientCli $installed @('--get-id') 'reconnect-id-before'
            $traceRoots = @(
                'C:\Windows\ServiceProfiles\LocalService\AppData\Roaming\MasterDesk\log',
                'C:\Windows\ServiceProfiles\LocalSystem\AppData\Roaming\MasterDesk\log',
                'C:\Users\MasterDeskTest\AppData\Roaming\MasterDesk\log'
            )
            $oldServers = @(Get-CimInstance Win32_Process -Filter "Name='MasterDesk.exe'" |
                Where-Object { [string]$_.CommandLine -match '(?i)\s--server(?:\s|$)' })
            $knownT3 = @(
                Get-ChildItem -Path $traceRoots -File -Recurse -ErrorAction SilentlyContinue |
                    Select-String -Pattern 'MD_RECONNECT stage=T3-register-send' `
                        -ErrorAction SilentlyContinue |
                    ForEach-Object { "$($_.Path):$($_.LineNumber):$($_.Line)" }
            )
            $startedUtc = [DateTime]::UtcNow
            Stop-Service -Name MasterDesk -Force -ErrorAction Stop
            (Get-Service -Name MasterDesk -ErrorAction Stop).WaitForStatus(
                [System.ServiceProcess.ServiceControllerStatus]::Stopped,
                [TimeSpan]::FromSeconds(30)
            )
            foreach ($process in $oldServers) {
                try { Wait-Process -Id $process.ProcessId -Timeout 10 -ErrorAction Stop } catch {}
            }
            $t0 = [DateTime]::UtcNow
            Start-Service -Name MasterDesk -ErrorAction Stop
            (Get-Service -Name MasterDesk -ErrorAction Stop).WaitForStatus(
                [System.ServiceProcess.ServiceControllerStatus]::Running,
                [TimeSpan]::FromSeconds(30)
            )
            $t1 = [DateTime]::UtcNow
            $newServer = $null
            $serverDeadline = [DateTime]::UtcNow.AddSeconds(20)
            do {
                $newServer = @(Get-CimInstance Win32_Process -Filter "Name='MasterDesk.exe'" |
                    Where-Object { [string]$_.CommandLine -match '(?i)\s--server(?:\s|$)' } |
                    Where-Object { @($oldServers.ProcessId) -notcontains $_.ProcessId } |
                    Select-Object -First 1)
                if ($newServer) { break }
                Start-Sleep -Milliseconds 100
            } while ([DateTime]::UtcNow -lt $serverDeadline)
            if (-not $newServer) { throw 'New service-owned --server did not become ready.' }
            $t2 = [DateTime]::UtcNow
            $newT3 = $null
            $t3Deadline = [DateTime]::UtcNow.AddSeconds(20)
            do {
                $currentT3 = @(
                    Get-ChildItem -Path $traceRoots -File -Recurse -ErrorAction SilentlyContinue |
                        Select-String -Pattern 'MD_RECONNECT stage=T3-register-send' `
                            -ErrorAction SilentlyContinue |
                        ForEach-Object { "$($_.Path):$($_.LineNumber):$($_.Line)" }
                )
                $newT3 = @($currentT3 | Where-Object { $knownT3 -notcontains $_ } |
                    Select-Object -First 1)
                if ($newT3) { break }
                Start-Sleep -Milliseconds 100
            } while ([DateTime]::UtcNow -lt $t3Deadline)
            if (-not $newT3) { throw 'New --server did not emit its first T3 registration trace.' }
            $t3 = [DateTime]::UtcNow
            $idAfter = Invoke-ClientCli $installed @('--get-id') 'reconnect-id-after'
            if ($idAfter -ne $idBefore) { throw "ID changed: $idBefore -> $idAfter" }
            $result.Id = $idAfter
            $result.OldServerProcessIds = @($oldServers | ForEach-Object { [int]$_.ProcessId })
            $result.NewServerProcessId = [int]$newServer.ProcessId
            $result.T0OldServerStoppedUtc = $t0.ToString('o')
            $result.T1ServiceRunningUtc = $t1.ToString('o')
            $result.T2NewServerReadyUtc = $t2.ToString('o')
            $result.T3FirstRegistrationObservedUtc = $t3.ToString('o')
            $result.T3Trace = [string]$newT3[0]
            $result.DeltaT0T1Ms = [math]::Round(($t1 - $t0).TotalMilliseconds, 1)
            $result.DeltaT1T2Ms = [math]::Round(($t2 - $t1).TotalMilliseconds, 1)
            $result.DeltaT2T3Ms = [math]::Round(($t3 - $t2).TotalMilliseconds, 1)
            $result.TotalMs = [math]::Round(($t3 - $startedUtc).TotalMilliseconds, 1)
        }
    }
    $result.Passed = $true
    Save-Result $result
    exit 0
} catch {
    Save-Result ([ordered]@{
        Passed=$false; Action=$Action; Role=$Role
        TimestampUtc=[DateTime]::UtcNow.ToString('o')
        Error=$_.Exception.Message; Position=$_.InvocationInfo.PositionMessage
    })
    exit 1
}
