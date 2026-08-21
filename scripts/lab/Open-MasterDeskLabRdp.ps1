[CmdletBinding()]
param(
    [ValidateSet('A', 'B', 'All')]
    [string]$Vm = 'All',

    [string]$ConfigPath = 'D:\Vms\MasterDeskLab\lab-config.psd1',

    [switch]$NoLaunch
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$artifactRoot = Join-Path $repoRoot 'artifacts\lab\rdp'
New-Item -ItemType Directory -Path $artifactRoot -Force | Out-Null

function Test-TcpPort {
    param(
        [string]$Address,
        [int]$Port,
        [int]$TimeoutMilliseconds = 3000
    )

    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $task = $client.ConnectAsync($Address, $Port)
        if (-not $task.Wait($TimeoutMilliseconds)) {
            return $false
        }
        return $client.Connected
    } catch {
        return $false
    } finally {
        $client.Dispose()
    }
}

if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
    throw "Lab configuration file was not found: $ConfigPath"
}
$config = Import-PowerShellDataFile -LiteralPath $ConfigPath
foreach ($key in @('VmAName', 'VmBName', 'VmAComputerName', 'VmBComputerName',
        'VmAAddress', 'VmBAddress', 'RdpUser')) {
    if (-not $config.ContainsKey($key) -or [string]::IsNullOrWhiteSpace([string]$config[$key])) {
        throw "Missing required RDP lab configuration key: $key"
    }
}

$definitions = @(
    [pscustomobject]@{
        Label = 'A'; Name = [string]$config.VmAName
        ComputerName = [string]$config.VmAComputerName; Address = [string]$config.VmAAddress
    },
    [pscustomobject]@{
        Label = 'B'; Name = [string]$config.VmBName
        ComputerName = [string]$config.VmBComputerName; Address = [string]$config.VmBAddress
    }
)
if ($Vm -ne 'All') {
    $definitions = @($definitions | Where-Object Label -eq $Vm)
}

foreach ($definition in $definitions) {
    if (-not (Test-TcpPort -Address $definition.Address -Port 3389)) {
        throw "RDP is unavailable for VM $($definition.Label) at $($definition.Address):3389"
    }

    $rdpPath = Join-Path $artifactRoot ("{0}.rdp" -f $definition.Name)
    $userName = "{0}\{1}" -f $definition.ComputerName, [string]$config.RdpUser
    $windowPosition = if ($definition.Label -eq 'A') {
        'winposstr:s:0,1,0,0,920,760'
    } else {
        'winposstr:s:0,1,920,0,1840,760'
    }
    @(
        'screen mode id:i:1'
        'use multimon:i:0'
        'session bpp:i:32'
        'desktopwidth:i:900'
        'desktopheight:i:700'
        'smart sizing:i:1'
        'dynamic resolution:i:1'
        $windowPosition
        "full address:s:$($definition.Address)"
        "username:s:$userName"
        'prompt for credentials on client:i:1'
        'promptcredentialonce:i:0'
        'authentication level:i:2'
        'enablecredsspsupport:i:1'
        'redirectclipboard:i:1'
        'redirectprinters:i:0'
        'redirectcomports:i:0'
        'redirectsmartcards:i:0'
        'drivestoredirect:s:'
        'autoreconnection enabled:i:1'
    ) | Set-Content -LiteralPath $rdpPath -Encoding Unicode

    if (Select-String -LiteralPath $rdpPath -Pattern '^password' -Quiet) {
        throw "Refusing to launch an RDP file containing a password: $rdpPath"
    }

    if ($NoLaunch) {
        Write-Output ("PASS action=OpenRdp vm={0} mode=generated address={1} file={2}" -f `
            $definition.Label, $definition.Address, $rdpPath)
        continue
    }

    $process = Start-Process -FilePath "$env:SystemRoot\System32\mstsc.exe" `
        -ArgumentList @($rdpPath) -PassThru
    [ordered]@{
        Vm = $definition.Label
        Name = $definition.Name
        Address = $definition.Address
        ProcessId = $process.Id
        StartedUtc = $process.StartTime.ToUniversalTime().ToString('o')
        RdpPath = $rdpPath
    } | ConvertTo-Json | Set-Content -LiteralPath (
        Join-Path $artifactRoot ("{0}.process.json" -f $definition.Name)
    ) -Encoding UTF8
    Write-Output ("PASS action=OpenRdp vm={0} mode=launched address={1} pid={2} file={3}" -f `
        $definition.Label, $definition.Address, $process.Id, $rdpPath)
}
