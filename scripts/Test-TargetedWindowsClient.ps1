[CmdletBinding()]
param(
    [string[]]$Filter = @(
        'windows_layout_',
        'test_normalized_keyboard_layout_klid',
        'test_keyboard_layout_uses_secure_input_desktop',
        'test_safe_mode_network_plan',
        'test_windows_safe_mode_metric',
        'test_bcd_safeboot_detection',
        'restart_remote_device_message_',
        'peer_features_json_',
        'test_temporary_password_gui_lease_',
        'permanent_password',
        'machine_payload_',
        'gui_compat_',
        'relay_device_id_',
        'online_state_response_',
        'websocket_heartbeat_'
    ),
    [switch]$CheckOnly,
    [switch]$SkipCheck,
    [switch]$IncludeAliasPersistence
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Initialize-MasterDeskBuildEnvironment.ps1')
$workspace = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$artifactDirectory = Join-Path $workspace "artifacts\targeted-windows-client\$timestamp"
New-Item -ItemType Directory -Path $artifactDirectory -Force | Out-Null

if ($IncludeAliasPersistence -and 'peer_alias_sidecar_' -notin $Filter) {
    $Filter += 'peer_alias_sidecar_'
}

if (-not $env:VCPKG_ROOT -and $env:MASTERDESK_VCPKG_ROOT) {
    $env:VCPKG_ROOT = $env:MASTERDESK_VCPKG_ROOT
}
if (-not $env:LIBCLANG_PATH -and $env:MASTERDESK_LLVM_BIN) {
    $env:LIBCLANG_PATH = $env:MASTERDESK_LLVM_BIN
}
$env:VCPKGRS_DYNAMIC = '0'

function Invoke-LoggedCargo {
    param(
        [Parameter(Mandatory)] [string]$Stage,
        [Parameter(Mandatory)] [string[]]$Arguments
    )

    $log = Join-Path $artifactDirectory "$Stage.log"
    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    & cargo @Arguments *> $log
    $exitCode = $LASTEXITCODE
    $ErrorActionPreference = $previousErrorActionPreference
    if ($exitCode -eq 0) {
        Write-Output "PASS stage=$Stage log=$log"
        return
    }

    Write-Output "FAIL stage=$Stage exit=$exitCode log=$log"
    Get-Content -LiteralPath $log -Tail 30
    exit $exitCode
}

Push-Location $workspace
try {
    if (-not $SkipCheck) {
        Invoke-LoggedCargo -Stage 'check-flutter' -Arguments @('check', '--features', 'flutter')
    }
    if (-not $CheckOnly) {
        foreach ($testFilter in $Filter) {
            $safeName = $testFilter -replace '[^A-Za-z0-9_.-]', '_'
            Invoke-LoggedCargo -Stage "test-$safeName" -Arguments @(
                'test', '-p', 'rustdesk', '--features', 'flutter', '--lib',
                $testFilter, '--', '--test-threads=1'
            )
        }
    }
} finally {
    Pop-Location
}
