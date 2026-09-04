[CmdletBinding()]
param(
    [ValidateRange(0, 9999)]
    [int]$BetaNumber = 0,

    [switch]$RefreshFlutterAot,
    [switch]$SkipTargetedTests
)

$ErrorActionPreference = 'Stop'
$workspace = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$flutterAotInputs = @(
    'flutter/lib',
    'src/bridge_generated.rs',
    'src/bridge_generated.io.rs',
    'src/flutter.rs',
    'src/flutter_ffi.rs'
)
$changedFlutterAotInputs = @(& git -C $workspace status --porcelain=v1 --untracked-files=all -- $flutterAotInputs)
if ($LASTEXITCODE -ne 0) {
    throw 'Failed to inspect Flutter AOT dependencies.'
}
if ($changedFlutterAotInputs.Count -gt 0 -and -not $RefreshFlutterAot) {
    $RefreshFlutterAot = $true
    Write-Output 'Flutter/bridge changes detected; Flutter AOT refresh enabled automatically.'
}
$existingBetas = Get-ChildItem -LiteralPath (Join-Path $workspace 'dist') -File -ErrorAction SilentlyContinue |
    ForEach-Object {
        if ($_.Name -match '-beta-(\d+)-\d{4}-\d{2}-\d{2}-RDS-x86_64\.exe$') {
            [int]$matches[1]
        }
    }
$highestExistingBeta = ($existingBetas | Measure-Object -Maximum).Maximum
if ($null -eq $highestExistingBeta) {
    $highestExistingBeta = 0
}
if ($BetaNumber -eq 0) {
    $BetaNumber = [int]$highestExistingBeta + 1
} elseif ($BetaNumber -le $highestExistingBeta) {
    throw "Beta $BetaNumber is not newer than existing beta $highestExistingBeta. Use the next beta or omit -BetaNumber."
}
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$artifactDirectory = Join-Path $workspace "artifacts\incremental-beta\$timestamp"
New-Item -ItemType Directory -Path $artifactDirectory -Force | Out-Null

if (-not $SkipTargetedTests) {
    & (Join-Path $PSScriptRoot 'Test-TargetedWindowsClient.ps1')
    if ($LASTEXITCODE -ne 0) {
        exit $LASTEXITCODE
    }
}

$buildLog = Join-Path $artifactDirectory "build-beta-$BetaNumber.log"
$buildArguments = @(
    '-NoProfile',
    '-ExecutionPolicy', 'Bypass',
    '-File', (Join-Path $PSScriptRoot 'Build-CustomWindows.ps1'),
    '-IncrementalRustOnly',
    '-SkipVcpkg',
    '-SkipFlutterSetup',
    '-BetaNumber', $BetaNumber
)
if ($RefreshFlutterAot) {
    $buildArguments += '-RefreshFlutterAot'
}

$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
& powershell.exe @buildArguments *> $buildLog
$exitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
if ($exitCode -ne 0) {
    Write-Output "FAIL stage=incremental-beta-$BetaNumber exit=$exitCode log=$buildLog"
    Get-Content -LiteralPath $buildLog -Tail 35
    exit $exitCode
}

$candidate = Get-ChildItem -LiteralPath (Join-Path $workspace 'dist') -File |
    Where-Object Name -Match "-beta-$BetaNumber-\d{4}-\d{2}-\d{2}-RDS-x86_64\.exe$" |
    Sort-Object LastWriteTimeUtc -Descending |
    Select-Object -First 1
if (-not $candidate) {
    Write-Output "FAIL stage=locate-candidate beta=$BetaNumber log=$buildLog"
    exit 1
}

$hash = (Get-FileHash -LiteralPath $candidate.FullName -Algorithm SHA256).Hash
Write-Output "PASS beta=$BetaNumber exe=$($candidate.FullName) sha256=$hash log=$buildLog"
