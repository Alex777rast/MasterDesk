[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$ProjectRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$VcpkgRoot = if ($env:MASTERDESK_VCPKG_ROOT) {
    [System.IO.Path]::GetFullPath($env:MASTERDESK_VCPKG_ROOT)
} else {
    Join-Path $ProjectRoot '.tools\vcpkg'
}
$CargoBin = Join-Path $env:USERPROFILE '.cargo\bin'
$LlvmBin = if ($env:MASTERDESK_LLVM_BIN) {
    [System.IO.Path]::GetFullPath($env:MASTERDESK_LLVM_BIN)
} else {
    $clangCommand = Get-Command clang.exe -ErrorAction SilentlyContinue
    if ($clangCommand) {
        [System.IO.Path]::GetDirectoryName($clangCommand.Source)
    } else {
        'C:\Program Files\LLVM\bin'
    }
}

function Invoke-NativeChecked {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter()][string[]]$Arguments = @(),
        [Parameter(Mandatory)][string]$FailureMessage
    )

    # Python unittest and Cargo legitimately write progress to stderr. When a
    # caller redirects this script to an artifact, Windows PowerShell otherwise
    # promotes those lines to terminating NativeCommandError records.
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        & $FilePath @Arguments
        $nativeExitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    if ($nativeExitCode -ne 0) {
        throw "$FailureMessage with exit code $nativeExitCode."
    }
}
$VsDevCmd = if ($env:MASTERDESK_VSDEVCMD) {
    [System.IO.Path]::GetFullPath($env:MASTERDESK_VSDEVCMD)
} else {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    $detectedVsDevCmd = if (Test-Path -LiteralPath $vswhere) {
        & $vswhere `
            -latest `
            -products '*' `
            -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
            -find 'Common7\Tools\VsDevCmd.bat' |
            Select-Object -First 1
    }
    if ($detectedVsDevCmd) {
        $detectedVsDevCmd
    } else {
        'C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\Common7\Tools\VsDevCmd.bat'
    }
}

$environmentLines = & $env:COMSPEC /s /c "`"$VsDevCmd`" -arch=x64 -host_arch=x64 >nul && set"
if ($LASTEXITCODE -ne 0) {
    throw 'VsDevCmd.bat failed.'
}
foreach ($line in $environmentLines) {
    $separator = $line.IndexOf('=')
    if ($separator -gt 0) {
        [Environment]::SetEnvironmentVariable(
            $line.Substring(0, $separator),
            $line.Substring($separator + 1),
            'Process'
        )
    }
}

$env:LIBCLANG_PATH = $LlvmBin
$env:VCPKG_ROOT = $VcpkgRoot
$env:VCPKG_INSTALLED_ROOT = Join-Path $VcpkgRoot 'installed'
$env:VCPKG_DEFAULT_TRIPLET = 'x64-windows-static'
$env:VCPKG_DEFAULT_HOST_TRIPLET = 'x64-windows-static'
$env:Path = "$CargoBin;$LlvmBin;$env:Path"

$windowsInstaller = Get-Content -LiteralPath (Join-Path $ProjectRoot 'src\platform\windows.rs') -Raw
$installStart = $windowsInstaller.IndexOf('pub fn install_me(')
$installEnd = $windowsInstaller.IndexOf('pub fn run_after_install()', $installStart)
if ($installStart -lt 0 -or $installEnd -le $installStart) {
    throw 'Could not locate the initial Windows installer implementation.'
}
$initialInstaller = $windowsInstaller.Substring($installStart, $installEnd - $installStart)
if ($initialInstaller -notmatch '\{copy_exe\}\s*\{rename_exe\}') {
    throw 'Initial installation does not rename the packaged rustdesk.exe to the branded executable.'
}
if ($initialInstaller -notmatch 'rename_exe\s*=\s*rename_exe_cmd\(&src_exe,\s*&path\)\?') {
    throw 'Initial installation is missing the rename_exe command binding.'
}

$serverModel = Get-Content -LiteralPath (Join-Path $ProjectRoot 'flutter\lib\models\server_model.dart') -Raw
if ($serverModel -notmatch 'showCmWindow\(forceForeground:\s*!client\.authorized\)') {
    throw 'Unauthorized incoming connections are not configured to foreground the approval window.'
}

$serverPage = Get-Content -LiteralPath (Join-Path $ProjectRoot 'flutter\lib\desktop\pages\server_page.dart') -Raw
if ($serverPage -notmatch "text:\s*'Dismiss'") {
    throw 'The incoming connection rejection button is not configured as Dismiss.'
}

$clientSource = Get-Content -LiteralPath (Join-Path $ProjectRoot 'src\client.rs') -Raw
if ($clientSource -notmatch 'custom_defaults::DEFAULT_KEYBOARD_MODE') {
    throw 'New peer sessions do not use the compiled keyboard-mode default.'
}

$customDefaults = Get-Content -LiteralPath (Join-Path $ProjectRoot 'src\custom_defaults.rs') -Raw
foreach ($expectedValue in @(
    'hbbs.masterdesk.online',
    'hbbr.masterdesk.online',
    '1.4.9-10',
    'https://api.github.com/repos/Alex777rast/MasterDesk/releases/latest'
)) {
    if ($customDefaults -notmatch [regex]::Escape($expectedValue)) {
        throw "Compiled MasterDesk defaults are missing $expectedValue."
    }
}
if ($customDefaults -notmatch 'masterdesk_update_asset_version' -or
    $customDefaults -notmatch 'MasterDesk-' -or
    $customDefaults -notmatch '-beta-' -or
    $customDefaults -notmatch '-RDS-x86_64\.exe') {
    throw 'The GitHub updater does not enforce the dated MasterDesk beta asset name.'
}
if ($customDefaults -notmatch 'migrate_previous_network_settings') {
    throw 'Previous MasterDesk network settings are not migrated to the new domain.'
}
if ($customDefaults -notmatch 'DEFAULT_IMAGE_QUALITY:\s*&str\s*=\s*"balanced"') {
    throw 'Default image quality must be "balanced".'
}
if ($customDefaults -notmatch 'is_protected_network_option' -or
    $customDefaults -notmatch 'OBFUSCATED_API_SERVER' -or
    $customDefaults -notmatch 'OBFUSCATED_SERVER_PUBLIC_KEY' -or
    $customDefaults -notmatch 'OPTION_FORCE_SECURE_WEBSOCKET') {
    throw 'MasterDesk API/Key are not protected as internal compiled settings.'
}
if ($customDefaults -match 'https://api\.masterdesk\.online') {
    throw 'The MasterDesk API URL must not be stored as plain text in the client source.'
}

$websocketSource = Get-Content -LiteralPath `
    (Join-Path $ProjectRoot 'libs\hbb_common\src\websocket.rs') -Raw
if ($websocketSource -notmatch 'OPTION_FORCE_SECURE_WEBSOCKET' -or
    $websocketSource -notmatch 'client_async_tls_with_config' -or
    $websocketSource -notmatch 'connect_direct_server') {
    throw 'MasterDesk WSS is not forced through the direct Windows route.'
}

$uiInterface = Get-Content -LiteralPath (Join-Path $ProjectRoot 'src\ui_interface.rs') -Raw
if ($uiInterface -notmatch '\.filter\(\|\(key, _\)\| !crate::custom_defaults::is_protected_network_option\(key\)\)' -or
    $uiInterface -notmatch 'm\.retain\(\|key, _\| !crate::custom_defaults::is_protected_network_option\(key\)\)') {
    throw 'Protected API/Key settings are not filtered from the native UI bridge.'
}

$flutterCommon = Get-Content -LiteralPath (Join-Path $ProjectRoot 'flutter\lib\common.dart') -Raw
if ($flutterCommon -notmatch 'isMasterDeskClient' -or
    $flutterCommon -notmatch "apiServer\s*=\s*isMasterDeskClient\s*\?\s*''" -or
    $flutterCommon -notmatch "key\s*=\s*isMasterDeskClient\s*\?\s*''") {
    throw 'Protected API/Key settings are not removed from the Flutter model.'
}

$rendezvousProto = Get-Content -LiteralPath `
    (Join-Path $ProjectRoot 'libs\hbb_common\protos\rendezvous.proto') -Raw
foreach ($securityMessage in @('DeviceLease', 'IdentityRotation', 'RelayAuth', 'RelayTicket')) {
    if ($rendezvousProto -notmatch "message\s+$securityMessage") {
        throw "Rendezvous protocol is missing $securityMessage."
    }
}

$messageProto = Get-Content -LiteralPath `
    (Join-Path $ProjectRoot 'libs\hbb_common\protos\message.proto') -Raw
if ($messageProto -notmatch 'message\s+KeyboardLayout' -or
    $messageProto -notmatch 'KeyboardLayout\s+keyboard_layout\s*=\s*39') {
    throw 'The legacy KeyboardLayout wire field must remain for protocol compatibility.'
}
$inputModel = Get-Content -LiteralPath (Join-Path $ProjectRoot 'flutter\lib\models\input_model.dart') -Raw
$inputModifierUtils = Get-Content -LiteralPath `
    (Join-Path $ProjectRoot 'flutter\lib\models\input_modifier_utils.dart') -Raw
$nativeKeyboard = Get-Content -LiteralPath (Join-Path $ProjectRoot 'src\keyboard.rs') -Raw
if ($inputModel -notmatch 'shouldPassWindowsModifierToPlatform' -or
    $inputModel -notmatch 'KeyEventResult\.skipRemainingHandlers' -or
    $inputModifierUtils -notmatch 'PhysicalKeyboardKey\.altLeft' -or
    $inputModifierUtils -notmatch 'PhysicalKeyboardKey\.controlLeft' -or
    $inputModifierUtils -notmatch 'PhysicalKeyboardKey\.shiftLeft' -or
    $nativeKeyboard -notmatch 'should_pass_windows_modifier_to_platform' -or
    $nativeKeyboard -notmatch 'is_press\s*&&\s*!pass_modifier_to_platform') {
    throw 'Windows modifiers are not forwarded to both the peer and local platform for both input sources.'
}
$serverConnection = Get-Content -LiteralPath `
    (Join-Path $ProjectRoot 'src\server\connection.rs') -Raw
$clientIoLoop = Get-Content -LiteralPath (Join-Path $ProjectRoot 'src\client\io_loop.rs') -Raw
if ($serverConnection -match 'should_sync_keyboard_layout_after_key' -or
    $clientIoLoop -notmatch 'Ignored peer keyboard layout' -or
    $clientIoLoop -match 'apply_keyboard_layout_klid') {
    throw 'The stale peer-KLID feedback path can still override the controller layout.'
}

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

if ($flutterCommon -notmatch 'kCheckSoftwareUpdateFinish') {
    throw 'The Flutter main process is not registered for update notifications.'
}

$desktopHome = Get-Content -LiteralPath (Join-Path $ProjectRoot 'flutter\lib\desktop\pages\desktop_home_page.dart') -Raw
if ($desktopHome -notmatch 'if \(updateUrl\.isNotEmpty && !isCardClosed\)') {
    throw 'The main window does not render the MasterDesk update card.'
}
if ($desktopHome -notmatch 'Uri\.parse\(updateUrl\)') {
    throw 'The MasterDesk update card does not open the manifest release URL.'
}
if ($desktopHome -notmatch 'isMasterDesk\s*&&\s*isWindows') {
    throw 'The installed MasterDesk client is not allowed to launch an interactive update.'
}
if ($desktopHome -notmatch 'handleUpdate\(updateUrl\)') {
    throw 'The MasterDesk update card does not launch the integrated updater.'
}
if ($desktopHome -notmatch '!bind\.mainIsInstalled\(\)' -or
    $desktopHome -notmatch 'bind\.mainGotoInstall\(\)') {
    throw 'The portable MasterDesk client does not offer installation from the main window.'
}
if ($desktopHome -notmatch 'mainIsInstalledLowerVersion\(\)' -or
    $desktopHome -notmatch '"Update"' -or
    $desktopHome -notmatch 'bind\.mainUpdateMe\(\)') {
    throw 'The portable MasterDesk client does not expose the explicit GUI Update button.'
}
if ($customDefaults -notmatch 'BUILD_BETA_NUMBER' -or
    $customDefaults -notmatch 'CUSTOM_BUILD_DATE' -or
    $customDefaults -notmatch 'installed_build_is_older') {
    throw 'Numeric beta/date identity or local installed-version comparison is missing.'
}
$buildScript = Get-Content -LiteralPath (Join-Path $ProjectRoot 'scripts\Build-CustomWindows.ps1') -Raw
if ($buildScript -notmatch 'MasterDesk-\$BuildBaseVersion-beta-\$BetaNumber-\$BuildDateForFileName-RDS-x86_64\.exe' -or
    $buildScript -notmatch 'MASTERDESK_BUILD_BETA_NUMBER' -or
    $buildScript -notmatch 'MASTERDESK_BUILD_DATE') {
    throw 'The Windows build script does not enforce the beta/date EXE identity.'
}
if ($buildScript -match '(?i)-install\.exe') {
    throw 'The Windows build script must not create a MasterDesk -install.exe.'
}
if ($buildScript -notmatch 'RefreshFlutterAot' -or
    $buildScript -notmatch 'tool_backend\.bat' -or
    $buildScript -notmatch "@\('windows-x64', 'Release'\)" -or
    $buildScript -notmatch "-Filter 'app\.so'") {
    throw 'The targeted Dart UI path does not refresh only the cached Flutter runner.'
}
if ($buildScript -notmatch 'Test-FlutterReleaseAssetBundle' -or
    $buildScript -notmatch 'AssetManifest\.bin' -or
    $buildScript -notmatch 'FontManifest\.json' -or
    $buildScript -notmatch 'MaterialIcons-Regular\.otf') {
    throw 'The Windows build script does not reject an incomplete Flutter asset bundle.'
}

$portablePacker = Get-Content -LiteralPath (Join-Path $ProjectRoot 'libs\portable\src\main.rs') -Raw
if ($portablePacker -notmatch 'masterdesk_release_runs_portable_by_default') {
    throw 'The MasterDesk release does not have a portable-by-default regression test.'
}
if ($portablePacker -match 'name\.starts_with\("masterdesk-"\)') {
    throw 'The portable packer still treats a MasterDesk release as an automatic installer.'
}

$coreMain = Get-Content -LiteralPath (Join-Path $ProjectRoot 'src\core_main.rs') -Raw
foreach ($forbiddenStartupUpdate in @(
    'should_update_from_masterdesk_package',
    'is_installed_masterdesk_package_launch',
    'confirm_message_box',
    'launch_installed_application'
)) {
    if ($coreMain -match [regex]::Escape($forbiddenStartupUpdate)) {
        throw "Portable startup still contains the automatic update path $forbiddenStartupUpdate."
    }
}
if ($coreMain -notmatch 'is_cur_exe_the_installed\(\)' -or
    $coreMain -notmatch 'remove_var\(crate::common::PORTABLE_APPNAME_RUNTIME_ENV_KEY\)') {
    throw 'The installed executable does not clear the inherited portable package marker.'
}
if ($coreMain -notmatch 'should_use_installed_gui_compat' -or
    $coreMain -notmatch 'Portable GUI will use the installed MasterDesk server') {
    throw 'Portable MasterDesk can start a second server instead of attaching to the installed GUI compatibility IPC.'
}

$ipcSource = Get-Content -LiteralPath (Join-Path $ProjectRoot 'src\ipc.rs') -Raw
if ($ipcSource -notmatch 'POSTFIX_GUI_COMPAT' -or
    $ipcSource -notmatch 'gui_compat_config_query_allowed' -or
    $ipcSource -notmatch 'gui_compat_does_not_expose_machine_password_verifier' -or
    $ipcSource -notmatch 'sanitized_gui_compat_options') {
    throw 'The installed GUI compatibility IPC is missing its versioned route or security allowlist coverage.'
}

$commonSource = Get-Content -LiteralPath (Join-Path $ProjectRoot 'src\common.rs') -Raw
if ($commonSource -notmatch 'should_check_software_update_for_runtime' -or
    $commonSource -notmatch 'is_masterdesk\s*&&\s*!crate::platform::is_cur_exe_the_installed\(\)' -or
    $commonSource -notmatch 'Skipping the automatic MasterDesk update request') {
    throw 'Portable MasterDesk startup can still make an automatic update-manifest request.'
}

$windowsPlatform = Get-Content -LiteralPath (Join-Path $ProjectRoot 'src\platform\windows.rs') -Raw
if ($windowsPlatform -notmatch 'Installation completed; exiting the portable IPC owner') {
    throw 'The portable installer does not release the IPC pipe after installation.'
}
if ($coreMain -notmatch '--wait-for-portable' -or
    $windowsPlatform -notmatch 'wait_for_process_exit' -or
    $windowsPlatform -notmatch 'wait_for_current_process') {
    throw 'The installed GUI does not wait for the portable installer to release IPC.'
}
$earlyHandoff = $coreMain.IndexOf('wait_for_portable_handoff_before_initialization();')
$globalInit = $coreMain.IndexOf('crate::common::global_init()')
if ($earlyHandoff -lt 0 -or $globalInit -lt 0 -or $earlyHandoff -gt $globalInit) {
    throw 'The portable handoff wait must happen before global initialization and IPC bootstrap.'
}
if ($windowsPlatform -notmatch 'main_window_sessions\.dedup\(\)' -or
    $windowsPlatform -notmatch 'tray_sessions\.dedup\(\)') {
    throw 'The updater does not deduplicate Windows sessions before restoring GUI and tray processes.'
}
if ($coreMain -notmatch 'Update succeeded; closing the portable updater for GUI handoff' -or
    $coreMain -match 'text1\(&translate\(text\)\)') {
    throw 'The successful updater path may remain alive while displaying a notification.'
}
$runnerMain = Get-Content -LiteralPath (Join-Path $ProjectRoot 'flutter\windows\runner\main.cpp') -Raw
if ($runnerMain -notmatch '"--wait-for-portable"') {
    throw 'The Flutter runner does not allow the installed handoff process to start.'
}
$desktopHome = Get-Content -LiteralPath (Join-Path $ProjectRoot 'flutter\lib\desktop\pages\desktop_home_page.dart') -Raw
if ($desktopHome -notmatch 'Expanded\(\s*child: SingleChildScrollView\(') {
    throw 'The GUI update card can be clipped below the non-scrollable left pane.'
}
if ($windowsPlatform -notmatch 'application_display_version\(\)' -or
    $windowsPlatform -notmatch 'build_display_version\(\)' -or
    $windowsPlatform -notmatch 'CUSTOM_BUILD_DATE') {
    throw 'The installed MasterDesk build number is not persisted for update comparisons.'
}
if ($windowsPlatform -notmatch 'No previous main window found; opening the updated application' -or
    $windowsPlatform -notmatch 'vec!\["--wait-for-portable", &updater_pid\]') {
    throw 'The updater does not wait for the portable process before reopening the main MasterDesk window.'
}

$directServer = Get-Content -LiteralPath (Join-Path $ProjectRoot 'libs\hbb_common\src\direct_server.rs') -Raw
$socketClient = Get-Content -LiteralPath (Join-Path $ProjectRoot 'libs\hbb_common\src\socket_client.rs') -Raw
if ($directServer -notmatch 'pub fn resolved_target\(' -or
    $socketClient -notmatch 'compiled IPv4 alias') {
    throw 'Direct-server hostnames are not resolved through the compiled IPv4 alias.'
}

$flutterFfi = Get-Content -LiteralPath (Join-Path $ProjectRoot 'src\flutter_ffi.rs') -Raw
if ($flutterFfi -notmatch 'verify_masterdesk_update_package') {
    throw 'The interactive updater does not verify the downloaded MasterDesk package.'
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
Invoke-NativeChecked $pythonCommand.Source @(
    '-m', 'unittest', 'discover',
    '-s', (Join-Path $ProjectRoot 'deploy\masterdesk-api'),
    '-p', 'test_*.py',
    '-v'
) 'Update-manifest tests failed'

Push-Location $ProjectRoot
try {
    Invoke-NativeChecked (Join-Path $CargoBin 'cargo.exe') @(
        'test',
        '--locked',
        '--offline',
        '--release',
        '--features', 'hwcodec,vram,flutter',
        'custom_defaults',
        '--lib',
        '--',
        '--nocapture'
    ) 'Custom defaults tests failed'

    foreach ($testName in @(
        'masterdesk_release_name_is_a_portable_or_update_package',
        'portable_masterdesk_skips_automatic_update_check',
        'parses_only_the_expected_release_checksum'
    )) {
        Invoke-NativeChecked (Join-Path $CargoBin 'cargo.exe') @(
            'test',
            '--locked',
            '--offline',
            '--release',
            '--features', 'hwcodec,vram,flutter',
            $testName,
            '--lib',
            '--',
            '--nocapture'
        ) "MasterDesk updater test $testName failed"
    }

    foreach ($portableTestName in @(
        'masterdesk_release_runs_portable_by_default',
        'generated_package_has_versioned_extraction_timestamp'
    )) {
        Invoke-NativeChecked (Join-Path $CargoBin 'cargo.exe') @(
            'test',
            '--locked',
            '--offline',
            '--manifest-path', (Join-Path $ProjectRoot 'libs\portable\Cargo.toml'),
            $portableTestName,
            '--',
            '--nocapture'
        ) "Portable regression test $portableTestName failed"
    }

} finally {
    Pop-Location
}
