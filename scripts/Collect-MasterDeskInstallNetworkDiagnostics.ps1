[CmdletBinding()]
param()

# Read-only, Windows PowerShell 5.1 compatible. Never prints config contents,
# passwords, key material, command lines or raw application logs.
$ErrorActionPreference = 'Continue'
$dll = 'C:\Program Files\MasterDesk\libmasterdesk.dll'
$service = Get-CimInstance Win32_Service -Filter "Name='MasterDesk'" -ErrorAction SilentlyContinue
$processes = @(Get-CimInstance Win32_Process -Filter "Name='MasterDesk.exe'" -ErrorAction SilentlyContinue | ForEach-Object {
    $role = if ($_.CommandLine -match '(?:^|\s)--service(?:\s|$)') {'service'} elseif ($_.CommandLine -match '(?:^|\s)--server(?:\s|$)') {'server'} elseif ($_.CommandLine -match '(?:^|\s)--tray(?:\s|$)') {'tray'} else {'gui/other'}
    [pscustomobject]@{Id=$_.ProcessId;Session=$_.SessionId;Role=$role}
})
$roots = @((Join-Path $env:APPDATA 'MasterDesk\log'), 'C:\Windows\ServiceProfiles\LocalService\AppData\Roaming\MasterDesk\log', 'C:\Windows\System32\config\systemprofile\AppData\Roaming\MasterDesk\log')
$patterns = [ordered]@{
    IdentityDecryptFailure = 'Failed to load the machine-bound device identity|Existing key pair is unavailable'
    RegistrationSigningFailure = 'Cannot sign the MasterDesk device lease: invalid local private key'
    HardwareIdentityUnavailable = 'SMBIOS.*unavailable|Machine UID for local secret protection is empty'
    ImportFailure = 'Failed to (read installation source identity|import primary config|import secondary config)'
    PrimaryConfigImported = 'Primary config imported'
    ConnectionFailure = 'Connection timed out|Connection refused|failed to connect'
}
$signals = [ordered]@{}
foreach ($name in $patterns.Keys) {$signals[$name] = 0}
$read = 0
$unreadable = 0
foreach ($root in $roots) {
    if (-not (Test-Path -LiteralPath $root -ErrorAction SilentlyContinue)) {$unreadable++; continue}
    foreach ($file in @(Get-ChildItem -LiteralPath $root -Filter '*CURRENT.log' -Recurse -File -ErrorAction SilentlyContinue)) {
        try {
            $content = Get-Content -LiteralPath $file.FullName -Raw -ErrorAction Stop
            foreach ($name in $patterns.Keys) {$signals[$name] += [regex]::Matches([string]$content, $patterns[$name], [Text.RegularExpressions.RegexOptions]::IgnoreCase).Count}
            $read++
        } catch {$unreadable++}
    }
}
[ordered]@{
    AtUtc = [DateTime]::UtcNow.ToString('o')
    ReadOnly = $true
    Is64BitOS = [Environment]::Is64BitOperatingSystem
    InstalledCoreSha256 = if (Test-Path -LiteralPath $dll) {(Get-FileHash -LiteralPath $dll -Algorithm SHA256).Hash} else {$null}
    Service = if ($service) {$service | Select-Object State,StartMode,StartName,ProcessId} else {$null}
    Processes = $processes
    CurrentLogsRead = $read
    UnavailableLogsOrRoots = $unreadable
    LogSignals = $signals
} | ConvertTo-Json -Depth 5
