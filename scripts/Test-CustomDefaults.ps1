[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$ProjectRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$VcpkgRoot = Join-Path $ProjectRoot '.tools\vcpkg'
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
    'https://api.masterdesk.online/masterdesk/version/latest',
    'MasterDesk-1.4.9-RDS-x86_64.exe',
    '1.4.9-6'
)) {
    if ($customDefaults -notmatch [regex]::Escape($expectedValue)) {
        throw "Compiled MasterDesk defaults are missing $expectedValue."
    }
}
if ($customDefaults -notmatch 'migrate_previous_network_settings') {
    throw 'Previous MasterDesk network settings are not migrated to the new domain.'
}
if ($customDefaults -notmatch 'DEFAULT_IMAGE_QUALITY:\s*&str\s*=\s*"balanced"') {
    throw 'Default image quality must be "balanced".'
}

$flutterCommon = Get-Content -LiteralPath (Join-Path $ProjectRoot 'flutter\lib\common.dart') -Raw
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

$portablePacker = Get-Content -LiteralPath (Join-Path $ProjectRoot 'libs\portable\src\main.rs') -Raw
if ($portablePacker -notmatch 'masterdesk_release_runs_portable_by_default') {
    throw 'The MasterDesk release does not have a portable-by-default regression test.'
}
if ($portablePacker -match 'name\.starts_with\("masterdesk-"\)') {
    throw 'The portable packer still treats a MasterDesk release as an automatic installer.'
}

$coreMain = Get-Content -LiteralPath (Join-Path $ProjectRoot 'src\core_main.rs') -Raw
if ($coreMain -notmatch 'should_update_from_masterdesk_package') {
    throw 'An installed MasterDesk client is not routed to the in-place update path.'
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
& $pythonCommand.Source -m unittest discover `
    -s (Join-Path $ProjectRoot 'deploy\masterdesk-api') `
    -p 'test_*.py' `
    -v
if ($LASTEXITCODE -ne 0) {
    throw "Update-manifest tests failed with exit code $LASTEXITCODE."
}

Push-Location $ProjectRoot
try {
    & (Join-Path $CargoBin 'cargo.exe') test `
        --locked `
        --offline `
        --release `
        --features 'hwcodec,vram,flutter' `
        custom_defaults `
        --lib `
        -- `
        --nocapture
    if ($LASTEXITCODE -ne 0) {
        throw "Custom defaults tests failed with exit code $LASTEXITCODE."
    }

    foreach ($testName in @(
        'masterdesk_release_name_is_a_portable_or_update_package',
        'clean_computer_runs_release_as_portable_client',
        'installed_computer_routes_release_to_update',
        'parses_only_the_expected_release_checksum'
    )) {
        & (Join-Path $CargoBin 'cargo.exe') test `
            --locked `
            --offline `
            --release `
            --features 'hwcodec,vram,flutter' `
            $testName `
            --lib `
            -- `
            --nocapture
        if ($LASTEXITCODE -ne 0) {
            throw "MasterDesk updater test $testName failed with exit code $LASTEXITCODE."
        }
    }

    & (Join-Path $CargoBin 'cargo.exe') test `
        --locked `
        --offline `
        --manifest-path (Join-Path $ProjectRoot 'libs\portable\Cargo.toml') `
        masterdesk_release_runs_portable_by_default `
        -- `
        --nocapture
    if ($LASTEXITCODE -ne 0) {
        throw "Portable-by-default test failed with exit code $LASTEXITCODE."
    }

} finally {
    Pop-Location
}
