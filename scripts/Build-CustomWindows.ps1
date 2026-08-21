[CmdletBinding()]
param(
    [switch]$SkipVcpkg,
    [switch]$SkipFlutterSetup,
    [switch]$IncrementalRustOnly,
    [switch]$DiagnosticRustLibraryOnly,
    [switch]$RefreshFlutterAot,
    [ValidateRange(0, 999999)]
    [int]$BetaNumber = 0,
    [string]$OutputFileName = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Initialize-MasterDeskBuildEnvironment.ps1')

if ($RefreshFlutterAot -and -not $IncrementalRustOnly) {
    throw '-RefreshFlutterAot is supported only with -IncrementalRustOnly.'
}
if ($DiagnosticRustLibraryOnly -and -not $IncrementalRustOnly) {
    throw '-DiagnosticRustLibraryOnly is supported only with -IncrementalRustOnly.'
}

$ProjectRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$ToolsRoot = Join-Path $ProjectRoot '.tools'
$AppDataRoot = Join-Path $ToolsRoot 'appdata'
$PubCacheRoot = if ($env:MASTERDESK_PUB_CACHE) {
    [System.IO.Path]::GetFullPath($env:MASTERDESK_PUB_CACHE)
} else {
    Join-Path $ToolsRoot 'pub-cache'
}
$FlutterRoot = if ($env:MASTERDESK_FLUTTER_ROOT) {
    [System.IO.Path]::GetFullPath($env:MASTERDESK_FLUTTER_ROOT)
} else {
    Join-Path $ToolsRoot 'flutter'
}
$FlutterExe = Join-Path $FlutterRoot 'bin\flutter.bat'
$VcpkgRoot = if ($env:MASTERDESK_VCPKG_ROOT) {
    [System.IO.Path]::GetFullPath($env:MASTERDESK_VCPKG_ROOT)
} else {
    Join-Path $ToolsRoot 'vcpkg'
}
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
$GitCommand = Get-Command git.exe -ErrorAction SilentlyContinue
if (-not $GitCommand) {
    throw 'Git for Windows was not found.'
}
$GitBin = [System.IO.Path]::GetDirectoryName($GitCommand.Source)
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
$BuildBaseVersion = '1.4.9-10'
$BuildDate = Get-Date -Format 'yyyy-MM-dd HH:mm'
$BuildDateForFileName = Get-Date -Format 'yyyy-MM-dd'
if ($BetaNumber -eq 0) {
    $existingBetaNumbers = @()
    if (Test-Path -LiteralPath $DistDirectory) {
        $existingBetaNumbers = @(Get-ChildItem -LiteralPath $DistDirectory -File -Filter 'MasterDesk-*-beta-*-*-RDS-x86_64.exe' |
            ForEach-Object {
                if ($_.Name -match '-beta-(\d+)-\d{4}-\d{2}-\d{2}-RDS-x86_64\.exe$') {
                    [int]$matches[1]
                }
            })
    }
    $BetaNumber = if ($existingBetaNumbers.Count -eq 0) {
        1
    } else {
        1 + ($existingBetaNumbers | Measure-Object -Maximum).Maximum
    }
}
$expectedOutputFileName = "MasterDesk-$BuildBaseVersion-beta-$BetaNumber-$BuildDateForFileName-RDS-x86_64.exe"
if ([string]::IsNullOrWhiteSpace($OutputFileName)) {
    $OutputFileName = $expectedOutputFileName
} elseif ($OutputFileName -cne $expectedOutputFileName) {
    throw "OutputFileName must follow the build identity rule: $expectedOutputFileName"
}
$OutputExe = Join-Path $DistDirectory $OutputFileName

function Invoke-Checked {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter()][string[]]$Arguments = @()
    )

    Write-Host "`n> $FilePath $($Arguments -join ' ')"
    # Native tools legitimately write progress and warnings to stderr. When
    # this script's output is redirected to an artifact, Windows PowerShell can
    # turn those records into terminating errors under Stop preference.
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        & $FilePath @Arguments
        $nativeExitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    if ($nativeExitCode -ne 0) {
        throw "Command failed with exit code $nativeExitCode`: $FilePath"
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

function Invoke-IncrementalFlutterAotBuild {
    param(
        [Parameter(Mandatory)] [string]$FlutterBackend,
        [Parameter(Mandatory)] [string]$FlutterProject
    )

    $logDirectory = Join-Path $ProjectRoot '.tools\logs'
    New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $stdoutLog = Join-Path $logDirectory "flutter-aot-$stamp.stdout.log"
    $stderrLog = Join-Path $logDirectory "flutter-aot-$stamp.stderr.log"
    $startedUtc = [DateTime]::UtcNow
    $commandLine = "/d /s /c `"`"$FlutterBackend`" windows-x64 Release`""
    $process = Start-Process `
        -FilePath $env:ComSpec `
        -ArgumentList $commandLine `
        -WorkingDirectory $FlutterProject `
        -WindowStyle Hidden `
        -RedirectStandardOutput $stdoutLog `
        -RedirectStandardError $stderrLog `
        -PassThru

    $deadline = [DateTime]::UtcNow.AddMinutes(10)
    $lastSignature = $null
    $stableSince = $null
    $latestAot = $null
    while ([DateTime]::UtcNow -lt $deadline) {
        $process.Refresh()
        $latestAot = Get-ChildItem `
            -LiteralPath (Join-Path $FlutterProject '.dart_tool\flutter_build') `
            -Recurse -File -Filter 'app.so' -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTimeUtc -Descending |
            Select-Object -First 1

        if ($latestAot -and $latestAot.LastWriteTimeUtc -ge $startedUtc.AddSeconds(-2)) {
            $signature = "$($latestAot.Length):$($latestAot.LastWriteTimeUtc.Ticks)"
            if ($signature -ne $lastSignature) {
                $lastSignature = $signature
                $stableSince = [DateTime]::UtcNow
            } elseif ($stableSince -and
                [DateTime]::UtcNow.Subtract($stableSince).TotalSeconds -ge 15) {
                if (-not $process.HasExited) {
                    # Flutter 3.24 can leave tool_backend.bat waiting after the
                    # final app.so is complete. Stop only that exact hidden
                    # wrapper after the artifact has remained stable.
                    Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
                    $process.WaitForExit(5000) | Out-Null
                    Write-Host "Flutter AOT wrapper stopped after stable output: $($latestAot.FullName)"
                }
                return $latestAot
            }
        }

        if ($process.HasExited) {
            if ($process.ExitCode -ne 0) {
                Write-Host "Flutter AOT stderr log: $stderrLog"
                if (Test-Path -LiteralPath $stderrLog) {
                    Get-Content -LiteralPath $stderrLog -Tail 25
                }
                throw "Flutter AOT backend failed with exit code $($process.ExitCode)."
            }
            if (-not $latestAot) {
                throw 'Flutter AOT backend completed without producing app.so.'
            }
            return $latestAot
        }
        Start-Sleep -Seconds 1
    }

    Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
    throw "Flutter AOT backend timed out. Logs: $stdoutLog ; $stderrLog"
}

function Build-IncrementalRustPortableExecutable {
    Push-Location $ProjectRoot
    try {
        $runnerExe = Join-Path $ReleaseDirectory 'rustdesk.exe'
        if (-not (Test-Path -LiteralPath $runnerExe)) {
            throw "Existing Flutter runner not found: $runnerExe"
        }

        if ($RefreshFlutterAot) {
            Push-Location (Join-Path $ProjectRoot 'flutter')
            try {
                # Call Flutter's cached AOT backend directly. The outer
                # `flutter build windows` CMake wrapper can wait indefinitely
                # after app.so is already complete on this workspace.
                $flutterProject = Join-Path $ProjectRoot 'flutter'
                $env:FLUTTER_ROOT = $FlutterRoot
                $env:PROJECT_DIR = $flutterProject
                $env:FLUTTER_EPHEMERAL_DIR = Join-Path $flutterProject 'windows\flutter\ephemeral'
                $env:FLUTTER_TARGET = 'lib\main.dart'
                $env:DART_OBFUSCATION = 'false'
                $env:TRACK_WIDGET_CREATION = 'true'
                $env:TREE_SHAKE_ICONS = 'true'
                $env:PACKAGE_CONFIG = Join-Path $flutterProject '.dart_tool\package_config.json'
                $flutterBackend = Join-Path $FlutterRoot 'packages\flutter_tools\bin\tool_backend.bat'
                $aotOutput = Invoke-IncrementalFlutterAotBuild `
                    -FlutterBackend $flutterBackend `
                    -FlutterProject $flutterProject
                $releaseAot = Join-Path $ReleaseDirectory 'data\app.so'
                Copy-Item -LiteralPath $aotOutput.FullName -Destination $releaseAot -Force
                Write-Host "Flutter AOT refreshed: $($aotOutput.FullName)"
            } finally {
                Pop-Location
            }
        }

        # Recompile only the Rust library. The existing Flutter runner, AOT
        # bundle, plugins, vcpkg artifacts, and CMake output stay untouched.
        Invoke-Checked $CargoExe @(
            'build',
            '--locked',
            '--offline',
            '--release',
            '--features', 'hwcodec,vram,flutter',
            '--lib'
        )

        $rustLibrary = Join-Path $ProjectRoot 'target\release\librustdesk.dll'
        if (-not (Test-Path -LiteralPath $rustLibrary)) {
            throw "Incremental Rust library was not produced: $rustLibrary"
        }
        if ($DiagnosticRustLibraryOnly) {
            $diagnosticDirectory = Join-Path $ProjectRoot (
                'artifacts\diagnostic-rust\' + (Get-Date -Format 'yyyyMMdd-HHmmss')
            )
            New-Item -ItemType Directory -Path $diagnosticDirectory -Force | Out-Null
            $diagnosticLibrary = Join-Path $diagnosticDirectory 'librustdesk.dll'
            Copy-Item -LiteralPath $rustLibrary -Destination $diagnosticLibrary -Force
            $diagnosticHash = (Get-FileHash -LiteralPath $diagnosticLibrary -Algorithm SHA256).Hash
            Write-Host "`nBUILD_SUCCESS"
            Write-Host 'MODE=DiagnosticRustLibraryOnly'
            Write-Host "OUTPUT=$diagnosticLibrary"
            Write-Host "SHA256=$diagnosticHash"
            return
        }
        Copy-Item -LiteralPath $rustLibrary -Destination $ReleaseDirectory -Force
        Copy-Item -LiteralPath (Join-Path $ProjectRoot 'LICENCE') -Destination $ReleaseDirectory -Force
        Copy-Item -LiteralPath (Join-Path $ProjectRoot 'CUSTOM_BUILD.md') -Destination $ReleaseDirectory -Force

        Push-Location (Join-Path $ProjectRoot 'libs\portable')
        try {
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
        if ($RefreshFlutterAot) {
            Write-Host 'MODE=IncrementalRustWithFlutterAot'
        } else {
            Write-Host 'MODE=IncrementalRustOnly'
        }
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

New-Item -ItemType Directory -Path $AppDataRoot -Force | Out-Null
New-Item -ItemType Directory -Path $PubCacheRoot -Force | Out-Null

$env:APPDATA = $AppDataRoot
$env:PUB_CACHE = $PubCacheRoot
$env:CI = 'true'
$env:FLUTTER_SUPPRESS_ANALYTICS = 'true'
$env:FLUTTER_ALREADY_LOCKED = 'true'
$env:CARGO_NET_GIT_FETCH_WITH_CLI = 'true'
$env:CARGO_NET_RETRY = '5'
$env:CARGO_HTTP_TIMEOUT = '120'
$env:GIT_CONFIG_COUNT = '3'
$env:GIT_CONFIG_KEY_0 = 'http.version'
$env:GIT_CONFIG_VALUE_0 = 'HTTP/1.1'
$env:GIT_CONFIG_KEY_1 = 'safe.directory'
$env:GIT_CONFIG_VALUE_1 = $FlutterRoot
$env:GIT_CONFIG_KEY_2 = 'safe.directory'
$env:GIT_CONFIG_VALUE_2 = $VcpkgRoot
$env:Path = "$FlutterRoot\bin;$GitBin;$CargoBin;$LlvmBin;$([System.IO.Path]::GetDirectoryName($PythonExe));$env:Path"

Import-VisualStudioEnvironment

# VsDevCmd defines VCPKG_ROOT for Visual Studio's bundled copy. RustDesk must
# use the pinned standalone vcpkg checkout prepared for this repository.
$env:APPDATA = $AppDataRoot
$env:PUB_CACHE = $PubCacheRoot
$env:FLUTTER_ALREADY_LOCKED = 'true'
$env:LIBCLANG_PATH = $LlvmBin
$env:VCPKG_ROOT = $VcpkgRoot
$env:VCPKG_INSTALLED_ROOT = Join-Path $VcpkgRoot 'installed'
$env:VCPKG_DEFAULT_TRIPLET = 'x64-windows-static'
$env:VCPKG_DEFAULT_HOST_TRIPLET = 'x64-windows-static'
$env:MASTERDESK_BUILD_BETA_NUMBER = $BetaNumber.ToString([System.Globalization.CultureInfo]::InvariantCulture)
$env:MASTERDESK_BUILD_DATE = $BuildDate
$env:Path = "$FlutterRoot\bin;$GitBin;$CargoBin;$LlvmBin;$([System.IO.Path]::GetDirectoryName($PythonExe));$env:Path"
$localPythonPackages = Join-Path $ToolsRoot 'python-packages'
if (Test-Path -LiteralPath $localPythonPackages) {
    $env:PYTHONPATH = if ($env:PYTHONPATH) {
        "$localPythonPackages;$env:PYTHONPATH"
    } else {
        $localPythonPackages
    }
}

Write-Host 'Pinned toolchain:'
Write-Host "MasterDesk build: $BuildBaseVersion beta $BetaNumber ($BuildDate)"
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
if ($IncrementalRustOnly) {
    Build-IncrementalRustPortableExecutable
} else {
    Build-PortableExecutable
}
