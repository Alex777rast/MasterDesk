[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Status', 'Smoke')]
    [string]$Mode,

    [Parameter(Mandatory = $true)]
    [string]$OutputPath,

    [string]$LogArchivePath = 'C:\MasterDeskLab\MasterDeskLogs.zip',

    [ValidateRange(0, 180)]
    [int]$DesktopTimeoutSeconds = 45
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$failures = New-Object System.Collections.Generic.List[string]

function Add-ProbeFailure {
    param([string]$Message)

    if (-not [string]::IsNullOrWhiteSpace($Message)) {
        $failures.Add($Message)
    }
}

function Test-TcpEndpoint {
    param(
        [string]$HostName,
        [int]$Port,
        [int]$TimeoutMilliseconds = 6000
    )

    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $pending = $client.BeginConnect($HostName, $Port, $null, $null)
        if (-not $pending.AsyncWaitHandle.WaitOne($TimeoutMilliseconds, $false)) {
            return $false
        }
        [void]$client.EndConnect($pending)
        return [bool]$client.Connected
    } catch {
        return $false
    } finally {
        [void]$client.Close()
    }
}

function Test-WssEndpoint {
    param(
        [string]$Uri,
        [int]$TimeoutSeconds = 8
    )

    $socket = New-Object System.Net.WebSockets.ClientWebSocket
    $cancellation = New-Object System.Threading.CancellationTokenSource
    try {
        [void]$cancellation.CancelAfter([TimeSpan]::FromSeconds($TimeoutSeconds))
        [void]$socket.ConnectAsync([Uri]$Uri, $cancellation.Token).GetAwaiter().GetResult()
        return [bool]($socket.State -eq [System.Net.WebSockets.WebSocketState]::Open)
    } catch {
        return $false
    } finally {
        [void]$socket.Dispose()
        [void]$cancellation.Dispose()
    }
}

function Get-MasterDeskProcesses {
    try {
        return @(
            Get-CimInstance -ClassName Win32_Process -ErrorAction Stop |
                Where-Object { $_.Name -ieq 'MasterDesk.exe' } |
                Sort-Object ProcessId |
                ForEach-Object {
                    [ordered]@{
                        ProcessId       = [int]$_.ProcessId
                        ParentProcessId = [int]$_.ParentProcessId
                        SessionId       = [int]$_.SessionId
                        Name            = [string]$_.Name
                        CommandLine     = [string]$_.CommandLine
                        ExecutablePath  = [string]$_.ExecutablePath
                    }
                }
        )
    } catch {
        Add-ProbeFailure "process inventory: $($_.Exception.Message)"
        return @()
    }
}

function Get-DesktopSessions {
    try {
        return @(
            Get-CimInstance -ClassName Win32_Process -Filter "Name='explorer.exe'" -ErrorAction Stop |
                Where-Object { [int]$_.SessionId -gt 0 } |
                Sort-Object SessionId, ProcessId |
                ForEach-Object {
                    [ordered]@{
                        SessionId = [int]$_.SessionId
                        ProcessId = [int]$_.ProcessId
                    }
                }
        )
    } catch {
        Add-ProbeFailure "desktop session inventory: $($_.Exception.Message)"
        return @()
    }
}

function Invoke-MasterDeskCliValue {
    param(
        [string]$Executable,
        [string[]]$Arguments,
        [string]$Name
    )

    if ([string]::IsNullOrWhiteSpace($Executable) -or
        -not (Test-Path -LiteralPath $Executable -PathType Leaf)) {
        return $null
    }
    $stdout = "C:\MasterDeskLab\probe-$Name.stdout.txt"
    $stderr = "C:\MasterDeskLab\probe-$Name.stderr.txt"
    Remove-Item -LiteralPath $stdout, $stderr -Force -ErrorAction SilentlyContinue
    try {
        $process = Start-Process -FilePath $Executable -ArgumentList $Arguments -PassThru `
            -RedirectStandardOutput $stdout -RedirectStandardError $stderr -ErrorAction Stop
        if (-not $process.WaitForExit(15000)) {
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
            return $null
        }
        if ($null -ne $process.ExitCode -and [int]$process.ExitCode -ne 0) {
            return $null
        }
        if (Test-Path -LiteralPath $stdout) {
            return ((Get-Content -LiteralPath $stdout -ErrorAction SilentlyContinue | Out-String).Trim())
        }
    } catch {
        return $null
    }
    return $null
}

function Save-MasterDeskLogs {
    param([string]$Destination)

    $staging = 'C:\MasterDeskLab\CollectedLogs'
    if (Test-Path -LiteralPath $staging) {
        Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
    }
    New-Item -ItemType Directory -Path $staging -Force | Out-Null

    $candidates = @(
        (Join-Path $env:APPDATA 'MasterDesk\log'),
        (Join-Path $env:LOCALAPPDATA 'MasterDesk\log'),
        (Join-Path $env:ProgramData 'MasterDesk\log'),
        'C:\Windows\ServiceProfiles\LocalService\AppData\Roaming\MasterDesk\log',
        'C:\Windows\System32\config\systemprofile\AppData\Roaming\MasterDesk\log'
    )

    $copied = 0
    $index = 0
    foreach ($candidate in $candidates) {
        $index++
        if (-not (Test-Path -LiteralPath $candidate)) {
            continue
        }
        $destinationRoot = Join-Path $staging ("source-{0}" -f $index)
        try {
            Copy-Item -LiteralPath $candidate -Destination $destinationRoot -Recurse -Force -ErrorAction Stop
            $copied++
        } catch {
            Add-Content -LiteralPath (Join-Path $staging 'collection-errors.txt') `
                -Value ("{0}: {1}" -f $candidate, $_.Exception.Message) -Encoding UTF8
        }
    }

    if ($copied -eq 0) {
        Set-Content -LiteralPath (Join-Path $staging 'no-logs-found.txt') `
            -Value 'No accessible MasterDesk log directory was found.' -Encoding UTF8
    }

    if (Test-Path -LiteralPath $Destination) {
        Remove-Item -LiteralPath $Destination -Force
    }
    Compress-Archive -Path (Join-Path $staging '*') -DestinationPath $Destination -Force
    return (Test-Path -LiteralPath $Destination)
}

function Get-SafeModeStatus {
    $option = Get-ItemProperty -LiteralPath `
        'HKLM:\SYSTEM\CurrentControlSet\Control\SafeBoot\Option' `
        -Name OptionValue -ErrorAction SilentlyContinue
    $marker = Get-ItemProperty -LiteralPath `
        'HKLM:\SOFTWARE\MasterDesk\SafeModeReboot' `
        -ErrorAction SilentlyContinue
    return [ordered]@{
        Active = $null -ne $option -and [int]$option.OptionValue -ne 0
        OptionValue = if ($null -eq $option) { 0 } else { [int]$option.OptionValue }
        MarkerPresent = $null -ne $marker
        MarkerPhase = if ($null -eq $marker) { 0 } else { [int]$marker.Phase }
        CreatedEntries = if ($null -eq $marker) { '' } else { [string]$marker.CreatedEntries }
    }
}

$result = [ordered]@{
    Mode             = $Mode
    TimestampUtc     = [DateTime]::UtcNow.ToString('o')
    Hostname         = $env:COMPUTERNAME
    IpAddresses      = @()
    DesktopSessions  = @()
    Service          = $null
    SafeMode         = $null
    Identity         = $null
    Processes        = @()
    NetworkAvailable = $false
    Dns              = [ordered]@{}
    Endpoints        = [ordered]@{}
    LogArchive       = $null
    Failures         = @()
    Passed           = $false
}

try {
    $result.SafeMode = Get-SafeModeStatus
    $networkConfigurations = @(
        Get-NetIPConfiguration -ErrorAction SilentlyContinue |
            Where-Object {
                $_.NetAdapter.Status -eq 'Up' -and
                $null -ne $_.IPv4Address
            }
    )
    $result.IpAddresses = @(
        $networkConfigurations |
            ForEach-Object { @($_.IPv4Address) } |
            ForEach-Object { $_.IPAddress } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Sort-Object -Unique
    )
    $result.NetworkAvailable = @(
        $networkConfigurations |
            Where-Object { $null -ne $_.IPv4DefaultGateway }
    ).Count -gt 0

    if ($Mode -eq 'Smoke' -and $DesktopTimeoutSeconds -gt 0) {
        $deadline = [DateTime]::UtcNow.AddSeconds($DesktopTimeoutSeconds)
        do {
            $result.DesktopSessions = @(Get-DesktopSessions)
            if ($result.DesktopSessions.Count -gt 0) {
                break
            }
            Start-Sleep -Seconds 2
        } while ([DateTime]::UtcNow -lt $deadline)
    } else {
        $result.DesktopSessions = @(Get-DesktopSessions)
    }

    $service = Get-CimInstance -ClassName Win32_Service -Filter "Name='MasterDesk'" `
        -ErrorAction SilentlyContinue
    if ($null -ne $service -and $Mode -eq 'Smoke' -and $service.State -ne 'Running') {
        try {
            Start-Service -Name 'MasterDesk' -ErrorAction Stop
            (Get-Service -Name 'MasterDesk' -ErrorAction Stop).WaitForStatus(
                [System.ServiceProcess.ServiceControllerStatus]::Running,
                [TimeSpan]::FromSeconds(25)
            )
        } catch {
            Add-ProbeFailure "service start: $($_.Exception.Message)"
        }
        $service = Get-CimInstance -ClassName Win32_Service -Filter "Name='MasterDesk'" `
            -ErrorAction SilentlyContinue
    }

    if ($null -ne $service) {
        $result.Service = [ordered]@{
            Name        = [string]$service.Name
            State       = [string]$service.State
            StartMode   = [string]$service.StartMode
            StartName   = [string]$service.StartName
            ProcessId   = [int]$service.ProcessId
            PathName    = [string]$service.PathName
        }
    }
    $installedExecutable = if ($null -eq $service) {
        'C:\Program Files\MasterDesk\MasterDesk.exe'
    } else {
        ([string]$service.PathName -replace '^\s*"([^\"]+)".*$', '$1')
    }
    if (Test-Path -LiteralPath $installedExecutable -PathType Leaf) {
        $result.Identity = [ordered]@{
            Id = Invoke-MasterDeskCliValue $installedExecutable @('--get-id') 'get-id'
            Version = Invoke-MasterDeskCliValue $installedExecutable @('--version') 'version'
            BuildDate = Invoke-MasterDeskCliValue $installedExecutable @('--build-date') 'build-date'
            StopService = Invoke-MasterDeskCliValue $installedExecutable `
                @('--option', 'stop-service') 'stop-service'
        }
    }
    $result.Processes = @(Get-MasterDeskProcesses)

    if ($Mode -eq 'Smoke') {
        foreach ($hostName in @('hbbs.masterdesk.online', 'hbbr.masterdesk.online')) {
            try {
                $addresses = @(
                    Resolve-DnsName -Name $hostName -Type A -ErrorAction Stop |
                        Where-Object { $_.IPAddress } |
                        Select-Object -ExpandProperty IPAddress -Unique
                )
                $result.Dns[$hostName] = $addresses
            } catch {
                $result.Dns[$hostName] = @()
            }
        }

        $result.Endpoints['idTcp21116'] = Test-TcpEndpoint 'hbbs.masterdesk.online' 21116
        $result.Endpoints['relayTcp21117'] = Test-TcpEndpoint 'hbbr.masterdesk.online' 21117
        $result.Endpoints['idWss'] = Test-WssEndpoint 'wss://hbbs.masterdesk.online/ws/id'
        $result.Endpoints['relayWss'] = Test-WssEndpoint 'wss://hbbr.masterdesk.online/ws/relay'

        if (-not $result.NetworkAvailable) {
            Add-ProbeFailure 'network: no active IPv4 interface with a default gateway'
        }
        if ($result.DesktopSessions.Count -eq 0) {
            Add-ProbeFailure 'desktop: no interactive explorer.exe session'
        }
        if ($null -eq $result.Service) {
            Add-ProbeFailure 'service: MasterDesk service does not exist'
        } elseif ($result.Service.State -ne 'Running') {
            Add-ProbeFailure "service: state is $($result.Service.State)"
        }
        if ($result.Processes.Count -eq 0) {
            Add-ProbeFailure 'processes: no MasterDesk.exe process found'
        }
        foreach ($hostName in @('hbbs.masterdesk.online', 'hbbr.masterdesk.online')) {
            if (@($result.Dns[$hostName]).Count -eq 0) {
                Add-ProbeFailure "dns: $hostName did not resolve"
            }
        }
        foreach ($endpoint in @('idTcp21116', 'relayTcp21117', 'idWss', 'relayWss')) {
            if (-not $result.Endpoints[$endpoint]) {
                Add-ProbeFailure "endpoint: $endpoint is unavailable"
            }
        }

        try {
            if (Save-MasterDeskLogs -Destination $LogArchivePath) {
                $result.LogArchive = $LogArchivePath
            }
        } catch {
            Add-ProbeFailure "log collection: $($_.Exception.Message)"
        }
    }
} catch {
    Add-ProbeFailure "probe: $($_.Exception.Message)"
} finally {
    $result.Failures = @($failures)
    $result.Passed = $failures.Count -eq 0
    $parent = Split-Path -Parent $OutputPath
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $OutputPath -Encoding UTF8
}

exit 0
