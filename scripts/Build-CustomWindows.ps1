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
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        # A non-zero exit is expected when the patch is already present. Windows
        # PowerShell promotes native stderr to a terminating error under Stop,
        # so probe both directions with native failures temporarily non-fatal.
        $ErrorActionPreference = 'Continue'
        & git -C $FlutterRoot apply --check $patchPath 2>$null
        $patchCanApply = $LASTEXITCODE -eq 0
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    if ($patchCanApply) {
        Invoke-Checked 'git' @('-C', $FlutterRoot, 'apply', $patchPath)
    } else {
        $previousErrorActionPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            & git -C $FlutterRoot apply --reverse --check $patchPath 2>$null
            $patchIsApplied = $LASTEXITCODE -eq 0
        }
        finally {
            $ErrorActionPreference = $previousErrorActionPreference
        }
        if (-not $patchIsApplied) {
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

function Initialize-DesktopDropWindowsPatch {
    $packageConfigPath = Join-Path $ProjectRoot 'flutter\.dart_tool\package_config.json'
    if (-not (Test-Path -LiteralPath $packageConfigPath)) {
        Push-Location (Join-Path $ProjectRoot 'flutter')
        try {
            Invoke-FlutterPubGetWithRetry
        } finally {
            Pop-Location
        }
    }

    $packageConfig = Get-Content -LiteralPath $packageConfigPath -Raw | ConvertFrom-Json
    $desktopDrop = @($packageConfig.packages | Where-Object { $_.name -eq 'desktop_drop' })
    if ($desktopDrop.Count -ne 1) {
        throw 'Expected exactly one desktop_drop package in Flutter package_config.json.'
    }

    $packageConfigUri = [Uri](Get-Item -LiteralPath $packageConfigPath).FullName
    $packageRootUri = [Uri]::new($packageConfigUri, [string]$desktopDrop[0].rootUri)
    $pluginSource = Join-Path $packageRootUri.LocalPath 'windows\desktop_drop_plugin.cpp'
    if (-not (Test-Path -LiteralPath $pluginSource)) {
        throw "desktop_drop Windows source not found: $pluginSource"
    }

    $source = [System.IO.File]::ReadAllText($pluginSource)
    $newline = if ($source.Contains("`r`n")) { "`r`n" } else { "`n" }
    $normalized = $source.Replace("`r`n", "`n")
    $signatures = @(
        'HRESULT DesktopDropTarget::DragEnter(IDataObject *pDataObj, DWORD grfKeyState, POINTL pt, DWORD *pdwEffect) {',
        'HRESULT DesktopDropTarget::DragOver(DWORD grfKeyState, POINTL pt, DWORD *pdwEffect) {',
        'HRESULT DesktopDropTarget::Drop(IDataObject *pDataObj, DWORD grfKeyState, POINTL pt, DWORD *pdwEffect) {'
    )
    $effectSelection = @'
    if (pdwEffect != nullptr) {
        *pdwEffect = (*pdwEffect & DROPEFFECT_COPY) != 0
                         ? DROPEFFECT_COPY
                         : DROPEFFECT_NONE;
    }
'@

    $changed = $false
    $patchedCount = ([regex]::Matches(
        $normalized,
        [regex]::Escape('(*pdwEffect & DROPEFFECT_COPY) != 0')
    )).Count
    if ($patchedCount -eq 0) {
        foreach ($signature in $signatures) {
            if (([regex]::Matches($normalized, [regex]::Escape($signature))).Count -ne 1) {
                throw "desktop_drop Windows source signature changed: $signature"
            }
            $normalized = $normalized.Replace(
                $signature,
                "$signature`n$effectSelection"
            )
        }
        $changed = $true
    } elseif ($patchedCount -ne $signatures.Count) {
        throw "desktop_drop Windows copy-effect patch is partial ($patchedCount/$($signatures.Count))."
    }

    $hdropOld = @'
                // we asked for the data as a HGLOBAL, so access it appropriately
                PVOID data = GlobalLock(stgmed.hGlobal);
                if (data != nullptr) {
                    auto files = DragQueryFile(reinterpret_cast<HDROP>(data), 0xFFFFFFFF, nullptr, 0);
                    for (unsigned int i = 0; i < files; ++i) {
                        TCHAR filename[MAX_PATH];
                        DragQueryFile(reinterpret_cast<HDROP>(data), i, filename, sizeof(TCHAR) * MAX_PATH);
                        std::wstring wide(filename);
                        std::string path = ws2s(wide);
                        std::cout << "done: " << path << std::endl;
                        list.push_back(flutter::EncodableValue(path));
                    }
                    GlobalUnlock(stgmed.hGlobal);
                }
'@
    $hdropNew = @'
                const auto drop = reinterpret_cast<HDROP>(stgmed.hGlobal);
                const auto files = DragQueryFile(drop, 0xFFFFFFFF, nullptr, 0);
                for (unsigned int i = 0; i < files; ++i) {
                    const auto length = DragQueryFile(drop, i, nullptr, 0);
                    std::wstring filename(length + 1, L'\0');
                    if (DragQueryFile(drop, i, filename.data(),
                                      static_cast<UINT>(filename.size())) > 0) {
                        filename.resize(length);
                        list.push_back(flutter::EncodableValue(ws2s(filename)));
                    }
                }
'@
    $oldHdropCount = ([regex]::Matches($normalized, [regex]::Escape($hdropOld))).Count
    $newHdropCount = ([regex]::Matches($normalized, [regex]::Escape($hdropNew))).Count
    if ($oldHdropCount -eq 1 -and $newHdropCount -eq 0) {
        $normalized = $normalized.Replace($hdropOld, $hdropNew)
        $changed = $true
    } elseif ($oldHdropCount -ne 0 -or $newHdropCount -ne 1) {
        throw "desktop_drop Windows CF_HDROP patch state is invalid (old=$oldHdropCount new=$newHdropCount)."
    }

    if (-not $changed) {
        Write-Host 'desktop_drop Windows copy-effect and CF_HDROP patches are already applied.'
        return
    }
    [System.IO.File]::WriteAllText(
        $pluginSource,
        $normalized.Replace("`n", $newline),
        [System.Text.UTF8Encoding]::new($false)
    )
    Write-Host "Applied desktop_drop Windows copy-effect/CF_HDROP patches: $pluginSource"
}

function Test-FlutterBridgeNeedsGeneration {
    $bridgeOutputs = @(
        (Join-Path $ProjectRoot 'src\bridge_generated.rs'),
        (Join-Path $ProjectRoot 'src\bridge_generated.io.rs'),
        (Join-Path $ProjectRoot 'flutter\lib\generated_bridge.dart'),
        (Join-Path $ProjectRoot 'flutter\lib\generated_bridge.freezed.dart'),
        (Join-Path $ProjectRoot 'flutter\macos\Runner\bridge_generated.h')
    )
    $missingBridgeOutputs = @(
        $bridgeOutputs | Where-Object { -not (Test-Path -LiteralPath $_) }
    )
    if ($missingBridgeOutputs.Count -gt 0) {
        return $true
    }

    $bridgeInput = Get-Item -LiteralPath (Join-Path $ProjectRoot 'src\flutter_ffi.rs')
    $generatedCore = @(
        'src\bridge_generated.rs',
        'src\bridge_generated.io.rs',
        'flutter\lib\generated_bridge.dart',
        'flutter\macos\Runner\bridge_generated.h'
    ) | ForEach-Object { Get-Item -LiteralPath (Join-Path $ProjectRoot $_) }
    return @($generatedCore | Where-Object {
        $_.LastWriteTimeUtc -lt $bridgeInput.LastWriteTimeUtc
    }).Count -gt 0
}

function Initialize-FlutterBridge {
    if (-not (Test-FlutterBridgeNeedsGeneration)) {
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
            '--c-output', (Join-Path $ProjectRoot 'flutter\macos\Runner\bridge_generated.h'),
            '--llvm-path', (Split-Path -Parent $LlvmBin)
        )
    } finally {
        [Environment]::SetEnvironmentVariable('RUST_LOG', $previousRustLog, 'Process')
    }
    Copy-Item `
        -LiteralPath (Join-Path $ProjectRoot 'flutter\macos\Runner\bridge_generated.h') `
        -Destination (Join-Path $ProjectRoot 'flutter\ios\Runner\bridge_generated.h') `
        -Force
}

function Remove-LegacyWindowsBundleNames {
    foreach ($legacyName in @(
        'rustdesk.exe',
        'librustdesk.dll',
        'RuntimeBroker_rustdesk.exe'
    )) {
        $legacyPath = Join-Path $ReleaseDirectory $legacyName
        if (Test-Path -LiteralPath $legacyPath) {
            Remove-Item -LiteralPath $legacyPath -Force
        }
    }

    $remainingLegacyNames = @(Get-ChildItem -LiteralPath $ReleaseDirectory -Recurse -Force |
        Where-Object { $_.Name -match '(?i)rustdesk' })
    if ($remainingLegacyNames.Count -gt 0) {
        throw "Legacy RustDesk-named bundle entries remain: $($remainingLegacyNames.FullName -join '; ')"
    }
}

function Test-FlutterReleaseAssetBundle {
    param(
        [string]$AssetRoot = (Join-Path $ReleaseDirectory 'data\flutter_assets'),
        [switch]$ThrowOnFailure
    )

    $assetManifest = Join-Path $AssetRoot 'AssetManifest.bin'
    $fontManifest = Join-Path $AssetRoot 'FontManifest.json'
    $materialIcons = Join-Path $AssetRoot 'fonts\MaterialIcons-Regular.otf'
    $problems = [System.Collections.Generic.List[string]]::new()

    foreach ($requiredFile in @($assetManifest, $fontManifest, $materialIcons)) {
        if (-not (Test-Path -LiteralPath $requiredFile)) {
            [void]$problems.Add("missing $requiredFile")
        } elseif ((Get-Item -LiteralPath $requiredFile).Length -le 0) {
            [void]$problems.Add("empty $requiredFile")
        }
    }

    if ($problems.Count -eq 0) {
        try {
            $fonts = Get-Content -LiteralPath $fontManifest -Raw | ConvertFrom-Json
            $materialFamilyCount = 0
            $materialAssetFound = $false
            foreach ($fontFamily in $fonts) {
                if ($fontFamily.family -ne 'MaterialIcons') {
                    continue
                }
                $materialFamilyCount++
                foreach ($fontEntry in $fontFamily.fonts) {
                    if ($fontEntry.asset -eq 'fonts/MaterialIcons-Regular.otf') {
                        $materialAssetFound = $true
                    }
                }
            }
            if ($materialFamilyCount -ne 1 -or -not $materialAssetFound) {
                [void]$problems.Add('FontManifest.json does not register MaterialIcons-Regular.otf')
            }
        } catch {
            [void]$problems.Add("invalid FontManifest.json: $($_.Exception.Message)")
        }
    }

    if ($problems.Count -gt 0) {
        if ($ThrowOnFailure) {
            throw "BUILD FAIL: Flutter release asset bundle is incomplete: $($problems -join '; ')"
        }
        return $false
    }
    return $true
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

        if (-not (Test-Path -LiteralPath (Join-Path $ReleaseDirectory 'MasterDesk.exe'))) {
            throw "Flutter release executable not found in $ReleaseDirectory"
        }
        if (-not (Test-Path -LiteralPath (Join-Path $ReleaseDirectory 'libmasterdesk.dll'))) {
            throw "Branded Rust library not found in $ReleaseDirectory"
        }
        Remove-LegacyWindowsBundleNames

        Copy-Item -LiteralPath (Join-Path $ProjectRoot 'LICENCE') -Destination $ReleaseDirectory -Force
        Copy-Item -LiteralPath (Join-Path $ProjectRoot 'CUSTOM_BUILD.md') -Destination $ReleaseDirectory -Force
        Write-BuildConsistencyManifest

        Push-Location (Join-Path $ProjectRoot 'libs\portable')
        try {
            Invoke-Checked $PythonExe @('-m', 'pip', 'install', '-r', '.\requirements.txt')
            Invoke-Checked $PythonExe @(
                '.\generate.py',
                '-f', '..\..\flutter\build\windows\x64\runner\Release',
                '-o', '.',
                '-e', '..\..\flutter\build\windows\x64\runner\Release\MasterDesk.exe'
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

function Stop-ProcessTree {
    param([Parameter(Mandatory)] [int]$RootProcessId)

    $processes = @(Get-CimInstance Win32_Process)
    $targets = [System.Collections.Generic.List[object]]::new()
    $pending = [System.Collections.Generic.Queue[object]]::new()
    $pending.Enqueue([pscustomobject]@{ Id = $RootProcessId; Depth = 0 })
    while ($pending.Count -gt 0) {
        $item = $pending.Dequeue()
        $process = $processes | Where-Object { $_.ProcessId -eq $item.Id } | Select-Object -First 1
        if (-not $process) {
            continue
        }
        [void]$targets.Add([pscustomobject]@{ Id = [int]$process.ProcessId; Depth = $item.Depth })
        foreach ($child in ($processes | Where-Object { $_.ParentProcessId -eq $process.ProcessId })) {
            $pending.Enqueue([pscustomobject]@{ Id = [int]$child.ProcessId; Depth = $item.Depth + 1 })
        }
    }

    foreach ($target in ($targets | Sort-Object Depth -Descending)) {
        Stop-Process -Id $target.Id -Force -ErrorAction SilentlyContinue
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
    $aotInputs = @(
        Get-ChildItem -LiteralPath (Join-Path $FlutterProject 'lib') -Recurse -File -Filter '*.dart'
        Get-Item -LiteralPath (Join-Path $ProjectRoot 'src\bridge_generated.rs') -ErrorAction SilentlyContinue
        Get-Item -LiteralPath (Join-Path $ProjectRoot 'src\bridge_generated.io.rs') -ErrorAction SilentlyContinue
        Get-Item -LiteralPath (Join-Path $ProjectRoot 'src\flutter.rs') -ErrorAction SilentlyContinue
        Get-Item -LiteralPath (Join-Path $ProjectRoot 'src\flutter_ffi.rs') -ErrorAction SilentlyContinue
    ) | Where-Object { $_ }
    $newestAotInput = $aotInputs | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
    # Redirect inside cmd.exe and use System.Diagnostics.Process directly.
    # Windows PowerShell's Start-Process can wait while descendant Dart
    # processes retain handles, preventing the watchdog from observing the PID.
    $commandLine = "/d /s /c `"`"$FlutterBackend`" windows-x64 Release 1>`"$stdoutLog`" 2>`"$stderrLog`"`""
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $env:ComSpec
    $startInfo.Arguments = $commandLine
    $startInfo.WorkingDirectory = $FlutterProject
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    if (-not $process.Start()) {
        throw 'Failed to start the Flutter AOT backend.'
    }
    Write-Host "Flutter AOT wrapper started: PID $($process.Id)"

    $deadline = [DateTime]::UtcNow.AddMinutes(10)
    $lastSignature = $null
    $stableSince = $null
    $latestAot = $null
    $lastProbeUtc = [DateTime]::MinValue
    while ([DateTime]::UtcNow -lt $deadline) {
        $process.Refresh()
        $latestAot = Get-ChildItem `
            -LiteralPath (Join-Path $FlutterProject '.dart_tool\flutter_build') `
            -Recurse -File -Filter 'app.so' -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTimeUtc -Descending |
            Select-Object -First 1

        $generatedAssetRoot = Join-Path $FlutterProject 'build\flutter_assets'
        $generatedAssetsReady = Test-FlutterReleaseAssetBundle -AssetRoot $generatedAssetRoot
        $generatedAssetManifest = Join-Path $generatedAssetRoot 'AssetManifest.bin'
        $generatedFontManifest = Join-Path $generatedAssetRoot 'FontManifest.json'
        $freshOutput = $latestAot -and (
            $latestAot.LastWriteTimeUtc -ge $startedUtc.AddSeconds(-2) -or
            ((Test-Path -LiteralPath $generatedAssetManifest) -and
                (Get-Item -LiteralPath $generatedAssetManifest).LastWriteTimeUtc -ge $startedUtc.AddSeconds(-2)) -or
            ((Test-Path -LiteralPath $generatedFontManifest) -and
                (Get-Item -LiteralPath $generatedFontManifest).LastWriteTimeUtc -ge $startedUtc.AddSeconds(-2))
        )
        $aotAlreadyCurrent = $latestAot -and (
            -not $newestAotInput -or
            $latestAot.LastWriteTimeUtc -ge $newestAotInput.LastWriteTimeUtc
        )
        if ([DateTime]::UtcNow.Subtract($lastProbeUtc).TotalSeconds -ge 10) {
            Write-Host (
                'Flutter AOT probe: app={0} fresh={1} current={2} assets={3}' -f
                [bool]$latestAot,
                [bool]$freshOutput,
                [bool]$aotAlreadyCurrent,
                [bool]$generatedAssetsReady
            )
            $lastProbeUtc = [DateTime]::UtcNow
        }
        if ($latestAot -and
            ($freshOutput -or $aotAlreadyCurrent) -and
            $generatedAssetsReady) {
            $assetSignature = @(
                'AssetManifest.bin',
                'FontManifest.json',
                'fonts\MaterialIcons-Regular.otf'
            ) | ForEach-Object {
                $asset = Get-Item -LiteralPath (Join-Path $generatedAssetRoot $_)
                "$($asset.Length):$($asset.LastWriteTimeUtc.Ticks)"
            }
            $signature = "$($latestAot.Length):$($latestAot.LastWriteTimeUtc.Ticks):$($assetSignature -join ':')"
            if ($signature -ne $lastSignature) {
                $lastSignature = $signature
                $stableSince = [DateTime]::UtcNow
                Write-Host 'Flutter AOT and asset bundle are ready; verifying stability.'
            } elseif ($stableSince -and
                [DateTime]::UtcNow.Subtract($stableSince).TotalSeconds -ge 15) {
                if (-not $process.HasExited) {
                    # Flutter 3.24 can leave tool_backend.bat waiting after the
                    # final app.so is complete. Stop only that exact hidden
                    # wrapper tree after the artifacts have remained stable.
                    Stop-ProcessTree -RootProcessId $process.Id
                    $process.WaitForExit(5000) | Out-Null
                    Write-Host "Flutter AOT wrapper stopped after stable output: $($latestAot.FullName)"
                }
                return $latestAot
            }
        }

        if ($process.HasExited) {
            # Redirected Start-Process streams are finalized asynchronously.
            # Wait before reading ExitCode; otherwise PowerShell can expose
            # $null and falsely report a successful short backend run as failed.
            $process.WaitForExit()
            $process.Refresh()
            $exitCode = $process.ExitCode
            if ($null -eq $exitCode) {
                $stderrLength = if (Test-Path -LiteralPath $stderrLog) {
                    (Get-Item -LiteralPath $stderrLog).Length
                } else {
                    0
                }
                if ($latestAot -and $stderrLength -eq 0 -and
                    (Test-FlutterReleaseAssetBundle -AssetRoot $generatedAssetRoot)) {
                    return $latestAot
                }
                throw "Flutter AOT backend ended without an exit code. Logs: $stdoutLog ; $stderrLog"
            }
            if ($exitCode -ne 0) {
                Write-Host "Flutter AOT stderr log: $stderrLog"
                if (Test-Path -LiteralPath $stderrLog) {
                    Get-Content -LiteralPath $stderrLog -Tail 25
                }
                throw "Flutter AOT backend failed with exit code $exitCode."
            }
            if (-not $latestAot) {
                throw 'Flutter AOT backend completed without producing app.so.'
            }
            Test-FlutterReleaseAssetBundle `
                -AssetRoot $generatedAssetRoot `
                -ThrowOnFailure | Out-Null
            return $latestAot
        }
        Start-Sleep -Seconds 1
    }

    Stop-ProcessTree -RootProcessId $process.Id
    throw "Flutter AOT backend timed out. Logs: $stdoutLog ; $stderrLog"
}

function Write-BuildConsistencyManifest {
    $rustLibrary = Join-Path $ReleaseDirectory 'libmasterdesk.dll'
    $flutterAot = Join-Path $ReleaseDirectory 'data\app.so'
    if (-not (Test-Path -LiteralPath $rustLibrary)) {
        throw "Build consistency check: Rust library not found: $rustLibrary"
    }
    if (-not (Test-Path -LiteralPath $flutterAot)) {
        throw "Build consistency check: Flutter AOT not found: $flutterAot"
    }
    Test-FlutterReleaseAssetBundle -ThrowOnFailure | Out-Null
    if (Test-FlutterBridgeNeedsGeneration) {
        throw 'BUILD FAIL: Flutter/Rust bridge outputs are stale.'
    }

    $aotInputs = @(
        Get-ChildItem -LiteralPath (Join-Path $ProjectRoot 'flutter\lib') -Recurse -File -Filter '*.dart'
        Get-Item -LiteralPath (Join-Path $ProjectRoot 'src\bridge_generated.rs') -ErrorAction SilentlyContinue
        Get-Item -LiteralPath (Join-Path $ProjectRoot 'src\bridge_generated.io.rs') -ErrorAction SilentlyContinue
        Get-Item -LiteralPath (Join-Path $ProjectRoot 'src\flutter.rs') -ErrorAction SilentlyContinue
        Get-Item -LiteralPath (Join-Path $ProjectRoot 'src\flutter_ffi.rs') -ErrorAction SilentlyContinue
    ) | Where-Object { $_ }
    $newestInput = $aotInputs | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
    $aotFile = Get-Item -LiteralPath $flutterAot
    if ($newestInput -and $aotFile.LastWriteTimeUtc -lt $newestInput.LastWriteTimeUtc) {
        throw "BUILD FAIL: Flutter app.so is older than $($newestInput.FullName). Rebuild Flutter AOT."
    }

    $bridgeHashes = [ordered]@{}
    foreach ($relativePath in @(
        'src\bridge_generated.rs',
        'src\bridge_generated.io.rs',
        'flutter\lib\generated_bridge.dart',
        'flutter\lib\generated_bridge.freezed.dart'
    )) {
        $path = Join-Path $ProjectRoot $relativePath
        if (Test-Path -LiteralPath $path) {
            $bridgeHashes[$relativePath] = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
        }
    }

    $manifest = [ordered]@{
        Schema = 1
        Version = $BuildBaseVersion
        Beta = $BetaNumber
        BuildDate = $BuildDate
        RustDllSha256 = (Get-FileHash -LiteralPath $rustLibrary -Algorithm SHA256).Hash
        FlutterAotSha256 = (Get-FileHash -LiteralPath $flutterAot -Algorithm SHA256).Hash
        FlutterAotLastWriteUtc = $aotFile.LastWriteTimeUtc.ToString('o')
        NewestFlutterInput = if ($newestInput) { $newestInput.FullName } else { '' }
        NewestFlutterInputLastWriteUtc = if ($newestInput) { $newestInput.LastWriteTimeUtc.ToString('o') } else { '' }
        BridgeSha256 = $bridgeHashes
    }
    $manifestPath = Join-Path $ReleaseDirectory 'data\masterdesk-build-manifest.json'
    $manifest | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $manifestPath -Encoding UTF8

    $verified = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    if ($verified.Beta -ne $BetaNumber -or
        $verified.BuildDate -ne $BuildDate -or
        $verified.RustDllSha256 -ne $manifest.RustDllSha256 -or
        $verified.FlutterAotSha256 -ne $manifest.FlutterAotSha256) {
        throw 'BUILD FAIL: Rust/Flutter build consistency manifest verification failed.'
    }
    Write-Host "Build consistency manifest: $manifestPath"
    Write-Host "RUST_DLL_SHA256=$($manifest.RustDllSha256)"
    Write-Host "FLUTTER_AOT_SHA256=$($manifest.FlutterAotSha256)"
}

function Build-IncrementalRustPortableExecutable {
    Push-Location $ProjectRoot
    try {
        $runnerExe = Join-Path $ReleaseDirectory 'MasterDesk.exe'
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
                $generatedAssetRoot = Join-Path $flutterProject 'build\flutter_assets'
                $releaseAssetRoot = Join-Path $ReleaseDirectory 'data\flutter_assets'
                New-Item -ItemType Directory -Path $releaseAssetRoot -Force | Out-Null
                Copy-Item `
                    -Path (Join-Path $generatedAssetRoot '*') `
                    -Destination $releaseAssetRoot `
                    -Recurse `
                    -Force
                Test-FlutterReleaseAssetBundle -ThrowOnFailure | Out-Null
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
        Copy-Item `
            -LiteralPath $rustLibrary `
            -Destination (Join-Path $ReleaseDirectory 'libmasterdesk.dll') `
            -Force
        Remove-LegacyWindowsBundleNames
        Copy-Item -LiteralPath (Join-Path $ProjectRoot 'LICENCE') -Destination $ReleaseDirectory -Force
        Copy-Item -LiteralPath (Join-Path $ProjectRoot 'CUSTOM_BUILD.md') -Destination $ReleaseDirectory -Force
        Write-BuildConsistencyManifest

        Push-Location (Join-Path $ProjectRoot 'libs\portable')
        try {
            Invoke-Checked $PythonExe @(
                '.\generate.py',
                '-f', '..\..\flutter\build\windows\x64\runner\Release',
                '-o', '.',
                '-e', '..\..\flutter\build\windows\x64\runner\Release\MasterDesk.exe'
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
} elseif (Test-FlutterBridgeNeedsGeneration) {
    Initialize-FlutterBridge
}
Initialize-DesktopDropWindowsPatch
if (-not $SkipVcpkg) {
    Install-VcpkgDependencies
}
if ($IncrementalRustOnly) {
    Build-IncrementalRustPortableExecutable
} else {
    Build-PortableExecutable
}
