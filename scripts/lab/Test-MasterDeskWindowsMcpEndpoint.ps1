[CmdletBinding()]
param(
    [ValidateSet('A', 'B', 'All')]
    [string]$Vm = 'All',

    [string]$ConfigPath = 'D:\Vms\MasterDeskLab\lab-config.psd1',

    [string]$OutputDirectory
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
Add-Type -AssemblyName System.Net.Http

$requiredTools = @(
    'Screenshot', 'Snapshot', 'Click', 'Type', 'Shortcut',
    'Wait', 'WaitFor', 'App', 'Process'
)
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
if (-not $OutputDirectory) {
    $OutputDirectory = Join-Path $repoRoot (
        'artifacts\gui-runs\{0}\mcp-probe' -f (Get-Date -Format 'yyyyMMdd-HHmmss-fff')
    )
}
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null

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
        [AllowNull()][string]$Token,
        [object]$Payload,
        [AllowNull()][string]$SessionId,
        [AllowNull()][string]$ProtocolVersion
    )

    $request = New-Object Net.Http.HttpRequestMessage([Net.Http.HttpMethod]::Post, $Url)
    $body = $Payload | ConvertTo-Json -Depth 8 -Compress
    $request.Content = New-Object Net.Http.StringContent(
        $body, [Text.Encoding]::UTF8, 'application/json'
    )
    [void]$request.Headers.TryAddWithoutValidation('Accept', 'application/json, text/event-stream')
    if ($Token) {
        $request.Headers.Authorization = New-Object Net.Http.Headers.AuthenticationHeaderValue(
            'Bearer', $Token
        )
    }
    if ($SessionId) { [void]$request.Headers.TryAddWithoutValidation('Mcp-Session-Id', $SessionId) }
    if ($ProtocolVersion) {
        [void]$request.Headers.TryAddWithoutValidation('MCP-Protocol-Version', $ProtocolVersion)
    }
    try {
        $response = $Client.SendAsync($request).GetAwaiter().GetResult()
        try {
            $responseBody = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            $responseSession = $null
            if ($response.Headers.Contains('Mcp-Session-Id')) {
                $responseSession = @($response.Headers.GetValues('Mcp-Session-Id'))[0]
            }
            return [pscustomobject]@{
                StatusCode = [int]$response.StatusCode
                IsSuccess = $response.IsSuccessStatusCode
                Body = $responseBody
                SessionId = $responseSession
            }
        } finally { $response.Dispose() }
    } finally { $request.Dispose() }
}

function Test-Endpoint([pscustomobject]$Definition) {
    $token = [Environment]::GetEnvironmentVariable($Definition.TokenEnv, 'User')
    if ($token -notmatch '^[0-9a-f]{64}$') {
        throw "Host user token is missing or invalid for VM $($Definition.Label)."
    }
    $requestedUrl = "http://$($Definition.Address):8000/mcp/"
    $url = "http://$($Definition.Address):8000/mcp"
    $handler = New-Object Net.Http.HttpClientHandler
    $handler.UseProxy = $false
    $client = New-Object Net.Http.HttpClient($handler)
    $client.Timeout = [TimeSpan]::FromSeconds(20)
    try {
        $initializePayload = [ordered]@{
            jsonrpc = '2.0'; id = 1; method = 'initialize'
            params = [ordered]@{
                protocolVersion = '2025-06-18'; capabilities = @{}
                clientInfo = @{ name = 'masterdesk-lab-probe'; version = '1.0' }
            }
        }
        $unauthorized = Send-McpRequest -Client $client -Url $url -Token $null `
            -Payload $initializePayload -SessionId $null -ProtocolVersion $null
        if ($unauthorized.StatusCode -notin @(401, 403)) {
            throw "Unauthenticated request returned HTTP $($unauthorized.StatusCode)."
        }

        $initialized = Send-McpRequest -Client $client -Url $url -Token $token `
            -Payload $initializePayload -SessionId $null -ProtocolVersion $null
        if (-not $initialized.IsSuccess) {
            throw "MCP initialize returned HTTP $($initialized.StatusCode)."
        }
        $initializeJson = ConvertFrom-McpBody -Body $initialized.Body
        if (-not $initializeJson.result.protocolVersion) { throw 'MCP protocol version is missing.' }
        $protocolVersion = [string]$initializeJson.result.protocolVersion
        $sessionId = [string]$initialized.SessionId

        $notification = [ordered]@{
            jsonrpc = '2.0'; method = 'notifications/initialized'; params = @{}
        }
        $ready = Send-McpRequest -Client $client -Url $url -Token $token `
            -Payload $notification -SessionId $sessionId -ProtocolVersion $protocolVersion
        if (-not $ready.IsSuccess) {
            throw "MCP initialized notification returned HTTP $($ready.StatusCode)."
        }

        $listed = Send-McpRequest -Client $client -Url $url -Token $token `
            -Payload ([ordered]@{ jsonrpc = '2.0'; id = 2; method = 'tools/list'; params = @{} }) `
            -SessionId $sessionId -ProtocolVersion $protocolVersion
        if (-not $listed.IsSuccess) { throw "MCP tools/list returned HTTP $($listed.StatusCode)." }
        $listJson = ConvertFrom-McpBody -Body $listed.Body
        $tools = @($listJson.result.tools | Select-Object -ExpandProperty name | Sort-Object)
        $expected = @($requiredTools | Sort-Object)
        if (($tools -join '|') -ne ($expected -join '|')) {
            throw "Unexpected MCP tools for VM $($Definition.Label): $($tools -join ',')"
        }

        $report = [ordered]@{
            Passed = $true
            Vm = $Definition.Label
            Address = $Definition.Address
            Url = $url
            RequestedUrl = $requestedUrl
            CheckedUtc = [DateTime]::UtcNow.ToString('o')
            UnauthenticatedStatus = $unauthorized.StatusCode
            ProtocolVersion = $protocolVersion
            Tools = $tools
        }
        $report | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (
            Join-Path $OutputDirectory "vm-$($Definition.Label).json"
        ) -Encoding UTF8
        Write-Output ("PASS action=McpProbe vm={0} authReject={1} protocol={2} tools={3}" -f `
            $Definition.Label, $unauthorized.StatusCode, $protocolVersion, $tools.Count)
    } finally {
        $client.Dispose()
        $handler.Dispose()
    }
}

$config = Import-PowerShellDataFile -LiteralPath $ConfigPath
$definitions = @(
    [pscustomobject]@{ Label = 'A'; Address = [string]$config.VmAAddress; TokenEnv = 'MASTERDESK_VM_A_MCP_TOKEN' },
    [pscustomobject]@{ Label = 'B'; Address = [string]$config.VmBAddress; TokenEnv = 'MASTERDESK_VM_B_MCP_TOKEN' }
)
if ($Vm -ne 'All') { $definitions = @($definitions | Where-Object Label -eq $Vm) }
foreach ($definition in $definitions) { Test-Endpoint -Definition $definition }
Write-Output "PASS action=McpProbe vm=$Vm artifacts=$OutputDirectory"
