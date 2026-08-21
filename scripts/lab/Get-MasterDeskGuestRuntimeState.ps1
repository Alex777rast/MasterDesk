[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$OutputPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$service = Get-CimInstance Win32_Service -Filter "Name='MasterDesk'" -ErrorAction SilentlyContinue
$processes = @(Get-Process -Name MasterDesk -ErrorAction SilentlyContinue | ForEach-Object {
    $startTimeUtc = $null
    try { $startTimeUtc = $_.StartTime.ToUniversalTime().ToString('o') } catch {}
    [ordered]@{
        Id = $_.Id
        SessionId = $_.SessionId
        StartTimeUtc = $startTimeUtc
        Responding = $_.Responding
        WorkingSetBytes = $_.WorkingSet64
    }
})
$explorerSessions = @(Get-Process -Name explorer -ErrorAction SilentlyContinue |
    Select-Object -ExpandProperty SessionId -Unique)
$installedExecutable = 'C:\Program Files\MasterDesk\MasterDesk.exe'

function Invoke-MasterDeskCliValue {
    param([string[]]$Arguments, [string]$Name)

    if (-not (Test-Path -LiteralPath $installedExecutable -PathType Leaf)) {
        return $null
    }
    $stdout = "C:\MasterDeskLab\runtime-$Name.stdout.txt"
    $stderr = "C:\MasterDeskLab\runtime-$Name.stderr.txt"
    Remove-Item -LiteralPath $stdout, $stderr -Force -ErrorAction SilentlyContinue
    try {
        $process = Start-Process -FilePath $installedExecutable -ArgumentList $Arguments -PassThru `
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
        return $null
    } catch {
        return $null
    }
}

function Get-ConfigFileMetadata {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [ordered]@{ Path = $Path; Present = $false }
    }
    $item = Get-Item -LiteralPath $Path
    return [ordered]@{
        Path = $Path
        Present = $true
        Length = $item.Length
        LastWriteTimeUtc = $item.LastWriteTimeUtc.ToString('o')
    }
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

$configFiles = @(
    (Join-Path $env:APPDATA 'MasterDesk\config\MasterDesk.toml'),
    (Join-Path $env:APPDATA 'MasterDesk\config\MasterDesk2.toml'),
    'C:\Windows\System32\config\systemprofile\AppData\Roaming\MasterDesk\config\MasterDesk.toml',
    'C:\Windows\System32\config\systemprofile\AppData\Roaming\MasterDesk\config\MasterDesk2.toml'
)

[ordered]@{
    TimestampUtc = [DateTime]::UtcNow.ToString('o')
    ComputerName = $env:COMPUTERNAME
    InstalledDirectoryPresent = Test-Path -LiteralPath 'C:\Program Files\MasterDesk' -PathType Container
    InstalledExePresent = Test-Path -LiteralPath $installedExecutable -PathType Leaf
    Identity = [ordered]@{
        Id = Invoke-MasterDeskCliValue @('--get-id') 'get-id'
        Version = Invoke-MasterDeskCliValue @('--version') 'version'
        BuildDate = Invoke-MasterDeskCliValue @('--build-date') 'build-date'
        StopService = Invoke-MasterDeskCliValue @('--option', 'stop-service') 'stop-service'
        ConfigFiles = @($configFiles | ForEach-Object { Get-ConfigFileMetadata $_ })
    }
    Service = if ($null -eq $service) { $null } else {
        [ordered]@{
            Name = [string]$service.Name
            State = [string]$service.State
            StartMode = [string]$service.StartMode
            StartName = [string]$service.StartName
            ProcessId = [int]$service.ProcessId
        }
    }
    SafeMode = Get-SafeModeStatus
    InteractiveSessionIds = $explorerSessions
    Processes = $processes
} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $OutputPath -Encoding UTF8
