[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('A', 'B')]
    [string]$Vm,

    [Parameter(Mandatory)]
    [ValidateSet('Screenshot', 'Snapshot', 'Click', 'Type', 'Shortcut', 'Wait', 'WaitFor', 'App', 'Process')]
    [string]$Tool,

    [string]$ArgumentsJson = '{}',

    [Parameter(Mandatory)]
    [string]$OutputDirectory,

    [Parameter(Mandatory)]
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]*$')]
    [string]$ArtifactName,

    [string]$ConfigPath = 'D:\Vms\MasterDeskLab\lab-config.psd1'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
Add-Type -AssemblyName System.Net.Http

function ConvertFrom-McpBody([string]$Body) {
    if ([string]::IsNullOrWhiteSpace($Body)) { return $null }
    $trimmed = $Body.Trim()
    if ($trimmed.StartsWith('{')) { return $trimmed | ConvertFrom-Json }
    foreach ($line in $Body -split "`r?`n") {
        if ($line.StartsWith('data:')) {
            $data = $line.Substring(5).Trim()
            if ($data.StartsWith('{')) { return $data | ConvertFrom-Json }
        }
    }
    throw 'MCP response did not contain a JSON or SSE data object.'
}

function Send-McpRequest {
    param(
        [Net.Http.HttpClient]$Client,
        [string]$Url,
        [string]$Token,
        [object]$Payload,
        [AllowNull()][string]$SessionId,
        [AllowNull()][string]$ProtocolVersion
    )

    $request = New-Object Net.Http.HttpRequestMessage([Net.Http.HttpMethod]::Post, $Url)
    $request.Content = New-Object Net.Http.StringContent(
        ($Payload | ConvertTo-Json -Depth 12 -Compress),
        [Text.Encoding]::UTF8,
        'application/json'
    )
    [void]$request.Headers.TryAddWithoutValidation('Accept', 'application/json, text/event-stream')
    $request.Headers.Authorization = New-Object Net.Http.Headers.AuthenticationHeaderValue(
        'Bearer', $Token
    )
    if ($SessionId) { [void]$request.Headers.TryAddWithoutValidation('Mcp-Session-Id', $SessionId) }
    if ($ProtocolVersion) {
        [void]$request.Headers.TryAddWithoutValidation('MCP-Protocol-Version', $ProtocolVersion)
    }
    try {
        $response = $Client.SendAsync($request).GetAwaiter().GetResult()
        try {
            $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            if (-not $response.IsSuccessStatusCode) {
                throw "MCP request failed with HTTP $([int]$response.StatusCode)."
            }
            $responseSession = $null
            if ($response.Headers.Contains('Mcp-Session-Id')) {
                $responseSession = @($response.Headers.GetValues('Mcp-Session-Id'))[0]
            }
            return [pscustomobject]@{ Body = $body; SessionId = $responseSession }
        } finally { $response.Dispose() }
    } finally { $request.Dispose() }
}

if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
    throw "Lab configuration file was not found: $ConfigPath"
}
$config = Import-PowerShellDataFile -LiteralPath $ConfigPath
$address = if ($Vm -eq 'A') { [string]$config.VmAAddress } else { [string]$config.VmBAddress }
$tokenEnv = "MASTERDESK_VM_${Vm}_MCP_TOKEN"
$token = [Environment]::GetEnvironmentVariable($tokenEnv, 'User')
if ($token -notmatch '^[0-9a-f]{64}$') { throw "Host user token is missing or invalid for VM $Vm." }
try {
    $arguments = $ArgumentsJson | ConvertFrom-Json
} catch {
    throw "ArgumentsJson is not valid JSON: $($_.Exception.Message)"
}

New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$handler = New-Object Net.Http.HttpClientHandler
$handler.UseProxy = $false
$client = New-Object Net.Http.HttpClient($handler)
$client.Timeout = [TimeSpan]::FromSeconds(60)
$url = "http://${address}:8000/mcp"
try {
    $initialize = Send-McpRequest -Client $client -Url $url -Token $token -Payload ([ordered]@{
        jsonrpc = '2.0'; id = 1; method = 'initialize'
        params = [ordered]@{
            protocolVersion = '2025-06-18'; capabilities = @{}
            clientInfo = @{ name = 'masterdesk-lab-tool'; version = '1.0' }
        }
    }) -SessionId $null -ProtocolVersion $null
    $initializeJson = ConvertFrom-McpBody $initialize.Body
    $protocolVersion = [string]$initializeJson.result.protocolVersion
    $sessionId = [string]$initialize.SessionId
    [void](Send-McpRequest -Client $client -Url $url -Token $token -Payload ([ordered]@{
        jsonrpc = '2.0'; method = 'notifications/initialized'; params = @{}
    }) -SessionId $sessionId -ProtocolVersion $protocolVersion)

    $called = Send-McpRequest -Client $client -Url $url -Token $token -Payload ([ordered]@{
        jsonrpc = '2.0'; id = 2; method = 'tools/call'
        params = [ordered]@{ name = $Tool; arguments = $arguments }
    }) -SessionId $sessionId -ProtocolVersion $protocolVersion
    $calledJson = ConvertFrom-McpBody $called.Body
    if ($calledJson.PSObject.Properties['error']) {
        throw "MCP tool returned JSON-RPC error $($calledJson.error.code)."
    }
    if ($calledJson.result.PSObject.Properties['isError'] -and [bool]$calledJson.result.isError) {
        throw "MCP tool $Tool reported an error."
    }

    $texts = New-Object Collections.Generic.List[string]
    $images = New-Object Collections.Generic.List[string]
    $imageNumber = 0
    foreach ($item in @($calledJson.result.content)) {
        if ([string]$item.type -eq 'text') {
            $texts.Add([string]$item.text)
        } elseif ([string]$item.type -eq 'image') {
            $imageNumber++
            $extension = if ([string]$item.mimeType -eq 'image/jpeg') { 'jpg' } else { 'png' }
            $suffix = if ($imageNumber -eq 1) { '' } else { "-$imageNumber" }
            $imagePath = Join-Path $OutputDirectory ("$ArtifactName-$Vm$suffix.$extension")
            [IO.File]::WriteAllBytes($imagePath, [Convert]::FromBase64String([string]$item.data))
            $images.Add($imagePath)
        }
    }
    $hasRequiredImage = $Tool -notin @('Screenshot', 'Snapshot') -or $images.Count -gt 0
    $reportPath = Join-Path $OutputDirectory ("$ArtifactName-$Vm.json")
    [ordered]@{
        Passed = $hasRequiredImage
        TimestampUtc = [DateTime]::UtcNow.ToString('o')
        Vm = $Vm
        Address = $address
        Tool = $Tool
        Text = @($texts)
        Images = @($images | ForEach-Object { Split-Path -Leaf $_ })
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $reportPath -Encoding UTF8
    if (-not $hasRequiredImage) {
        throw "MCP tool $Tool returned no image."
    }
    Write-Output ("PASS action=McpTool vm={0} tool={1} images={2} artifact={3}" -f `
        $Vm, $Tool, $images.Count, $reportPath)
} finally {
    $token = $null
    $client.Dispose()
    $handler.Dispose()
}
