[CmdletBinding()]
param(
    [ValidateSet('Probe', 'Install', 'Restart')]
    [string]$Action = 'Probe',

    [ValidateSet('A', 'B', 'All')]
    [string]$Vm = 'All',

    [string]$ConfigPath = 'D:\Vms\MasterDeskLab\lab-config.psd1',

    [string]$HostAddress,

    [string]$WindowsMcpVersion = '0.8.5',

    [string]$UvVersion = '0.12.5',

    [switch]$RotateToken
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$runId = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
$artifactRoot = Join-Path $repoRoot "artifacts\gui-runs\$runId\mcp-setup"
$guestPassword = [Environment]::GetEnvironmentVariable('MASTERDESK_LAB_PASSWORD')
New-Item -ItemType Directory -Path $artifactRoot -Force | Out-Null

function ConvertTo-SafeText([AllowNull()][object]$Value) {
    $text = if ($null -eq $Value) { '' } else { [string]$Value }
    if ($guestPassword) { $text = $text.Replace($guestPassword, '<redacted>') }
    foreach ($name in @('MASTERDESK_VM_A_MCP_TOKEN', 'MASTERDESK_VM_B_MCP_TOKEN')) {
        $token = [Environment]::GetEnvironmentVariable($name)
        if ($token) { $text = $text.Replace($token, '<redacted>') }
    }
    return $text
}

function Invoke-Vmrun {
    param([hashtable]$Config, [object[]]$Arguments, [string]$LogPath)

    $actual = @('-T', 'ws', '-gu', [string]$Config.GuestUser, '-gp', $guestPassword) +
        $Arguments
    $safe = @('-T', 'ws', '-gu', [string]$Config.GuestUser, '-gp', '<redacted>') +
        $Arguments
    $output = @(& $Config.Vmrun @actual 2>&1)
    $code = $LASTEXITCODE
    @("command=vmrun $($safe -join ' ')", "exitCode=$code", 'output:') +
        @($output | ForEach-Object { ConvertTo-SafeText $_ }) |
        Set-Content -LiteralPath $LogPath -Encoding UTF8
    return [pscustomobject]@{ ExitCode = $code; Output = $output }
}

function Test-TcpPort([string]$Address, [int]$Port) {
    $client = New-Object Net.Sockets.TcpClient
    try {
        $connect = $client.ConnectAsync($Address, $Port)
        return $connect.Wait(3000) -and $client.Connected
    } catch { return $false } finally { $client.Dispose() }
}

function Get-HostVmwareAddress {
    $addresses = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
        Where-Object { $_.IPAddress -like '192.168.7.*' -and $_.IPAddress -notlike '*.14' -and
            $_.IPAddress -notlike '*.15' } | Select-Object -ExpandProperty IPAddress)
    if ($addresses.Count -ne 1) {
        throw "Expected one host address on 192.168.7.0/24; found $($addresses.Count)."
    }
    return $addresses[0]
}

function Get-VerifiedUvExe {
    $cacheRoot = Join-Path (Split-Path -Parent $ConfigPath) "cache\uv\$UvVersion"
    $zipPath = Join-Path $cacheRoot 'uv-x86_64-pc-windows-msvc.zip'
    $uvPath = Join-Path $cacheRoot 'uv.exe'
    $baseUri = "https://github.com/astral-sh/uv/releases/download/$UvVersion"
    New-Item -ItemType Directory -Path $cacheRoot -Force | Out-Null

    $checksumResponse = Invoke-WebRequest -UseBasicParsing `
        -Uri "$baseUri/uv-x86_64-pc-windows-msvc.zip.sha256"
    $checksumText = if ($checksumResponse.Content -is [byte[]]) {
        [Text.Encoding]::UTF8.GetString($checksumResponse.Content).Trim()
    } else { ([string]$checksumResponse.Content).Trim() }
    $expected = ($checksumText -split '\s+')[0].ToUpperInvariant()
    if ($expected -notmatch '^[0-9A-F]{64}$') { throw 'Invalid uv release checksum.' }
    $download = -not (Test-Path -LiteralPath $zipPath -PathType Leaf)
    if (-not $download) {
        $download = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash -ne $expected
    }
    if ($download) {
        Invoke-WebRequest -UseBasicParsing `
            -Uri "$baseUri/uv-x86_64-pc-windows-msvc.zip" -OutFile $zipPath
    }
    $actual = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash
    if ($actual -ne $expected) { throw 'Downloaded uv archive checksum mismatch.' }

    if (-not (Test-Path -LiteralPath $uvPath -PathType Leaf)) {
        $extractRoot = Join-Path $artifactRoot 'uv-extract'
        Expand-Archive -LiteralPath $zipPath -DestinationPath $extractRoot -Force
        $extracted = Get-ChildItem -LiteralPath $extractRoot -Filter 'uv.exe' -Recurse |
            Select-Object -First 1
        if (-not $extracted) { throw 'uv.exe was not found in the verified archive.' }
        Copy-Item -LiteralPath $extracted.FullName -Destination $uvPath -Force
    }
    [ordered]@{
        Version = $UvVersion
        ArchiveSha256 = $actual
        ExeSha256 = (Get-FileHash -LiteralPath $uvPath -Algorithm SHA256).Hash
    } | ConvertTo-Json | Set-Content -LiteralPath (
        Join-Path $artifactRoot 'uv-attribution.json'
    ) -Encoding UTF8
    return $uvPath
}

if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
    throw "Lab config not found: $ConfigPath"
}
if (-not $guestPassword) { throw 'MASTERDESK_LAB_PASSWORD is not set.' }
$config = Import-PowerShellDataFile -LiteralPath $ConfigPath
if (-not $HostAddress) { $HostAddress = Get-HostVmwareAddress }
$uvExe = if ($Action -eq 'Install') { Get-VerifiedUvExe } else { $null }
$definitions = @(
    [pscustomobject]@{ Label = 'A'; Vmx = [string]$config.VmA; Address = [string]$config.VmAAddress; TokenEnv = 'MASTERDESK_VM_A_MCP_TOKEN' },
    [pscustomobject]@{ Label = 'B'; Vmx = [string]$config.VmB; Address = [string]$config.VmBAddress; TokenEnv = 'MASTERDESK_VM_B_MCP_TOKEN' }
)
if ($Vm -ne 'All') { $definitions = @($definitions | Where-Object Label -eq $Vm) }

$tokens = @{}
foreach ($definition in $definitions) {
    $prefix = Join-Path $artifactRoot "vm-$($definition.Label)"
    $guestTokenImportPath = 'C:\MasterDeskLab\windows-mcp-token.import'
    $directory = Invoke-Vmrun -Config $config -Arguments @(
        'directoryExistsInGuest', $definition.Vmx, 'C:\MasterDeskLab'
    ) -LogPath "$prefix-directory-exists.log"
    if ($directory.ExitCode -ne 0) {
        $create = Invoke-Vmrun -Config $config -Arguments @(
            'createDirectoryInGuest', $definition.Vmx, 'C:\MasterDeskLab'
        ) -LogPath "$prefix-directory-create.log"
        if ($create.ExitCode -ne 0) { throw "Guest directory failed for VM $($definition.Label)." }
    }

    $copy = Invoke-Vmrun -Config $config -Arguments @(
        'copyFileFromHostToGuest', $definition.Vmx,
        (Join-Path $PSScriptRoot 'Install-MasterDeskWindowsMcpGuest.ps1'),
        'C:\MasterDeskLab\Install-MasterDeskWindowsMcpGuest.ps1'
    ) -LogPath "$prefix-helper-copy.log"
    if ($copy.ExitCode -ne 0) { throw "Helper copy failed for VM $($definition.Label)." }

    if ($Action -eq 'Install') {
        $uvCopy = Invoke-Vmrun -Config $config -Arguments @(
            'copyFileFromHostToGuest', $definition.Vmx, $uvExe,
            'C:\MasterDeskLab\uv.exe'
        ) -LogPath "$prefix-uv-copy.log"
        if ($uvCopy.ExitCode -ne 0) { throw "uv copy failed for VM $($definition.Label)." }

        $existingToken = [Environment]::GetEnvironmentVariable($definition.TokenEnv, 'User')
        if (-not $RotateToken -and $existingToken -match '^[0-9a-f]{64}$') {
            $hostTokenImportPath = Join-Path $env:TEMP (
                "masterdesk-windows-mcp-import-$runId-$($definition.Label).tmp"
            )
            try {
                Set-Content -LiteralPath $hostTokenImportPath -Value $existingToken `
                    -NoNewline -Encoding Ascii
                $tokenImportCopy = Invoke-Vmrun -Config $config -Arguments @(
                    'copyFileFromHostToGuest', $definition.Vmx,
                    $hostTokenImportPath, $guestTokenImportPath
                ) -LogPath "$prefix-token-import-copy.log"
                if ($tokenImportCopy.ExitCode -ne 0) {
                    throw "Token import transfer failed for VM $($definition.Label)."
                }
            } finally {
                Remove-Item -LiteralPath $hostTokenImportPath -Force -ErrorAction SilentlyContinue
                $existingToken = $null
            }
        }
    }

    $guestResult = "C:\MasterDeskLab\windows-mcp-$runId.json"
    $arguments = @(
        'runProgramInGuest', $definition.Vmx,
        'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe',
        '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
        '-File', 'C:\MasterDeskLab\Install-MasterDeskWindowsMcpGuest.ps1',
        '-Action', $Action, '-OutputPath', $guestResult,
        '-HostAddress', $HostAddress, '-WindowsMcpVersion', $WindowsMcpVersion
    )
    if ($RotateToken) { $arguments += '-RotateToken' }
    $run = Invoke-Vmrun -Config $config -Arguments $arguments -LogPath "$prefix-run.log"
    if ($Action -eq 'Install') {
        [void](Invoke-Vmrun -Config $config -Arguments @(
            'deleteFileInGuest', $definition.Vmx, $guestTokenImportPath
        ) -LogPath "$prefix-token-import-delete.log")
    }
    $hostResult = "$prefix-result.json"
    $copyResult = Invoke-Vmrun -Config $config -Arguments @(
        'copyFileFromGuestToHost', $definition.Vmx, $guestResult, $hostResult
    ) -LogPath "$prefix-result-copy.log"
    if ($copyResult.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $hostResult)) {
        throw "Result copy failed for VM $($definition.Label)."
    }
    $result = Get-Content -LiteralPath $hostResult -Raw | ConvertFrom-Json
    if ($run.ExitCode -ne 0 -or -not $result.Passed) {
        $detail = if ($result.PSObject.Properties.Name -contains 'Error') {
            [string]$result.Error
        } else { 'post-install state validation failed' }
        throw "Windows-MCP $Action failed for VM $($definition.Label): $detail"
    }

    if ($Action -eq 'Install') {
        $hostTokenPath = Join-Path $env:TEMP "masterdesk-windows-mcp-$runId-$($definition.Label).tmp"
        try {
            $tokenCopy = Invoke-Vmrun -Config $config -Arguments @(
                'copyFileFromGuestToHost', $definition.Vmx,
                'C:\MasterDeskLab\windows-mcp-token.tmp', $hostTokenPath
            ) -LogPath "$prefix-token-copy.log"
            if ($tokenCopy.ExitCode -ne 0) { throw "Token transfer failed for VM $($definition.Label)." }
            $token = (Get-Content -LiteralPath $hostTokenPath -Raw).Trim()
            if ($token -notmatch '^[0-9a-f]{64}$') { throw "Invalid token format for VM $($definition.Label)." }
            [Environment]::SetEnvironmentVariable($definition.TokenEnv, $token, 'User')
            Set-Item -LiteralPath "Env:$($definition.TokenEnv)" -Value $token
            $tokens[$definition.Label] = $token
        } finally {
            Remove-Item -LiteralPath $hostTokenPath -Force -ErrorAction SilentlyContinue
            [void](Invoke-Vmrun -Config $config -Arguments @(
                'deleteFileInGuest', $definition.Vmx,
                'C:\MasterDeskLab\windows-mcp-token.tmp'
            ) -LogPath "$prefix-token-delete.log")
        }
    }

    Write-Output ("PASS action={0} vm={1} task={2} listener={3} interactive={4} firewall={5} artifacts={6}" -f `
        $Action, $definition.Label, $result.State.TaskState, $result.State.ListenerCount,
        $result.State.InteractiveProcess, $result.State.FirewallRulePresent, $artifactRoot)
}

if ($Action -eq 'Install' -and $tokens.Count -eq 2 -and $tokens.A -eq $tokens.B) {
    throw 'The two VM bearer tokens must be different.'
}

foreach ($definition in $definitions) {
    if ($Action -in @('Install', 'Restart') -and
            -not (Test-TcpPort -Address $definition.Address -Port 8000)) {
        throw "Windows-MCP TCP port is unavailable for VM $($definition.Label)."
    }
}

Write-Output ("PASS action={0} vm={1} host={2} version={3} artifacts={4}" -f `
    $Action, $Vm, $HostAddress, $WindowsMcpVersion, $artifactRoot)
