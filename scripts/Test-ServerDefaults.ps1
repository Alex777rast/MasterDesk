[CmdletBinding()]
param([string]$RepositoryRoot=(Join-Path $PSScriptRoot '..'))
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$ProjectRoot=[IO.Path]::GetFullPath($RepositoryRoot)
# Server-only, read-only checks. The complete defaults gate calls this by
# default; public client builds explicitly select -ClientOnly instead.
$serverPatch = Join-Path $ProjectRoot 'deploy\masterdesk-server\masterdesk-server-a7736be.patch'
$serverPatchScript = Join-Path $ProjectRoot 'deploy\masterdesk-server\Apply-MasterDeskServerPatch.ps1'
$caddyExample = Join-Path $ProjectRoot 'deploy\masterdesk-server\Caddyfile.example'
foreach ($serverArtifact in @($serverPatch, $serverPatchScript, $caddyExample)) {
    if (-not (Test-Path -LiteralPath $serverArtifact)) {
        throw "Server security artifact is missing: $serverArtifact"
    }
}
$serverPatchSource = Get-Content -LiteralPath $serverPatch -Raw
foreach ($serverSecurityMarker in @(
    'require-relay-ticket',
    'relay_ed25519',
    'CONSUMED_TICKETS',
    'MAX_ACTIVE_PER_IP',
    'DEVICE_LEASE_TIMEOUT'
)) {
    if ($serverPatchSource -notmatch [regex]::Escape($serverSecurityMarker)) {
        throw "Server security patch is missing $serverSecurityMarker."
    }
}
if ($serverPatchSource -notmatch 'if\s+!relay_security_required\(\)\s*\{\s*\+?\s*return true;') {
    throw 'Server compatibility mode can still reject partially upgraded clients.'
}
$updateManifest = Get-Content -LiteralPath (Join-Path $ProjectRoot 'deploy\masterdesk-api\latest.json') -Raw |
    ConvertFrom-Json
if ($updateManifest.version -notmatch '^\d+\.\d+\.\d+-\d+$') {
    throw 'The MasterDesk update manifest version is not in the expected numeric format.'
}
if ($updateManifest.url -notmatch '^https://') {
    throw 'The MasterDesk update manifest release URL must use HTTPS.'
}
$pythonCommand = Get-Command python.exe -ErrorAction SilentlyContinue
if (-not $pythonCommand) {
    throw 'Python is required to test the update-manifest refresh service.'
}
$previousErrorActionPreference=$ErrorActionPreference
try {
    $ErrorActionPreference='Continue'
    & $pythonCommand.Source -m unittest discover -s (Join-Path $ProjectRoot 'deploy\masterdesk-api') -p 'test_*.py' -v
    $nativeExitCode=$LASTEXITCODE
} finally {
    $ErrorActionPreference=$previousErrorActionPreference
}
if($nativeExitCode -ne 0){throw "Update-manifest tests failed with exit code $nativeExitCode."}
Write-Output 'SERVER_DEFAULTS=PASS (static patch guards and update-manifest service tests; not a production canary)'
