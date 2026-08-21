[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Portable', 'Install', 'Service', 'SingleGui', 'Wss')]
    [string]$Scenario,

    [Parameter(Mandatory = $true)]
    [string]$OutputPath,

    [string]$CandidateMarkerPath = 'C:\MasterDeskLab\candidate-path.txt',

    [string]$LogArchivePath = 'C:\MasterDeskLab\MasterDeskScenarioLogs.zip',

    [string]$ExpectedHostname
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$script:Failures = New-Object System.Collections.Generic.List[string]
$script:Criteria = [ordered]@{}
$script:Evidence = [ordered]@{}
$script:LogAccessWarnings = New-Object System.Collections.Generic.List[string]

function Add-Criterion {
    param(
        [string]$Name,
        [bool]$Passed,
        [string]$Failure
    )

    $script:Criteria[$Name] = $Passed
    if (-not $Passed -and -not [string]::IsNullOrWhiteSpace($Failure)) {
        $script:Failures.Add($Failure)
    }
}

function Convert-ProcessRecord {
    param([object]$Process)

    return [ordered]@{
        ProcessId       = [int]$Process.ProcessId
        ParentProcessId = [int]$Process.ParentProcessId
        SessionId       = [int]$Process.SessionId
        Name            = [string]$Process.Name
        CommandLine     = [string]$Process.CommandLine
        ExecutablePath  = [string]$Process.ExecutablePath
    }
}

function Get-LabProcesses {
    param([string]$CandidatePath)

    $candidateName = if ([string]::IsNullOrWhiteSpace($CandidatePath)) {
        ''
    } else {
        [System.IO.Path]::GetFileName($CandidatePath)
    }
    return @(
        Get-CimInstance -ClassName Win32_Process -ErrorAction Stop |
            Where-Object {
                $_.Name -ieq 'MasterDesk.exe' -or
                $_.Name -ieq 'rustdesk.exe' -or
                (-not [string]::IsNullOrWhiteSpace($candidateName) -and $_.Name -ieq $candidateName)
            } |
            Sort-Object ProcessId |
            ForEach-Object { Convert-ProcessRecord $_ }
    )
}

function Get-MasterDeskServices {
    return @(
        Get-CimInstance -ClassName Win32_Service -ErrorAction Stop |
            Where-Object { $_.Name -ieq 'MasterDesk' } |
            ForEach-Object {
                [ordered]@{
                    Name      = [string]$_.Name
                    State     = [string]$_.State
                    StartMode = [string]$_.StartMode
                    ProcessId = [int]$_.ProcessId
                    PathName  = [string]$_.PathName
                }
            }
    )
}

function Get-DesktopSessions {
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
}

function Get-ServiceExecutablePath {
    param([AllowNull()][object]$Service)

    if ($null -eq $Service -or [string]::IsNullOrWhiteSpace([string]$Service.PathName)) {
        return $null
    }
    $pathName = [string]$Service.PathName
    if ($pathName -match '^\s*"([^"]+)"') {
        return $matches[1]
    }
    if ($pathName -match '^\s*(\S+)') {
        return $matches[1]
    }
    return $null
}

function Get-FileSha256 {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function Get-CandidatePath {
    if (-not (Test-Path -LiteralPath $CandidateMarkerPath -PathType Leaf)) {
        return $null
    }
    $rawPath = (Get-Content -LiteralPath $CandidateMarkerPath -Raw -ErrorAction Stop).Trim()
    if ([string]::IsNullOrWhiteSpace($rawPath)) {
        return $null
    }
    $fullPath = [System.IO.Path]::GetFullPath($rawPath)
    $labRoot = [System.IO.Path]::GetFullPath('C:\MasterDeskLab')
    if (-not $fullPath.StartsWith(
        $labRoot + [System.IO.Path]::DirectorySeparatorChar,
        [System.StringComparison]::OrdinalIgnoreCase
    )) {
        return $null
    }
    if ([System.IO.Path]::GetExtension($fullPath) -ine '.exe') {
        return $null
    }
    return $fullPath
}

function Get-CandidateMetadata {
    $path = 'C:\MasterDeskLab\candidate-metadata.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return $null
    }
    try {
        return Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json
    } catch {
        return $null
    }
}

function Get-KnownInstalledPaths {
    return @(
        'C:\Program Files\MasterDesk\MasterDesk.exe',
        'C:\Program Files (x86)\MasterDesk\MasterDesk.exe',
        (Join-Path $env:LOCALAPPDATA 'MasterDesk\MasterDesk.exe')
    ) | Select-Object -Unique
}

function Get-ExistingInstalledPaths {
    return @(Get-KnownInstalledPaths | Where-Object {
        Test-Path -LiteralPath $_ -PathType Leaf
    })
}

function Test-CandidateRelatedProcess {
    param(
        [object]$Process,
        [string]$CandidatePath
    )

    if (-not [string]::IsNullOrWhiteSpace($CandidatePath) -and
        [string]::Equals([string]$Process.ExecutablePath, $CandidatePath, [StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }
    if ([string]$Process.Name -ieq 'rustdesk.exe') {
        return $true
    }
    return ([string]$Process.ExecutablePath) -match '(?i)\\AppData\\Local\\rustdesk\\'
}

function Get-ProcessRole {
    param(
        [object]$Process,
        [int]$ServicePid
    )

    $commandLine = [string]$Process.CommandLine
    if ($ServicePid -gt 0 -and [int]$Process.ProcessId -eq $ServicePid) {
        return 'service'
    }
    foreach ($role in @('service', 'server', 'tray')) {
        if ($commandLine -match ("(?i)(^|\s)--{0}(\s|$)" -f $role)) {
            return $role
        }
    }
    # An unelevated interactive probe cannot read command lines of service-owned
    # processes. The current Windows architecture makes --server a direct child
    # of the service PID in the target interactive session.
    if ($ServicePid -gt 0 -and [int]$Process.ParentProcessId -eq $ServicePid -and
        [int]$Process.SessionId -gt 0) {
        return 'server'
    }
    if ([string]$Process.Name -ieq 'MasterDesk.exe' -and [int]$Process.SessionId -gt 0) {
        return 'gui'
    }
    if ([string]$Process.Name -ieq 'rustdesk.exe') {
        return 'portable'
    }
    return 'unknown'
}

function Get-RoleInventory {
    param(
        [object[]]$Processes,
        [int]$ServicePid
    )

    $inventory = [ordered]@{
        Service = @()
        Server  = @()
        Tray    = @()
        Gui     = @()
        Portable = @()
        Unknown = @()
    }
    foreach ($process in $Processes) {
        $role = Get-ProcessRole -Process $process -ServicePid $ServicePid
        switch ($role) {
            'service'  { $inventory.Service += $process }
            'server'   { $inventory.Server += $process }
            'tray'     { $inventory.Tray += $process }
            'gui'      { $inventory.Gui += $process }
            'portable' { $inventory.Portable += $process }
            default    { $inventory.Unknown += $process }
        }
    }
    return $inventory
}

function Test-TcpEndpoint {
    param([string]$HostName, [int]$Port, [int]$TimeoutMilliseconds = 6000)

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
    param([string]$Uri, [int]$TimeoutSeconds = 8)

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

function Get-LogRoots {
    return @(
        (Join-Path $env:APPDATA 'MasterDesk\log'),
        (Join-Path $env:APPDATA 'RustDesk\log'),
        (Join-Path $env:LOCALAPPDATA 'MasterDesk\log'),
        (Join-Path $env:ProgramData 'MasterDesk\log'),
        'C:\Windows\ServiceProfiles\LocalService\AppData\Roaming\MasterDesk\log',
        'C:\Windows\System32\config\systemprofile\AppData\Roaming\MasterDesk\log'
    ) | Select-Object -Unique
}

function Test-AccessibleLogRoot {
    param([string]$Path)

    try {
        return Test-Path -LiteralPath $Path -PathType Container -ErrorAction Stop
    } catch {
        $warning = "{0}: {1}" -f $Path, $_.Exception.Message
        if (-not $script:LogAccessWarnings.Contains($warning)) {
            $script:LogAccessWarnings.Add($warning)
        }
        return $false
    }
}

function Get-LogOffsets {
    $offsets = [ordered]@{}
    foreach ($root in Get-LogRoots) {
        if (-not (Test-AccessibleLogRoot -Path $root)) {
            continue
        }
        foreach ($file in Get-ChildItem -LiteralPath $root -Filter '*.log' -File -Recurse -ErrorAction SilentlyContinue) {
            $offsets[$file.FullName] = [long]$file.Length
        }
    }
    return $offsets
}

function Get-AppendedLogLines {
    param(
        [System.Collections.IDictionary]$Offsets,
        [string]$IncludePattern = ''
    )

    $lines = New-Object System.Collections.Generic.List[object]
    foreach ($root in Get-LogRoots) {
        if (-not (Test-AccessibleLogRoot -Path $root)) {
            continue
        }
        foreach ($file in Get-ChildItem -LiteralPath $root -Filter '*.log' -File -Recurse -ErrorAction SilentlyContinue) {
            $offset = 0L
            if ($Offsets.Contains($file.FullName)) {
                $offset = [long]$Offsets[$file.FullName]
            }
            # MasterDesk rotates the active log when service/server processes
            # restart and reuses the same *CURRENT.log path for a new file.
            # Runtime timestamp filtering below prevents old lines from being
            # accepted, so read CURRENT files from zero to avoid applying an
            # offset belonging to the pre-restart file identity.
            if ($file.Name -match '(?i)CURRENT\.log$') {
                $offset = 0L
            } elseif ([long]$file.Length -lt $offset) {
                $offset = 0L
            }
            if ([long]$file.Length -le $offset) {
                continue
            }
            $stream = New-Object System.IO.FileStream(
                $file.FullName,
                [System.IO.FileMode]::Open,
                [System.IO.FileAccess]::Read,
                [System.IO.FileShare]::ReadWrite
            )
            try {
                [void]$stream.Seek($offset, [System.IO.SeekOrigin]::Begin)
                $reader = New-Object System.IO.StreamReader($stream)
                try {
                    while (-not $reader.EndOfStream) {
                        $text = $reader.ReadLine()
                        if (-not [string]::IsNullOrWhiteSpace($IncludePattern) -and
                            $text -notmatch $IncludePattern) {
                            continue
                        }
                        $lines.Add([ordered]@{ File = $file.FullName; Text = $text })
                        if ($lines.Count -ge 2000) {
                            return @($lines | ForEach-Object { $_ })
                        }
                    }
                } finally {
                    $reader.Dispose()
                }
            } finally {
                $stream.Dispose()
            }
        }
    }
    return @($lines | ForEach-Object { $_ })
}

function Get-LogLineTimestampUtc {
    param([string]$Line)

    if ($Line -match '^\[([^\]]+)\]') {
        try {
            return ([DateTimeOffset]::Parse(
                $matches[1],
                [System.Globalization.CultureInfo]::InvariantCulture
            )).UtcDateTime
        } catch {
            return [DateTime]::MinValue
        }
    }
    return [DateTime]::MinValue
}

function Save-ScenarioLogs {
    param([string]$Destination)

    $staging = Join-Path $env:TEMP ("MasterDeskLab-ScenarioLogs-{0}" -f $PID)
    if (Test-Path -LiteralPath $staging) {
        Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
    }
    New-Item -ItemType Directory -Path $staging -Force | Out-Null
    $copied = 0
    $index = 0
    foreach ($root in Get-LogRoots) {
        $index++
        if (-not (Test-AccessibleLogRoot -Path $root)) {
            continue
        }
        try {
            Copy-Item -LiteralPath $root -Destination (Join-Path $staging ("source-{0}" -f $index)) `
                -Recurse -Force -ErrorAction Stop
            $copied++
        } catch {
            Add-Content -LiteralPath (Join-Path $staging 'collection-errors.txt') `
                -Value ("{0}: {1}" -f $root, $_.Exception.Message) -Encoding UTF8
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

function Invoke-ClientCli {
    param(
        [string]$Executable,
        [string[]]$Arguments,
        [string]$Prefix
    )

    $stdout = "C:\MasterDeskLab\$Prefix.stdout.txt"
    $stderr = "C:\MasterDeskLab\$Prefix.stderr.txt"
    foreach ($path in @($stdout, $stderr)) {
        if (Test-Path -LiteralPath $path) {
            Remove-Item -LiteralPath $path -Force
        }
    }
    try {
        $process = Start-Process -FilePath $Executable -ArgumentList $Arguments -PassThru `
            -RedirectStandardOutput $stdout -RedirectStandardError $stderr -ErrorAction Stop
        if (-not $process.WaitForExit(30000)) {
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
            return [ordered]@{ Success = $false; ExitCode = -1; Output = 'timeout' }
        }
        $output = @()
        if (Test-Path -LiteralPath $stdout) {
            $output += @(Get-Content -LiteralPath $stdout -ErrorAction SilentlyContinue)
        }
        if (Test-Path -LiteralPath $stderr) {
            $output += @(Get-Content -LiteralPath $stderr -ErrorAction SilentlyContinue)
        }
        return [ordered]@{
            Success = $process.ExitCode -eq 0
            ExitCode = [int]$process.ExitCode
            Output = ($output -join "`n").Trim()
        }
    } catch {
        return [ordered]@{ Success = $false; ExitCode = 1; Output = $_.Exception.Message }
    }
}

function Invoke-PortableScenario {
    $candidate = Get-CandidatePath
    $metadata = Get-CandidateMetadata
    Add-Criterion 'candidate_exists' ($null -ne $candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) `
        'portable prerequisite: deployed candidate marker/file is missing'
    $candidateHash = Get-FileSha256 $candidate
    Add-Criterion 'candidate_matches_host_sha256' ($null -ne $metadata -and
        -not [string]::IsNullOrWhiteSpace($candidateHash) -and
        $candidateHash -eq [string]$metadata.HostSha256) `
        'portable prerequisite: deployed candidate SHA256 does not match host candidate'
    if ($script:Failures.Count -gt 0) {
        return 'candidate missing'
    }

    $beforeServices = @(Get-MasterDeskServices)
    $beforeProcesses = @(Get-LabProcesses -CandidatePath $candidate)
    $beforeInstalledPaths = @(Get-ExistingInstalledPaths)
    Add-Criterion 'clean_service_absent' ($beforeServices.Count -eq 0) `
        ("portable clean baseline: expected no MasterDesk service, found {0}" -f $beforeServices.Count)
    Add-Criterion 'clean_installed_binary_absent' ($beforeInstalledPaths.Count -eq 0) `
        ("portable clean baseline: installed MasterDesk executable exists: {0}" -f ($beforeInstalledPaths -join ', '))
    Add-Criterion 'clean_processes_absent' ($beforeProcesses.Count -eq 0) `
        ("portable clean baseline: expected no MasterDesk/rustdesk processes, found {0}" -f $beforeProcesses.Count)
    if ($script:Failures.Count -gt 0) {
        $script:Evidence['BeforeServices'] = $beforeServices
        $script:Evidence['BeforeProcesses'] = $beforeProcesses
        $script:Evidence['BeforeInstalledPaths'] = $beforeInstalledPaths
        return 'clean baseline failed'
    }
    $beforePids = @($beforeProcesses | ForEach-Object { [int]$_.ProcessId })
    $beforeService = $beforeServices | Select-Object -First 1
    $installedPath = Get-ServiceExecutablePath $beforeService
    $beforeInstalledHash = Get-FileSha256 $installedPath
    $beforeSignature = if ($null -eq $beforeService) {
        'missing'
    } else {
        "{0}|{1}|{2}" -f $beforeService.Name, $beforeService.StartMode, $beforeService.PathName
    }

    $launch = $null
    try {
        $launch = Start-Process -FilePath $candidate -PassThru -ErrorAction Stop
        Add-Criterion 'candidate_launched' $true ''
        $script:Evidence['LaunchPid'] = [int]$launch.Id
    } catch {
        Add-Criterion 'candidate_launched' $false ("portable launch: {0}" -f $_.Exception.Message)
        return 'launch failed'
    }

    Start-Sleep -Seconds 8
    $afterProcesses = @(Get-LabProcesses -CandidatePath $candidate)
    $newProcesses = @(
        $afterProcesses | Where-Object {
            $beforePids -notcontains [int]$_.ProcessId -and
            (Test-CandidateRelatedProcess -Process $_ -CandidatePath $candidate)
        }
    )
    $userProcesses = @($newProcesses | Where-Object { [int]$_.SessionId -gt 0 })
    Add-Criterion 'single_interactive_portable_process_appeared' ($userProcesses.Count -eq 1) `
        ("portable process: expected one new interactive candidate process, found {0}" -f $userProcesses.Count)

    Start-Sleep -Seconds 5
    $stableProcesses = @(Get-LabProcesses -CandidatePath $candidate)
    $stablePids = @($stableProcesses | ForEach-Object { [int]$_.ProcessId })
    $survivors = @($userProcesses | Where-Object { $stablePids -contains [int]$_.ProcessId })
    Add-Criterion 'portable_process_stable' ($survivors.Count -eq 1) `
        'portable process: candidate-related user process exited during the stability window'

    $afterServices = @(Get-MasterDeskServices)
    $afterService = $afterServices | Select-Object -First 1
    $afterSignature = if ($null -eq $afterService) {
        'missing'
    } else {
        "{0}|{1}|{2}" -f $afterService.Name, $afterService.StartMode, $afterService.PathName
    }
    Add-Criterion 'service_count_unchanged' ($beforeServices.Count -eq $afterServices.Count) `
        'portable invariant: MasterDesk service count changed'
    Add-Criterion 'service_configuration_unchanged' ($beforeSignature -eq $afterSignature) `
        'portable invariant: MasterDesk service configuration changed'
    $afterInstalledHash = Get-FileSha256 (Get-ServiceExecutablePath $afterService)
    Add-Criterion 'installed_executable_unchanged' ($beforeInstalledHash -eq $afterInstalledHash) `
        'portable invariant: installed MasterDesk executable changed'
    $afterInstalledPaths = @(Get-ExistingInstalledPaths)
    Add-Criterion 'installed_copy_not_created' ($afterInstalledPaths.Count -eq 0) `
        ("portable invariant: installed executable was created: {0}" -f ($afterInstalledPaths -join ', '))

    $script:Evidence['Candidate'] = $candidate
    $script:Evidence['BeforeService'] = $beforeService
    $script:Evidence['AfterService'] = $afterService
    $script:Evidence['NewProcesses'] = $newProcesses
    $script:Evidence['StableProcesses'] = $survivors
    $script:Evidence['HostSha256'] = [string]$metadata.HostSha256
    $script:Evidence['GuestCandidateSha256'] = $candidateHash

    foreach ($process in $newProcesses) {
        if (Test-CandidateRelatedProcess -Process $process -CandidatePath $candidate) {
            Stop-Process -Id ([int]$process.ProcessId) -Force -ErrorAction SilentlyContinue
        }
    }
    return ("candidate={0} userProcesses={1} serviceChanged=false" -f `
        [System.IO.Path]::GetFileName($candidate), $survivors.Count)
}

function Invoke-InstallScenario {
    $candidate = Get-CandidatePath
    $metadata = Get-CandidateMetadata
    Add-Criterion 'candidate_exists' ($null -ne $candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) `
        'install prerequisite: deployed candidate marker/file is missing'
    $candidateHash = Get-FileSha256 $candidate
    Add-Criterion 'candidate_matches_host_sha256' ($null -ne $metadata -and
        -not [string]::IsNullOrWhiteSpace($candidateHash) -and
        $candidateHash -eq [string]$metadata.HostSha256) `
        'install prerequisite: deployed candidate SHA256 does not match host candidate'
    if ($script:Failures.Count -gt 0) {
        return 'candidate missing'
    }

    $beforeServices = @(Get-MasterDeskServices)
    $beforeProcesses = @(Get-LabProcesses -CandidatePath $candidate)
    $beforeInstalledPaths = @(Get-ExistingInstalledPaths)
    Add-Criterion 'clean_service_absent' ($beforeServices.Count -eq 0) `
        ("install clean baseline: expected no MasterDesk service, found {0}" -f $beforeServices.Count)
    Add-Criterion 'clean_installed_binary_absent' ($beforeInstalledPaths.Count -eq 0) `
        ("install clean baseline: installed MasterDesk executable exists: {0}" -f ($beforeInstalledPaths -join ', '))
    Add-Criterion 'clean_processes_absent' ($beforeProcesses.Count -eq 0) `
        ("install clean baseline: expected no MasterDesk/rustdesk processes, found {0}" -f $beforeProcesses.Count)
    if ($script:Failures.Count -gt 0) {
        $script:Evidence['BeforeServices'] = $beforeServices
        $script:Evidence['BeforeProcesses'] = $beforeProcesses
        $script:Evidence['BeforeInstalledPaths'] = $beforeInstalledPaths
        return 'clean baseline failed'
    }
    $beforeService = $beforeServices | Select-Object -First 1
    $beforePid = if ($null -eq $beforeService) { 0 } else { [int]$beforeService.ProcessId }
    $beforeInstalledPath = Get-ServiceExecutablePath $beforeService
    $beforeWriteTime = if (-not [string]::IsNullOrWhiteSpace($beforeInstalledPath) -and
        (Test-Path -LiteralPath $beforeInstalledPath -PathType Leaf)) {
        (Get-Item -LiteralPath $beforeInstalledPath).LastWriteTimeUtc
    } else {
        [DateTime]::MinValue
    }

    try {
        $installer = Start-Process -FilePath $candidate -ArgumentList '--silent-install' `
            -PassThru -ErrorAction Stop
        Add-Criterion 'installation_command_started' $true ''
        $script:Evidence['InstallerLaunchPid'] = [int]$installer.Id
    } catch {
        Add-Criterion 'installation_command_started' $false ("install launch: {0}" -f $_.Exception.Message)
        return 'launch failed'
    }

    $deadline = [DateTime]::UtcNow.AddSeconds(150)
    $afterServices = @()
    $afterProcesses = @()
    $installEffect = $false
    do {
        Start-Sleep -Seconds 3
        $afterServices = @(Get-MasterDeskServices)
        $afterProcesses = @(Get-LabProcesses -CandidatePath $candidate)
        $service = $afterServices | Select-Object -First 1
        $installedPath = Get-ServiceExecutablePath $service
        $writeTime = if (-not [string]::IsNullOrWhiteSpace($installedPath) -and
            (Test-Path -LiteralPath $installedPath -PathType Leaf)) {
            (Get-Item -LiteralPath $installedPath).LastWriteTimeUtc
        } else {
            [DateTime]::MinValue
        }
        $installEffect = $null -ne $service -and (
            [int]$service.ProcessId -ne $beforePid -or $writeTime -gt $beforeWriteTime
        )
        $silentProcesses = @($afterProcesses | Where-Object { [string]$_.CommandLine -match '(?i)--silent-install' })
        $serviceProcess = if ($null -eq $service) {
            @()
        } else {
            @($afterProcesses | Where-Object {
                [int]$_.ProcessId -eq [int]$service.ProcessId -and
                [string]$_.CommandLine -match '(?i)(^|\s)--service(\s|$)'
            })
        }
        if ($installEffect -and $service.State -eq 'Running' -and
            $serviceProcess.Count -eq 1 -and $silentProcesses.Count -eq 0) {
            break
        }
    } while ([DateTime]::UtcNow -lt $deadline)

    $service = $afterServices | Select-Object -First 1
    $installedPath = Get-ServiceExecutablePath $service
    $serviceProcesses = if ($null -eq $service) { @() } else {
        @($afterProcesses | Where-Object {
            [int]$_.ProcessId -eq [int]$service.ProcessId -and
            [string]$_.CommandLine -match '(?i)(^|\s)--service(\s|$)'
        })
    }
    $silentProcesses = @($afterProcesses | Where-Object { [string]$_.CommandLine -match '(?i)--silent-install' })

    Add-Criterion 'installation_effect_observed' $installEffect `
        'install completion: service PID and installed executable timestamp did not change'
    Add-Criterion 'single_service' ($afterServices.Count -eq 1) `
        ("install result: expected one MasterDesk service, found {0}" -f $afterServices.Count)
    Add-Criterion 'service_running' ($null -ne $service -and $service.State -eq 'Running') `
        'install result: MasterDesk service is not running'
    Add-Criterion 'service_automatic' ($null -ne $service -and $service.StartMode -in @('Auto', 'Automatic')) `
        'install result: MasterDesk service start mode is not automatic'
    Add-Criterion 'service_process_matches_pid' (@($serviceProcesses).Count -eq 1) `
        'install result: service PID does not identify one --service process'
    Add-Criterion 'installed_executable_exists' (-not [string]::IsNullOrWhiteSpace($installedPath) -and
        (Test-Path -LiteralPath $installedPath -PathType Leaf)) `
        'install result: service executable does not exist'
    Add-Criterion 'installed_path_expected' (-not [string]::IsNullOrWhiteSpace($installedPath) -and
        $installedPath -match '(?i)\\Program Files\\MasterDesk\\MasterDesk\.exe$') `
        ("install result: unexpected service executable path: {0}" -f $installedPath)
    Add-Criterion 'installer_completed' ($silentProcesses.Count -eq 0) `
        'install completion: --silent-install process is still running'
    $installedHash = Get-FileSha256 $installedPath
    Add-Criterion 'installed_sha256_matches_expected_host_payload' (
        -not [string]::IsNullOrWhiteSpace([string]$metadata.ExpectedInstalledSha256) -and
        -not [string]::IsNullOrWhiteSpace($installedHash) -and
        $installedHash -eq [string]$metadata.ExpectedInstalledSha256
    ) 'install result: installed executable SHA256 does not match expected host payload'

    if ($script:Failures.Count -eq 0) {
        $marker = [ordered]@{
            TimestampUtc = [DateTime]::UtcNow.ToString('o')
            CandidatePath = $candidate
            CandidateSha256 = $candidateHash
            HostSha256 = [string]$metadata.HostSha256
            ExpectedInstalledSha256 = [string]$metadata.ExpectedInstalledSha256
            InstalledPath = $installedPath
            InstalledSha256 = $installedHash
        }
        $marker | ConvertTo-Json -Depth 4 |
            Set-Content -LiteralPath 'C:\MasterDeskLab\installed-candidate.json' -Encoding UTF8
    }

    $script:Evidence['BeforeService'] = $beforeService
    $script:Evidence['AfterService'] = $service
    $script:Evidence['Processes'] = $afterProcesses
    $script:Evidence['InstalledPath'] = $installedPath
    $serviceState = if ($null -eq $service) { 'missing' } else { $service.State }
    $servicePid = if ($null -eq $service) { 0 } else { $service.ProcessId }
    return ("service={0} pid={1} path={2}" -f $serviceState, $servicePid, $installedPath)
}

function Invoke-ServiceScenario {
    $services = @(Get-MasterDeskServices)
    $service = $services | Select-Object -First 1
    Add-Criterion 'single_service_before_restart' ($services.Count -eq 1) `
        ("service prerequisite: expected one MasterDesk service, found {0}" -f $services.Count)
    Add-Criterion 'service_running_before_restart' ($null -ne $service -and $service.State -eq 'Running') `
        'service prerequisite: MasterDesk service is not running'
    if ($script:Failures.Count -gt 0) {
        return 'service prerequisite failed'
    }

    $oldPid = [int]$service.ProcessId
    try {
        Restart-Service -Name 'MasterDesk' -Force -ErrorAction Stop
        Add-Criterion 'restart_command_completed' $true ''
    } catch {
        Add-Criterion 'restart_command_completed' $false ("service restart: {0}" -f $_.Exception.Message)
        return 'restart failed'
    }

    $deadline = [DateTime]::UtcNow.AddSeconds(45)
    do {
        Start-Sleep -Seconds 2
        $services = @(Get-MasterDeskServices)
        $service = $services | Select-Object -First 1
        if ($null -ne $service -and $service.State -eq 'Running' -and [int]$service.ProcessId -gt 0) {
            break
        }
    } while ([DateTime]::UtcNow -lt $deadline)

    $samples = @()
    for ($index = 0; $index -lt 3; $index++) {
        Start-Sleep -Seconds 3
        $current = @(Get-MasterDeskServices) | Select-Object -First 1
        $samples += [ordered]@{
            TimestampUtc = [DateTime]::UtcNow.ToString('o')
            State = if ($null -eq $current) { 'Missing' } else { $current.State }
            ProcessId = if ($null -eq $current) { 0 } else { [int]$current.ProcessId }
        }
    }
    $newPid = if ($null -eq $service) { 0 } else { [int]$service.ProcessId }
    $stable = @($samples | Where-Object { $_.State -eq 'Running' -and [int]$_.ProcessId -eq $newPid }).Count -eq 3
    $processes = @(Get-LabProcesses -CandidatePath '')
    $serviceProcesses = @($processes | Where-Object {
        [int]$_.ProcessId -eq $newPid -and [string]$_.CommandLine -match '(?i)(^|\s)--service(\s|$)'
    })

    Add-Criterion 'single_service_after_restart' ($services.Count -eq 1) `
        ("service result: expected one service, found {0}" -f $services.Count)
    Add-Criterion 'service_running_after_restart' ($null -ne $service -and $service.State -eq 'Running') `
        'service result: MasterDesk service did not return to Running'
    Add-Criterion 'service_pid_replaced' ($newPid -gt 0 -and $newPid -ne $oldPid) `
        'service result: service PID was not replaced after restart'
    Add-Criterion 'service_process_command_line' ($serviceProcesses.Count -eq 1) `
        'service result: service PID is not one MasterDesk --service process'
    Add-Criterion 'service_stable_no_crash_loop' $stable `
        'service result: service state/PID was not stable across three samples'

    $script:Evidence['OldPid'] = $oldPid
    $script:Evidence['NewPid'] = $newPid
    $script:Evidence['Service'] = $service
    $script:Evidence['ServiceProcess'] = $serviceProcesses
    $script:Evidence['StabilitySamples'] = $samples
    return ("oldPid={0} newPid={1} stableSamples=3/3" -f $oldPid, $newPid)
}

function Invoke-SingleGuiScenario {
    $services = @(Get-MasterDeskServices)
    $service = $services | Select-Object -First 1
    $installedPath = Get-ServiceExecutablePath $service
    $desktopSessions = @(Get-DesktopSessions)
    Add-Criterion 'service_running' ($null -ne $service -and $service.State -eq 'Running') `
        'single-gui prerequisite: MasterDesk service is not running'
    Add-Criterion 'installed_executable_exists' (-not [string]::IsNullOrWhiteSpace($installedPath) -and
        (Test-Path -LiteralPath $installedPath -PathType Leaf)) `
        'single-gui prerequisite: installed MasterDesk executable is missing'
    Add-Criterion 'desktop_session_exists' ($desktopSessions.Count -gt 0) `
        'single-gui prerequisite: no interactive desktop session exists'
    if ($script:Failures.Count -gt 0) {
        return 'prerequisite failed'
    }

    $before = @(Get-LabProcesses -CandidatePath '')
    $launchPids = @()
    try {
        $first = Start-Process -FilePath $installedPath -PassThru -ErrorAction Stop
        $launchPids += [int]$first.Id
        Start-Sleep -Seconds 3
        $second = Start-Process -FilePath $installedPath -PassThru -ErrorAction Stop
        $launchPids += [int]$second.Id
        Add-Criterion 'two_gui_launch_commands_started' $true ''
    } catch {
        Add-Criterion 'two_gui_launch_commands_started' $false ("single-gui launch: {0}" -f $_.Exception.Message)
        return 'launch failed'
    }

    Start-Sleep -Seconds 12
    $after = @(Get-LabProcesses -CandidatePath '')
    $roles = Get-RoleInventory -Processes $after -ServicePid ([int]$service.ProcessId)
    $desktopIds = @($desktopSessions | ForEach-Object { [int]$_.SessionId })
    $guiInDesktop = @($roles.Gui | Where-Object { $desktopIds -contains [int]$_.SessionId })
    $trayGroups = @($roles.Tray | Group-Object SessionId | Where-Object { $_.Count -gt 1 })
    $serverGroups = @($roles.Server | Group-Object SessionId | Where-Object { $_.Count -gt 1 })

    Add-Criterion 'single_service_process' ($roles.Service.Count -eq 1) `
        ("single-gui result: expected one --service process, found {0}" -f $roles.Service.Count)
    Add-Criterion 'single_interactive_gui' ($roles.Gui.Count -eq 1 -and $guiInDesktop.Count -eq 1) `
        ("single-gui result: expected one interactive argument-less GUI, found {0}" -f $roles.Gui.Count)
    Add-Criterion 'no_duplicate_tray_per_session' ($trayGroups.Count -eq 0) `
        'single-gui result: multiple --tray processes exist in one session'
    Add-Criterion 'no_duplicate_server_per_session' ($serverGroups.Count -eq 0) `
        'single-gui result: multiple --server processes exist in one session'

    $script:Evidence['LaunchPids'] = $launchPids
    $script:Evidence['DesktopSessions'] = $desktopSessions
    $script:Evidence['BeforeProcesses'] = $before
    $script:Evidence['AfterProcesses'] = $after
    $script:Evidence['Roles'] = $roles
    return ("service={0} gui={1} server={2} tray={3}" -f `
        $roles.Service.Count, $roles.Gui.Count, $roles.Server.Count, $roles.Tray.Count)
}

function Invoke-WssScenario {
    $installedMarkerPath = 'C:\MasterDeskLab\installed-candidate.json'
    Add-Criterion 'installed_candidate_marker_exists' (Test-Path -LiteralPath $installedMarkerPath -PathType Leaf) `
        'wss prerequisite: run the Install scenario for the deployed candidate first'
    if ($script:Failures.Count -gt 0) {
        return 'installed candidate marker missing'
    }

    $installedMarker = Get-Content -LiteralPath $installedMarkerPath -Raw | ConvertFrom-Json
    $candidateMetadata = Get-CandidateMetadata
    $candidatePath = Get-CandidatePath
    $candidateHash = Get-FileSha256 $candidatePath
    $installedPath = [string]$installedMarker.InstalledPath
    $currentInstalledHash = Get-FileSha256 $installedPath
    Add-Criterion 'deployed_package_matches_host_sha256' ($null -ne $candidateMetadata -and
        -not [string]::IsNullOrWhiteSpace($candidateHash) -and
        $candidateHash -eq [string]$candidateMetadata.HostSha256) `
        'wss prerequisite: deployed outer package SHA256 does not match host package'
    Add-Criterion 'installed_candidate_hash_matches' (-not [string]::IsNullOrWhiteSpace($currentInstalledHash) -and
        $currentInstalledHash -eq [string]$installedMarker.InstalledSha256) `
        'wss prerequisite: installed executable no longer matches the Install scenario result'
    Add-Criterion 'installed_payload_matches_host_sha256' (-not [string]::IsNullOrWhiteSpace($currentInstalledHash) -and
        $currentInstalledHash -eq [string]$installedMarker.ExpectedInstalledSha256) `
        'wss prerequisite: installed executable SHA256 does not match expected host payload'
    $service = @(Get-MasterDeskServices) | Select-Object -First 1
    Add-Criterion 'service_running' ($null -ne $service -and $service.State -eq 'Running') `
        'wss prerequisite: MasterDesk service is not running'
    if ($script:Failures.Count -gt 0) {
        return 'installed candidate prerequisite failed'
    }

    $processesBefore = @(Get-LabProcesses -CandidatePath $candidatePath)
    $servicePath = Get-ServiceExecutablePath $service
    $serviceHash = Get-FileSha256 $servicePath
    $processAttribution = @(
        $processesBefore | ForEach-Object {
            [ordered]@{
                ProcessId = [int]$_.ProcessId
                ParentProcessId = [int]$_.ParentProcessId
                SessionId = [int]$_.SessionId
                Role = Get-ProcessRole -Process $_ -ServicePid ([int]$service.ProcessId)
                ExecutablePath = [string]$_.ExecutablePath
                ExecutableSha256 = Get-FileSha256 ([string]$_.ExecutablePath)
                CommandLine = [string]$_.CommandLine
            }
        }
    )
    $configEvidence = [ordered]@{}
    foreach ($option in @(
        'allow-websocket', 'force-secure-websocket', 'allow-insecure-tls-fallback',
        'custom-rendezvous-server', 'relay-server'
    )) {
        $query = Invoke-ClientCli -Executable $installedPath `
            -Arguments @('--option', $option) -Prefix ("wss-config-{0}" -f $option)
        $configEvidence[$option] = $query.Output.Trim()
    }
    $idQuery = Invoke-ClientCli -Executable $installedPath -Arguments @('--get-id') -Prefix 'wss-id-before'
    $configEvidence['id'] = $idQuery.Output.Trim()

    $queryBefore = Invoke-ClientCli -Executable $installedPath `
        -Arguments @('--option', 'allow-websocket') -Prefix 'wss-query-before'
    $beforeValue = $queryBefore.Output.Trim()
    Add-Criterion 'websocket_option_readable' ($beforeValue -in @('Y', 'N', '')) `
        ("wss option: unexpected value before test: {0}" -f $queryBefore.Output)
    $oldEnabled = $beforeValue -eq 'Y'
    $restoreValue = if ($oldEnabled) { 'Y' } else { 'N' }
    $summary = 'runtime-check-incomplete'

    try {
        [void](Invoke-ClientCli -Executable $installedPath `
            -Arguments @('--option', 'allow-websocket', 'N') -Prefix 'wss-disable-before-test')
        $queryDisabled = Invoke-ClientCli -Executable $installedPath `
            -Arguments @('--option', 'allow-websocket') -Prefix 'wss-query-disabled'
        Add-Criterion 'websocket_option_disabled_for_transition' `
            ($queryDisabled.Output.Trim() -eq 'N') `
            ("wss option: failed to establish N before transition; output={0}" -f $queryDisabled.Output)
        Start-Sleep -Seconds 5

        $offsets = Get-LogOffsets
        $setResult = Invoke-ClientCli -Executable $installedPath `
            -Arguments @('--option', 'allow-websocket', 'Y') -Prefix 'wss-enable'
        $queryAfter = Invoke-ClientCli -Executable $installedPath `
            -Arguments @('--option', 'allow-websocket') -Prefix 'wss-query-after'
        $settingVerified = $queryAfter.Output.Trim() -eq 'Y'
        Add-Criterion 'websocket_option_enabled' $settingVerified `
            ("wss option: failed to verify allow-websocket=Y; output={0}" -f $queryAfter.Output)

        $restartBeforePid = [int]$service.ProcessId
        $restartCompleted = $false
        try {
            Restart-Service -Name 'MasterDesk' -Force -ErrorAction Stop
            $restartDeadline = [DateTime]::UtcNow.AddSeconds(45)
            do {
                Start-Sleep -Seconds 2
                $restartedService = @(Get-MasterDeskServices) | Select-Object -First 1
                if ($null -ne $restartedService -and $restartedService.State -eq 'Running' -and
                    [int]$restartedService.ProcessId -gt 0 -and
                    [int]$restartedService.ProcessId -ne $restartBeforePid) {
                    $restartCompleted = $true
                    break
                }
            } while ([DateTime]::UtcNow -lt $restartDeadline)
        } catch {
            $script:Evidence['DiagnosticRestartError'] = $_.Exception.Message
        }
        Add-Criterion 'diagnostic_service_restart_with_wss_enabled' $restartCompleted `
            'wss diagnostic: service did not restart with the verified WebSocket option'

        $runtimeEvidence = @()
        $runtimePattern = '(?i)(start tcp:|Direct WebSocket|Client handshake done|RegisterPkResponse|request_pk|UUID_MISMATCH|NOT_DEPLOYED|keep_alive:|WebSocket protocol error|connection reset without closing handshake|rendezvous mediator error|Failed to store\s+config|server restart|Latency of)'
        $deadline = [DateTime]::UtcNow.AddSeconds(50)
        do {
            Start-Sleep -Seconds 3
            $runtimeEvidence = @(
                Get-AppendedLogLines -Offsets $offsets -IncludePattern $runtimePattern
            )
            if (@($runtimeEvidence | Where-Object {
                $_.Text -match '(?i)start tcp: wss://hbbs\.masterdesk\.online/ws/id'
            }).Count -gt 0) {
                break
            }
        } while ([DateTime]::UtcNow -lt $deadline)

        # Observe long enough to capture the normal reconnect interval as well as
        # an immediate protocol failure after the first application exchange.
        if (@($runtimeEvidence | Where-Object {
            $_.Text -match '(?i)start tcp: wss://hbbs\.masterdesk\.online/ws/id'
        }).Count -gt 0) {
            Start-Sleep -Seconds 25
            $runtimeEvidence = @(
                Get-AppendedLogLines -Offsets $offsets -IncludePattern $runtimePattern
            )
        }

        $idRuntime = @($runtimeEvidence | Where-Object {
            $_.Text -match '(?i)start tcp: wss://hbbs\.masterdesk\.online/ws/id'
        })
        $insecureRuntime = @($runtimeEvidence | Where-Object {
            $_.Text -match '(?i)start tcp: ws://hbbs\.masterdesk\.online'
        })
        $directRuntime = @($runtimeEvidence | Where-Object {
            $_.Text -match '(?i)Direct WebSocket connected to hbbs\.masterdesk\.online'
        })
        $handshakeRuntime = @($runtimeEvidence | Where-Object {
            $_.Text -match '(?i)Client handshake done'
        })
        $serverResponseRuntime = @($runtimeEvidence | Where-Object {
            $_.Text -match '(?i)(unknown RegisterPkResponse|request_pk received|UUID_MISMATCH|NOT_DEPLOYED|keep_alive:)'
        })
        $registrationOkRuntime = @($runtimeEvidence | Where-Object {
            $_.Text -match '(?i)(RegisterPkResponse.*\bOK\b|key_confirmed.*true)'
        })
        $configStoreErrors = @($runtimeEvidence | Where-Object {
            $_.Text -match '(?i)Failed to store\s+config'
        })
        $runtimeErrors = @($runtimeEvidence | Where-Object {
            $_.Text -match '(?i)(WebSocket protocol error|connection reset without closing handshake|rendezvous mediator error:.*WebSocket)'
        })

        $tcpId = Test-TcpEndpoint 'hbbs.masterdesk.online' 21116
        $tcpRelay = Test-TcpEndpoint 'hbbr.masterdesk.online' 21117
        $wssId = Test-WssEndpoint 'wss://hbbs.masterdesk.online/ws/id'
        $wssRelay = Test-WssEndpoint 'wss://hbbr.masterdesk.online/ws/relay'
        $dnsId = @()
        $dnsRelay = @()
        try {
            $dnsId = @(Resolve-DnsName -Name 'hbbs.masterdesk.online' -Type A -ErrorAction Stop |
                Where-Object { $_.IPAddress } | Select-Object -ExpandProperty IPAddress -Unique)
        } catch { }
        try {
            $dnsRelay = @(Resolve-DnsName -Name 'hbbr.masterdesk.online' -Type A -ErrorAction Stop |
                Where-Object { $_.IPAddress } | Select-Object -ExpandProperty IPAddress -Unique)
        } catch { }

        Add-Criterion 'candidate_id_wss_runtime_evidence' ($idRuntime.Count -gt 0) `
            'wss runtime: candidate logs contain no new ID connection to wss://hbbs.masterdesk.online/ws/id'
        Add-Criterion 'no_insecure_ws_downgrade' ($insecureRuntime.Count -eq 0) `
            'wss runtime: candidate logs show an insecure ws:// ID connection'
        Add-Criterion 'candidate_wss_stable' ($runtimeErrors.Count -eq 0) `
            'wss runtime: candidate logged a WebSocket connection/protocol error during the stability window'
        Add-Criterion 'id_tcp_endpoint' $tcpId 'wss network: hbbs TCP 21116 is unavailable'
        Add-Criterion 'relay_tcp_endpoint' $tcpRelay 'wss network: hbbr TCP 21117 is unavailable'
        Add-Criterion 'id_wss_endpoint' $wssId 'wss network: ID WSS handshake failed'
        Add-Criterion 'relay_wss_endpoint' $wssRelay 'wss network: relay WSS handshake failed'
        Add-Criterion 'id_dns' ($dnsId.Count -gt 0) 'wss network: hbbs DNS resolution failed'
        Add-Criterion 'relay_dns' ($dnsRelay.Count -gt 0) 'wss network: hbbr DNS resolution failed'
        Add-Criterion 'candidate_tls_websocket_upgrade' ($handshakeRuntime.Count -gt 0) `
            'wss runtime: candidate did not log a completed WebSocket client handshake'
        Add-Criterion 'candidate_registration_confirmed' ($registrationOkRuntime.Count -gt 0) `
            'wss registration: no successful candidate registration response was observed'

        $script:Evidence['InstalledCandidate'] = $installedMarker
        $script:Evidence['CandidateMetadata'] = $candidateMetadata
        $script:Evidence['CandidateGuestSha256'] = $candidateHash
        $script:Evidence['Service'] = $service
        $script:Evidence['ServiceExecutableSha256'] = $serviceHash
        $script:Evidence['ProcessesBefore'] = $processesBefore
        $script:Evidence['ProcessAttribution'] = $processAttribution
        $script:Evidence['Config'] = $configEvidence
        $script:Evidence['OptionBefore'] = $queryBefore.Output
        $script:Evidence['OptionSetExitCode'] = $setResult.ExitCode
        $script:Evidence['OptionAfterEnable'] = $queryAfter.Output
        $script:Evidence['IdRuntimeLines'] = @($idRuntime | Select-Object -First 20)
        $script:Evidence['DirectRuntimeLines'] = @($directRuntime | Select-Object -First 20)
        $script:Evidence['HandshakeRuntimeLines'] = @($handshakeRuntime | Select-Object -First 20)
        $script:Evidence['ServerResponseRuntimeLines'] = @($serverResponseRuntime | Select-Object -First 20)
        $script:Evidence['RegistrationOkRuntimeLines'] = @($registrationOkRuntime | Select-Object -First 20)
        $script:Evidence['ConfigStoreErrorLines'] = @($configStoreErrors | Select-Object -First 20)
        $script:Evidence['RuntimeErrorLines'] = @($runtimeErrors | Select-Object -First 20)
        $script:Evidence['GenericEndpoints'] = [ordered]@{
            IdTcp21116 = $tcpId
            RelayTcp21117 = $tcpRelay
            IdWss = $wssId
            RelayWss = $wssRelay
            IdDns = $dnsId
            RelayDns = $dnsRelay
        }
        $timeline = New-Object System.Collections.Generic.List[object]
        $addTimeline = {
            param([string]$Stage, [string]$Status, [AllowNull()][object]$Line, [string]$Evidence)
            $timestamp = $null
            $file = $null
            if ($null -ne $Line) {
                $timestampValue = Get-LogLineTimestampUtc -Line ([string]$Line.Text)
                if ($timestampValue -ne [DateTime]::MinValue) {
                    $timestamp = $timestampValue.ToString('o')
                }
                $file = [string]$Line.File
            }
            $timeline.Add([ordered]@{
                Stage = $Stage
                Status = $Status
                TimestampUtc = $timestamp
                Evidence = $Evidence
                LogFile = $file
            })
        }
        & $addTimeline 'DNS' $(if($dnsId.Count -gt 0){'PASS'}else{'FAIL'}) $null `
            $(if($dnsId.Count -gt 0){"hbbs resolved: $($dnsId -join ',')"}else{'no A record'})
        & $addTimeline 'TCP' $(if($directRuntime.Count -gt 0){'PASS'}else{'UNKNOWN'}) `
            ($directRuntime | Select-Object -First 1) 'Direct WebSocket socket connected to hbbs:443'
        & $addTimeline 'TLS+WebSocket Upgrade' $(if($handshakeRuntime.Count -gt 0){'PASS'}else{'UNKNOWN'}) `
            ($handshakeRuntime | Select-Object -First 1) 'tungstenite Client handshake done'
        & $addTimeline '/ws/id' $(if($idRuntime.Count -gt 0){'PASS'}else{'FAIL'}) `
            ($idRuntime | Select-Object -First 1) 'candidate selected exact wss://hbbs.masterdesk.online/ws/id'
        & $addTimeline 'MasterDesk first message' $(if($serverResponseRuntime.Count -gt 0){'INDIRECT-PASS'}else{'UNKNOWN'}) `
            ($serverResponseRuntime | Select-Object -First 1) 'a RegisterPkResponse proves a request reached the server; send itself is not logged'
        & $addTimeline 'Server response' $(if($serverResponseRuntime.Count -gt 0){'PASS'}else{'UNKNOWN'}) `
            ($serverResponseRuntime | Select-Object -First 1) `
            $(if($serverResponseRuntime.Count -gt 0){[string]($serverResponseRuntime | Select-Object -First 1).Text}else{'no response line'})
        & $addTimeline 'Registration' $(if($registrationOkRuntime.Count -gt 0){'PASS'}else{'FAIL'}) `
            ($registrationOkRuntime | Select-Object -First 1) `
            $(if($registrationOkRuntime.Count -gt 0){'registration confirmation logged'}else{'no successful registration confirmation'})
        & $addTimeline 'Disconnect' $(if($runtimeErrors.Count -gt 0){'FAIL'}else{'NONE'}) `
            ($runtimeErrors | Select-Object -First 1) `
            $(if($runtimeErrors.Count -gt 0){[string]($runtimeErrors | Select-Object -First 1).Text}else{'no disconnect error'})
        & $addTimeline 'Reconnect' $(if($idRuntime.Count -gt 1){'OBSERVED'}else{'NOT-OBSERVED'}) `
            ($idRuntime | Select-Object -Skip 1 -First 1) `
            $(if($idRuntime.Count -gt 1){"attempts=$($idRuntime.Count)"}else{'no second /ws/id attempt in observation window'})
        & $addTimeline 'Relay WSS' $(if($wssRelay){'GENERIC-PASS'}else{'GENERIC-FAIL'}) $null `
            'generic /ws/relay handshake only; no MasterDesk relay session was opened'
        $script:Evidence['Timeline'] = @($timeline | ForEach-Object { $_ })
        $script:Evidence['DiagnosticRestart'] = [ordered]@{
            OldServicePid = $restartBeforePid
            NewServicePid = if ($restartCompleted) { [int]$restartedService.ProcessId } else { 0 }
        }
        $script:Evidence['RelayRuntime'] = 'Not triggered: generic relay WSS handshake checked; no remote relay session was opened.'
        $endpointCount = @(@($tcpId, $tcpRelay, $wssId, $wssRelay) | Where-Object { $_ }).Count
        $summary = "candidateIdWss={0} directEvidence={1} endpoints={2}/4 relayRuntime=not-triggered" -f `
            ($idRuntime.Count -gt 0), ($directRuntime.Count -gt 0), $endpointCount
    } finally {
        [void](Invoke-ClientCli -Executable $installedPath `
            -Arguments @('--option', 'allow-websocket', $restoreValue) -Prefix 'wss-restore')
        $restoreQuery = Invoke-ClientCli -Executable $installedPath `
            -Arguments @('--option', 'allow-websocket') -Prefix 'wss-query-restored'
        Add-Criterion 'websocket_option_restored' ($restoreQuery.Output.Trim() -eq $restoreValue) `
            ("wss cleanup: failed to restore WebSocket state to {0}; output={1}" -f `
                $restoreValue, $restoreQuery.Output)
        $script:Evidence['OptionRestored'] = $restoreQuery.Output
    }
    return $summary
}

$result = [ordered]@{
    Scenario     = $Scenario
    TimestampUtc = [DateTime]::UtcNow.ToString('o')
    Hostname     = $env:COMPUTERNAME
    SessionId    = [System.Diagnostics.Process]::GetCurrentProcess().SessionId
    Criteria     = [ordered]@{}
    Evidence     = [ordered]@{}
    Summary      = ''
    LogArchive   = $null
    Failures     = @()
    Passed       = $false
}

try {
    if (-not [string]::IsNullOrWhiteSpace($ExpectedHostname)) {
        Add-Criterion 'expected_hostname' ($env:COMPUTERNAME -ieq $ExpectedHostname) `
            ("baseline hostname: expected {0}, found {1}" -f $ExpectedHostname, $env:COMPUTERNAME)
    }
    switch ($Scenario) {
        'Portable'  { $result.Summary = Invoke-PortableScenario }
        'Install'   { $result.Summary = Invoke-InstallScenario }
        'Service'   { $result.Summary = Invoke-ServiceScenario }
        'SingleGui' { $result.Summary = Invoke-SingleGuiScenario }
        'Wss'       { $result.Summary = Invoke-WssScenario }
    }
} catch {
    $script:Failures.Add(("scenario: {0} at line {1}: {2}" -f `
        $_.Exception.Message, $_.InvocationInfo.ScriptLineNumber, $_.InvocationInfo.Line.Trim()))
} finally {
    try {
        if (Save-ScenarioLogs -Destination $LogArchivePath) {
            $result.LogArchive = $LogArchivePath
        }
    } catch {
        $script:Failures.Add(("log collection: {0} at line {1}: {2}" -f `
            $_.Exception.Message, $_.InvocationInfo.ScriptLineNumber, $_.InvocationInfo.Line.Trim()))
    }
    $result.Criteria = $script:Criteria
    if ($script:LogAccessWarnings.Count -gt 0) {
        $script:Evidence['LogAccessWarnings'] = @($script:LogAccessWarnings)
    }
    $result.Evidence = $script:Evidence
    $result.Failures = @($script:Failures)
    $result.Passed = $script:Failures.Count -eq 0
    $parent = Split-Path -Parent $OutputPath
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $result | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $OutputPath -Encoding UTF8
}

exit 0
