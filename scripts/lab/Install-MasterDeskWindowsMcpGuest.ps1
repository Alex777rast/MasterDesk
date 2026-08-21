[CmdletBinding()]
param(
    [ValidateSet('Probe', 'Install', 'Restart', 'ClearTokenExport')]
    [string]$Action = 'Probe',

    [string]$OutputPath = 'C:\MasterDeskLab\windows-mcp-result.json',

    [string]$TokenExportPath = 'C:\MasterDeskLab\windows-mcp-token.tmp',

    [string]$TokenImportPath = 'C:\MasterDeskLab\windows-mcp-token.import',

    [string]$HostAddress = '192.168.7.3',

    [string]$WindowsMcpVersion = '0.8.5',

    [switch]$RotateToken
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$taskName = 'windows-mcp-server'
$firewallName = 'MasterDesk Windows-MCP Host Only'
$requiredTools = 'Screenshot,Snapshot,Click,Type,Shortcut,Wait,WaitFor,App,Process'

function Update-ProcessPath {
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = "$machine;$user"
}

function Get-UvPath {
    Update-ProcessPath
    $command = Get-Command uv.exe -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    $candidate = Join-Path $env:USERPROFILE '.local\bin\uv.exe'
    if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    return $null
}

function Install-Uv {
    $uv = Get-UvPath
    if ($uv) { return $uv }

    $staged = 'C:\MasterDeskLab\uv.exe'
    if (Test-Path -LiteralPath $staged -PathType Leaf) {
        $destinationDirectory = Join-Path $env:USERPROFILE '.local\bin'
        New-Item -ItemType Directory -Path $destinationDirectory -Force | Out-Null
        $destination = Join-Path $destinationDirectory 'uv.exe'
        Copy-Item -LiteralPath $staged -Destination $destination -Force
        $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
        if (@($userPath -split ';') -notcontains $destinationDirectory) {
            [Environment]::SetEnvironmentVariable(
                'Path', (($userPath.TrimEnd(';') + ';' + $destinationDirectory).TrimStart(';')), 'User'
            )
        }
        Update-ProcessPath
        return $destination
    }

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $installer = Join-Path $env:TEMP 'masterdesk-uv-install.ps1'
    try {
        Invoke-WebRequest -UseBasicParsing -Uri 'https://astral.sh/uv/install.ps1' `
            -OutFile $installer
        & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $installer |
            Out-Null
        if ($LASTEXITCODE -ne 0) { throw "uv installer exited with $LASTEXITCODE" }
    } finally {
        Remove-Item -LiteralPath $installer -Force -ErrorAction SilentlyContinue
    }
    $uv = Get-UvPath
    if (-not $uv) { throw 'uv.exe was not found after installation.' }
    return $uv
}

function New-BearerToken {
    $bytes = New-Object byte[] 32
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    return (($bytes | ForEach-Object { $_.ToString('x2') }) -join '')
}

function Get-InstalledWindowsMcpVersion([string]$UvPath) {
    if (-not $UvPath) { return $null }
    $previous = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $lines = @(& $UvPath tool list 2>&1 | ForEach-Object { [string]$_ })
        if ($LASTEXITCODE -ne 0) { return $null }
        $match = $lines | Where-Object { $_ -match '(?i)windows-mcp\s+v?([0-9]+(?:\.[0-9]+)+)' } |
            Select-Object -First 1
        if ($match -and $match -match '(?i)windows-mcp\s+v?([0-9]+(?:\.[0-9]+)+)') {
            return $matches[1]
        }
        return $null
    } finally { $ErrorActionPreference = $previous }
}

function Set-UserEnvironment([string]$Name, [string]$Value) {
    [Environment]::SetEnvironmentVariable($Name, $Value, 'User')
    Set-Item -LiteralPath "Env:$Name" -Value $Value
}

function Set-HostOnlyFirewall {
    Get-NetFirewallRule -DisplayName $firewallName -ErrorAction SilentlyContinue |
        Remove-NetFirewallRule -ErrorAction Stop
    New-NetFirewallRule -DisplayName $firewallName -Direction Inbound -Action Allow `
        -Protocol TCP -LocalPort 8000 -RemoteAddress "$HostAddress/32" -Profile Any |
        Out-Null
}

function Update-WindowsMcpStartScript {
    $path = Join-Path $env:USERPROFILE '.windows-mcp\start-server.cmd'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw 'Windows-MCP start-server.cmd was not created.'
    }
    $launcherPath = Join-Path $env:USERPROFILE '.windows-mcp\start-server.ps1'
    @(
        '$ErrorActionPreference = ''Stop'''
        "`$names = @('WINDOWS_MCP_AUTH_KEY','WINDOWS_MCP_IP_ALLOWLIST','WINDOWS_MCP_TOOLS','WINDOWS_MCP_DISABLE_FLASH','ANONYMIZED_TELEMETRY')"
        'foreach ($name in $names) {'
        '    $value = [Environment]::GetEnvironmentVariable($name, ''User'')'
        '    if ($null -ne $value) { Set-Item -LiteralPath "Env:$name" -Value $value }'
        '}'
        '$exe = Join-Path $env:USERPROFILE ''.local\bin\windows-mcp.exe'''
        '& $exe serve --transport streamable-http --host 0.0.0.0 --port 8000'
        'exit $LASTEXITCODE'
    ) | Set-Content -LiteralPath $launcherPath -Encoding UTF8
    $logOut = Join-Path $env:USERPROFILE '.windows-mcp\server.log'
    $logError = Join-Path $env:USERPROFILE '.windows-mcp\server.error.log'
    @(
        '@echo off'
        'setlocal'
        ('powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" 1>>"{1}" 2>>"{2}"' -f `
            $launcherPath, $logOut, $logError)
    ) | Set-Content -LiteralPath $path -Encoding Ascii
}

function Update-WindowsMcpTaskAction {
    $launcherPath = Join-Path $env:USERPROFILE '.windows-mcp\start-server.ps1'
    if (-not (Test-Path -LiteralPath $launcherPath -PathType Leaf)) {
        throw 'Windows-MCP PowerShell launcher was not found.'
    }
    $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arguments = '-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f `
        $launcherPath
    $taskAction = New-ScheduledTaskAction -Execute $powershell -Argument $arguments
    Set-ScheduledTask -TaskName $taskName -Action $taskAction -ErrorAction Stop | Out-Null
}

function Stop-WindowsMcpTask {
    Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    do {
        $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        if ($null -eq $task -or [string]$task.State -ne 'Running') { break }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $deadline)
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object {
            $_.ProcessId -ne $PID -and (
                ($_.Name -match '^(python|pythonw|windows-mcp)\.exe$' -and
                    $_.CommandLine -match 'windows[_-]mcp') -or
                ($_.Name -eq 'powershell.exe' -and
                    $_.CommandLine -match '\.windows-mcp\\start-server\.ps1')
            )
        } |
        ForEach-Object {
            Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
        }
}

function Get-WindowsMcpState {
    Update-ProcessPath
    $uv = Get-UvPath
    $command = Get-Command windows-mcp.exe -ErrorAction SilentlyContinue
    if (-not $command) {
        $candidate = Join-Path $env:USERPROFILE '.local\bin\windows-mcp.exe'
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            $command = [pscustomobject]@{ Source = $candidate }
        }
    }
    $commandPath = if ($command) { [string]$command.Source } else { $null }
    $installedVersion = Get-InstalledWindowsMcpVersion -UvPath $uv
    $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    $taskInfo = Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction SilentlyContinue
    $configPath = Join-Path $env:USERPROFILE '.windows-mcp\config.toml'
    $startScriptPath = Join-Path $env:USERPROFILE '.windows-mcp\start-server.cmd'
    $listener = @(Get-NetTCPConnection -LocalPort 8000 -State Listen -ErrorAction SilentlyContinue)
    $processes = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Name -match '^(python|pythonw|windows-mcp)\.exe$' -and
            $_.CommandLine -match 'windows[_-]mcp'
        } | Select-Object ProcessId, SessionId, Name)
    $explorerSessions = @(Get-Process explorer -ErrorAction SilentlyContinue |
        Select-Object -ExpandProperty SessionId -Unique)
    $rule = Get-NetFirewallRule -DisplayName $firewallName -ErrorAction SilentlyContinue
    $addressFilter = if ($rule) {
        $rule | Get-NetFirewallAddressFilter -ErrorAction SilentlyContinue |
            Select-Object -ExpandProperty RemoteAddress
    } else { @() }
    $portRules = @(Get-NetFirewallPortFilter -ErrorAction SilentlyContinue |
        Where-Object LocalPort -eq '8000' |
        Get-NetFirewallRule -ErrorAction SilentlyContinue |
        Where-Object { $_.Enabled -eq 'True' -and $_.Direction -eq 'Inbound' -and $_.Action -eq 'Allow' } |
        Select-Object -ExpandProperty DisplayName -Unique)

    return [ordered]@{
        ComputerName = $env:COMPUTERNAME
        UserName = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        Culture = (Get-Culture).Name
        UvPath = $uv
        WindowsMcpPath = $commandPath
        WindowsMcpVersion = $installedVersion
        AuthUserEnvPresent = [bool][Environment]::GetEnvironmentVariable(
            'WINDOWS_MCP_AUTH_KEY', 'User'
        )
        ToolWhitelist = [Environment]::GetEnvironmentVariable('WINDOWS_MCP_TOOLS', 'User')
        IpAllowlist = [Environment]::GetEnvironmentVariable(
            'WINDOWS_MCP_IP_ALLOWLIST', 'User'
        )
        TaskPresent = [bool]$task
        TaskState = if ($task) { [string]$task.State } else { $null }
        TaskLastResult = if ($taskInfo) { [int]$taskInfo.LastTaskResult } else { $null }
        TaskLastRunTimeUtc = if ($taskInfo -and $taskInfo.LastRunTime) {
            $taskInfo.LastRunTime.ToUniversalTime().ToString('o')
        } else { $null }
        TaskLogonType = if ($task) { [string]$task.Principal.LogonType } else { $null }
        TaskUser = if ($task) { [string]$task.Principal.UserId } else { $null }
        TaskActions = if ($task) { @($task.Actions | ForEach-Object {
            [ordered]@{ Execute = [string]$_.Execute; Arguments = [string]$_.Arguments }
        }) } else { @() }
        ConfigPresent = Test-Path -LiteralPath $configPath -PathType Leaf
        ConfigAuthKeyPresent = if (Test-Path -LiteralPath $configPath -PathType Leaf) {
            [bool](Select-String -LiteralPath $configPath -Pattern '^\s*auth_key\s*=' -Quiet)
        } else { $false }
        StartScriptRegistryLoader = if (Test-Path -LiteralPath $startScriptPath -PathType Leaf) {
            $launcherPath = Join-Path $env:USERPROFILE '.windows-mcp\start-server.ps1'
            Test-Path -LiteralPath $launcherPath -PathType Leaf
        } else { $false }
        ListenerCount = $listener.Count
        ListenerAddress = @($listener | Select-Object -ExpandProperty LocalAddress)
        Processes = $processes
        ExplorerSessionIds = $explorerSessions
        InteractiveProcess = @($processes | Where-Object {
            $_.SessionId -ne 0 -and $explorerSessions -contains $_.SessionId
        }).Count -gt 0
        FirewallRulePresent = [bool]$rule
        FirewallRemoteAddress = @($addressFilter)
        EnabledInboundAllowPort8000Rules = $portRules
    }
}

try {
    New-Item -ItemType Directory -Path (Split-Path -Parent $OutputPath) -Force |
        Out-Null
    switch ($Action) {
        'ClearTokenExport' {
            Remove-Item -LiteralPath $TokenExportPath -Force -ErrorAction SilentlyContinue
            [ordered]@{ Passed = $true; Action = $Action } | ConvertTo-Json |
                Set-Content -LiteralPath $OutputPath -Encoding UTF8
            exit 0
        }
        'Install' {
            if (-not (Test-NetConnection pypi.org -Port 443 -InformationLevel Quiet)) {
                throw 'PyPI TCP 443 is unavailable from the guest.'
            }
            $uv = Install-Uv
            $installedVersion = Get-InstalledWindowsMcpVersion -UvPath $uv
            if ($installedVersion -ne $WindowsMcpVersion) {
                Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
                Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
                    Where-Object {
                        $_.ProcessId -ne $PID -and
                        $_.Name -match '^(python|pythonw|windows-mcp)\.exe$' -and
                        $_.CommandLine -match 'windows[_-]mcp'
                    } |
                    ForEach-Object {
                        Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
                    }
                $previous = $ErrorActionPreference
                try {
                    $ErrorActionPreference = 'Continue'
                    $installOutput = @(& $uv tool install "windows-mcp==$WindowsMcpVersion" `
                        --python 3.13 --force 2>&1)
                    $installCode = $LASTEXITCODE
                } finally { $ErrorActionPreference = $previous }
                if ($installCode -ne 0) {
                    $tail = @($installOutput | Select-Object -Last 3) -join ' | '
                    throw "uv tool install exited with ${installCode}: $tail"
                }
            }
            Update-ProcessPath
            $windowsMcp = Get-Command windows-mcp.exe -ErrorAction Stop

            $token = $null
            if (-not $RotateToken -and (Test-Path -LiteralPath $TokenImportPath -PathType Leaf)) {
                $token = (Get-Content -LiteralPath $TokenImportPath -Raw).Trim()
                if ($token -notmatch '^[0-9a-f]{64}$') {
                    throw 'Imported bearer token has an invalid format.'
                }
            }
            Remove-Item -LiteralPath $TokenImportPath -Force -ErrorAction SilentlyContinue
            if ([string]::IsNullOrWhiteSpace($token)) {
                $token = [Environment]::GetEnvironmentVariable('WINDOWS_MCP_AUTH_KEY', 'User')
            }
            if ($RotateToken -or [string]::IsNullOrWhiteSpace($token)) {
                $token = New-BearerToken
            }
            Set-UserEnvironment -Name 'WINDOWS_MCP_AUTH_KEY' -Value $token
            Set-UserEnvironment -Name 'WINDOWS_MCP_IP_ALLOWLIST' -Value "$HostAddress/32"
            Set-UserEnvironment -Name 'WINDOWS_MCP_TOOLS' -Value $requiredTools
            Set-UserEnvironment -Name 'WINDOWS_MCP_DISABLE_FLASH' -Value '1'
            Set-UserEnvironment -Name 'ANONYMIZED_TELEMETRY' -Value 'false'

            Set-HostOnlyFirewall
            Stop-WindowsMcpTask
            & $windowsMcp.Source install --transport streamable-http --host 0.0.0.0 `
                --port 8000 --force | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "windows-mcp install exited with $LASTEXITCODE" }
            Update-WindowsMcpStartScript
            Stop-WindowsMcpTask
            Update-WindowsMcpTaskAction
            Stop-WindowsMcpTask
            Start-ScheduledTask -TaskName $taskName -ErrorAction Stop

            Set-Content -LiteralPath $TokenExportPath -Value $token -NoNewline -Encoding Ascii
            $deadline = [DateTime]::UtcNow.AddSeconds(90)
            do {
                if (Get-NetTCPConnection -LocalPort 8000 -State Listen `
                        -ErrorAction SilentlyContinue) { break }
                Start-Sleep -Seconds 2
            } while ([DateTime]::UtcNow -lt $deadline)
        }
        'Restart' {
            Stop-WindowsMcpTask
            Update-WindowsMcpTaskAction
            Stop-WindowsMcpTask
            Start-ScheduledTask -TaskName $taskName -ErrorAction Stop
            $deadline = [DateTime]::UtcNow.AddSeconds(90)
            do {
                if (Get-NetTCPConnection -LocalPort 8000 -State Listen `
                        -ErrorAction SilentlyContinue) { break }
                Start-Sleep -Seconds 1
            } while ([DateTime]::UtcNow -lt $deadline)
        }
    }

    $state = Get-WindowsMcpState
    $passed = if ($Action -in @('Install', 'Restart')) {
        $state.TaskPresent -and $state.ListenerCount -gt 0 -and
        $state.InteractiveProcess -and $state.FirewallRulePresent -and
        (@($state.FirewallRemoteAddress) -contains $HostAddress -or
            @($state.FirewallRemoteAddress) -contains "$HostAddress/255.255.255.255" -or
            @($state.FirewallRemoteAddress) -contains "$HostAddress/32") -and
        $state.ToolWhitelist -eq $requiredTools -and $state.AuthUserEnvPresent
    } else { $true }
    [ordered]@{ Passed = $passed; Action = $Action; State = $state } |
        ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $OutputPath -Encoding UTF8
    if (-not $passed) { exit 1 }
} catch {
    [ordered]@{
        Passed = $false
        Action = $Action
        Error = $_.Exception.Message
    } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $OutputPath -Encoding UTF8
    exit 1
}
