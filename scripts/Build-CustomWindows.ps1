[CmdletBinding()]
param(
    [switch]$SkipVcpkg,
    [switch]$SkipFlutterSetup
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$ProjectRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$ToolsRoot = Join-Path $ProjectRoot '.tools'
$FlutterRoot = if ($env:MASTERDESK_FLUTTER_ROOT) {
    [System.IO.Path]::GetFullPath($env:MASTERDESK_FLUTTER_ROOT)
} else {
    Join-Path $ToolsRoot 'flutter'
}
$FlutterExe = Join-Path $FlutterRoot 'bin\flutter.bat'
$VcpkgRoot = Join-Path $ToolsRoot 'vcpkg'
$VcpkgExe = Join-Path $VcpkgRoot 'vcpkg.exe'
$PythonExe = if ($env:MASTERDESK_PYTHON) {
    [System.IO.Path]::GetFullPath($env:MASTERDESK_PYTHON)
} else {
    $localPython = Join-Path $env:LOCALAPPDATA 'Programs\Python\Python312\python.exe'
    if (Test-Path -LiteralPath $localPython) {
        $localPython
    } else {
        $pythonCommand = Get-Command python.exe -ErrorAction SilentlyContinue
        if (-not $pythonCommand) {
            throw 'Python 3.12 was not found. Set MASTERDESK_PYTHON to python.exe.'
        }
        $pythonCommand.Source
    }
}
$CargoBin = Join-Path $env:USERPROFILE '.cargo\bin'
$CargoExe = Join-Path $CargoBin 'cargo.exe'
$RustupExe = Join-Path $CargoBin 'rustup.exe'
$CargoExpandExe = Join-Path $CargoBin 'cargo-expand.exe'
$FlutterRustBridgeCodegen = Join-Path $CargoBin 'flutter_rust_bridge_codegen.exe'
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
$ExpectedVcpkgCommit = '120deac3062162151622ca4860575a33844ba10b'
$FlutterEngineZip = Join-Path $ToolsRoot 'windows-x64-release.zip'
$FlutterEngineExtract = Join-Path $ToolsRoot 'custom-flutter-engine'
$FlutterEngineUrl = 'https://github.com/rustdesk/engine/releases/download/main/windows-x64-release.zip'
$FlutterEngineTarget = Join-Path $FlutterRoot 'bin\cache\artifacts\engine\windows-x64-release'
$ReleaseDirectory = Join-Path $ProjectRoot 'flutter\build\windows\x64\runner\Release'
$DistDirectory = Join-Path $ProjectRoot 'dist'
$OutputExe = Join-Path $DistDirectory 'MasterDesk-1.4.9-RDS-x86_64.exe'

function Invoke-Checked {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter()][string[]]$Arguments = @()
    )

    Write-Host "`n> $FilePath $($Arguments -join ' ')"
    & $FilePath @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed with exit code $LASTEXITCODE`: $FilePath"
    }
}

function Import-VisualStudioEnvironment {
    if (-not (Test-Path -LiteralPath $VsDevCmd)) {
        throw "Visual Studio developer environment not found: $VsDevCmd"
    }

    $environmentLines = & $env:COMSPEC /s /c "`"$VsDevCmd`" -arch=x64 -host_arch=x64 >nul && set"
    if ($LASTEXITCODE -ne 0) {
        throw 'VsDevCmd.bat failed.'
    }
    foreach ($line in $environmentLines) {
        $separator = $line.IndexOf('=')
        if ($separator -gt 0) {
            $name = $line.Substring(0, $separator)
            $value = $line.Substring($separator + 1)
            [Environment]::SetEnvironmentVariable($name, $value, 'Process')
        }
    }
}

function Initialize-Flutter {
    if (-not (Test-Path -LiteralPath $FlutterExe)) {
        throw "Flutter SDK not found: $FlutterExe"
    }

    Invoke-Checked $FlutterExe @('config', '--no-analytics', '--enable-windows-desktop')
    Invoke-Checked $FlutterExe @('precache', '--windows')

    $patchPath = Join-Path $ProjectRoot '.github\patches\flutter_3.24.4_dropdown_menu_enableFilter.diff'
    & git -C $FlutterRoot apply --check $patchPath 2>$null
    if ($LASTEXITCODE -eq 0) {
        Invoke-Checked 'git' @('-C', $FlutterRoot, 'apply', $patchPath)
    } else {
        & git -C $FlutterRoot apply --reverse --check $patchPath 2>$null
        if ($LASTEXITCODE -ne 0) {
            throw 'The upstream Flutter dropdown patch can neither be applied nor identified as already applied.'
        }
        Write-Host 'Flutter dropdown patch is already applied.'
    }

    if (-not (Test-Path -LiteralPath $FlutterEngineZip)) {
        Invoke-Checked (Join-Path $env:SystemRoot 'System32\curl.exe') @(
            '-L',
            '--fail',
            '--retry', '3',
            '--output', $FlutterEngineZip,
            $FlutterEngineUrl
        )
    }

    New-Item -ItemType Directory -Path $FlutterEngineExtract -Force | Out-Null
    Expand-Archive -LiteralPath $FlutterEngineZip -DestinationPath $FlutterEngineExtract -Force
    New-Item -ItemType Directory -Path $FlutterEngineTarget -Force | Out-Null
    Copy-Item -Path (Join-Path $FlutterEngineExtract '*') -Destination $FlutterEngineTarget -Recurse -Force
}

function Install-VcpkgDependencies {
    if (-not (Test-Path -LiteralPath $VcpkgExe)) {
        throw "vcpkg executable not found: $VcpkgExe"
    }

    $actualVcpkgCommit = (& git -C $VcpkgRoot rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0 -or $actualVcpkgCommit -ne $ExpectedVcpkgCommit) {
        throw "Expected vcpkg $ExpectedVcpkgCommit, found $actualVcpkgCommit."
    }

    Invoke-Checked $VcpkgExe @(
        'install',
        '--triplet', 'x64-windows-static',
        "--x-install-root=$VcpkgRoot\installed"
    )
}

function Invoke-CargoFetchWithRetry {
    $maximumAttempts = 30
    for ($attempt = 1; $attempt -le $maximumAttempts; $attempt++) {
        Write-Host "`n> $CargoExe fetch --locked (attempt $attempt/$maximumAttempts)"
        & $CargoExe fetch --locked
        if ($LASTEXITCODE -eq 0) {
            return
        }
        if ($attempt -eq $maximumAttempts) {
            throw "Cargo dependency download failed after $maximumAttempts attempts."
        }
        Start-Sleep -Seconds ([Math]::Min(5 * $attempt, 30))
    }
}

function Invoke-FlutterPubGetWithRetry {
    $maximumAttempts = 30
    for ($attempt = 1; $attempt -le $maximumAttempts; $attempt++) {
        Write-Host "`n> $FlutterExe pub get (attempt $attempt/$maximumAttempts)"
        & $FlutterExe pub get
        if ($LASTEXITCODE -eq 0) {
            return
        }
        if ($attempt -eq $maximumAttempts) {
            throw "Flutter dependency download failed after $maximumAttempts attempts."
        }
        Start-Sleep -Seconds ([Math]::Min(5 * $attempt, 30))
    }
}

function Initialize-FlutterBridge {
    $bridgeOutputs = @(
        (Join-Path $ProjectRoot 'src\bridge_generated.rs'),
        (Join-Path $ProjectRoot 'src\bridge_generated.io.rs'),
        (Join-Path $ProjectRoot 'flutter\lib\generated_bridge.dart'),
        (Join-Path $ProjectRoot 'flutter\lib\generated_bridge.freezed.dart')
    )
    $missingBridgeOutputs = @(
        $bridgeOutputs | Where-Object { -not (Test-Path -LiteralPath $_) }
    )
    if ($missingBridgeOutputs.Count -eq 0) {
        Write-Host 'Flutter bridge files are already generated.'
        return
    }

    if (-not (Test-Path -LiteralPath $CargoExpandExe)) {
        Invoke-Checked $CargoExe @(
            'install', 'cargo-expand',
            '--version', '1.0.95',
            '--locked'
        )
    }
    if (-not (Test-Path -LiteralPath $FlutterRustBridgeCodegen)) {
        Invoke-Checked $CargoExe @(
            'install', 'flutter_rust_bridge_codegen',
            '--version', '1.80.1',
            '--features', 'uuid',
            '--locked'
        )
    }

    Push-Location (Join-Path $ProjectRoot 'flutter')
    try {
        Invoke-FlutterPubGetWithRetry
    } finally {
        Pop-Location
    }

    $previousRustLog = [Environment]::GetEnvironmentVariable('RUST_LOG', 'Process')
    try {
        # flutter_rust_bridge_codegen 1.80.1 only accepts the "debug" and
        # "info" filters and panics when the parent shell uses RUST_LOG=warn.
        $env:RUST_LOG = 'info'
        Invoke-Checked $FlutterRustBridgeCodegen @(
            '--rust-input', (Join-Path $ProjectRoot 'src\flutter_ffi.rs'),
            '--dart-output', (Join-Path $ProjectRoot 'flutter\lib\generated_bridge.dart'),
            '--c-output', (Join-Path $ProjectRoot 'flutter\macos\Runner\bridge_generated.h')
        )
    } finally {
        [Environment]::SetEnvironmentVariable('RUST_LOG', $previousRustLog, 'Process')
    }
    Copy-Item `
        -LiteralPath (Join-Path $ProjectRoot 'flutter\macos\Runner\bridge_generated.h') `
        -Destination (Join-Path $ProjectRoot 'flutter\ios\Runner\bridge_generated.h') `
        -Force
}

function Build-PortableExecutable {
    Push-Location $ProjectRoot
    try {
        Invoke-CargoFetchWithRetry
        Initialize-FlutterBridge

        Invoke-Checked $PythonExe @(
            '.\build.py',
            '--portable',
            '--flutter',
            '--skip-portable-pack',
            '--hwcodec',
            '--vram'
        )

        if (-not (Test-Path -LiteralPath (Join-Path $ReleaseDirectory 'rustdesk.exe'))) {
            throw "Flutter release executable not found in $ReleaseDirectory"
        }

        Copy-Item -LiteralPath (Join-Path $ProjectRoot 'LICENCE') -Destination $ReleaseDirectory -Force
        Copy-Item -LiteralPath (Join-Path $ProjectRoot 'CUSTOM_BUILD.md') -Destination $ReleaseDirectory -Force

        Push-Location (Join-Path $ProjectRoot 'libs\portable')
        try {
            Invoke-Checked $PythonExe @('-m', 'pip', 'install', '-r', '.\requirements.txt')
            Invoke-Checked $PythonExe @(
                '.\generate.py',
                '-f', '..\..\flutter\build\windows\x64\runner\Release',
                '-o', '.',
                '-e', '..\..\flutter\build\windows\x64\runner\Release\rustdesk.exe'
            )
        } finally {
            Pop-Location
        }

        $packedExe = Join-Path $ProjectRoot 'target\release\rustdesk-portable-packer.exe'
        if (-not (Test-Path -LiteralPath $packedExe)) {
            throw "Portable packer output not found: $packedExe"
        }
        New-Item -ItemType Directory -Path $DistDirectory -Force | Out-Null
        Move-Item -LiteralPath $packedExe -Destination $OutputExe -Force

        $hash = (Get-FileHash -LiteralPath $OutputExe -Algorithm SHA256).Hash
        $hashLine = "$hash  $([System.IO.Path]::GetFileName($OutputExe))"
        Set-Content -LiteralPath (Join-Path $DistDirectory 'SHA256.txt') -Value $hashLine -Encoding ascii

        Write-Host "`nBUILD_SUCCESS"
        Write-Host "OUTPUT=$OutputExe"
        Write-Host "SHA256=$hash"
    } finally {
        Pop-Location
    }
}

foreach ($requiredFile in @($PythonExe, $CargoExe, $RustupExe, (Join-Path $LlvmBin 'clang.exe'))) {
    if (-not (Test-Path -LiteralPath $requiredFile)) {
        throw "Required build tool not found: $requiredFile"
    }
}

New-Item -ItemType Directory -Path (Join-Path $ToolsRoot 'appdata') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $ToolsRoot 'pub-cache') -Force | Out-Null

$env:APPDATA = Join-Path $ToolsRoot 'appdata'
$env:PUB_CACHE = Join-Path $ToolsRoot 'pub-cache'
$env:CI = 'true'
$env:FLUTTER_SUPPRESS_ANALYTICS = 'true'
$env:CARGO_NET_GIT_FETCH_WITH_CLI = 'true'
$env:CARGO_NET_RETRY = '5'
$env:CARGO_HTTP_TIMEOUT = '120'
$env:GIT_CONFIG_COUNT = '1'
$env:GIT_CONFIG_KEY_0 = 'http.version'
$env:GIT_CONFIG_VALUE_0 = 'HTTP/1.1'
$env:Path = "$FlutterRoot\bin;$CargoBin;$LlvmBin;$([System.IO.Path]::GetDirectoryName($PythonExe));$env:Path"

Import-VisualStudioEnvironment

# VsDevCmd defines VCPKG_ROOT for Visual Studio's bundled copy. RustDesk must
# use the pinned standalone vcpkg checkout prepared for this repository.
$env:LIBCLANG_PATH = $LlvmBin
$env:VCPKG_ROOT = $VcpkgRoot
$env:VCPKG_INSTALLED_ROOT = Join-Path $VcpkgRoot 'installed'
$env:VCPKG_DEFAULT_TRIPLET = 'x64-windows-static'
$env:VCPKG_DEFAULT_HOST_TRIPLET = 'x64-windows-static'
$env:Path = "$FlutterRoot\bin;$CargoBin;$LlvmBin;$([System.IO.Path]::GetDirectoryName($PythonExe));$env:Path"

Write-Host 'Pinned toolchain:'
Invoke-Checked $RustupExe @('run', '1.75.0', 'cargo', '--version')
Invoke-Checked (Join-Path $LlvmBin 'clang.exe') @('--version')
Invoke-Checked $PythonExe @('--version')
Invoke-Checked $FlutterExe @('--version')

if (-not $SkipFlutterSetup) {
    Initialize-Flutter
}
if (-not $SkipVcpkg) {
    Install-VcpkgDependencies
}
Build-PortableExecutable
