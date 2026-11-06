[CmdletBinding()]
param(
    [switch]$SkipVcpkg,
    [ValidateRange(0, 999999)]
    [int]$BetaNumber = 0,
    [string]$OutputFileName = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Initialize-MasterDeskBuildEnvironment.ps1')

$ProjectRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$ToolsRoot = Join-Path $ProjectRoot '.tools'
$VcpkgRoot = if ($env:MASTERDESK_VCPKG_X86_ROOT) {
    [System.IO.Path]::GetFullPath($env:MASTERDESK_VCPKG_X86_ROOT)
} else {
    Join-Path $ToolsRoot 'vcpkg-x86'
}
$VcpkgExe = Join-Path $VcpkgRoot 'vcpkg.exe'
$PythonExe = if ($env:MASTERDESK_PYTHON) {
    [System.IO.Path]::GetFullPath($env:MASTERDESK_PYTHON)
} else {
    $pythonCommand = Get-Command python.exe -ErrorAction SilentlyContinue
    if (-not $pythonCommand) {
        throw 'Python was not found. Set MASTERDESK_PYTHON to python.exe.'
    }
    $pythonCommand.Source
}
$CargoExe = Join-Path $env:USERPROFILE '.cargo\bin\cargo.exe'
$RustupExe = Join-Path $env:USERPROFILE '.cargo\bin\rustup.exe'
$LlvmBin = if ($env:MASTERDESK_LLVM_X86_BIN) {
    [System.IO.Path]::GetFullPath($env:MASTERDESK_LLVM_X86_BIN)
} else {
    Join-Path $ToolsRoot 'llvm-15.0.6-x86\bin'
}
$GitCommand = Get-Command git.exe -ErrorAction Stop
$GitBin = [System.IO.Path]::GetDirectoryName($GitCommand.Source)
$VsWhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$VsDevCmd = if ($env:MASTERDESK_VSDEVCMD) {
    [System.IO.Path]::GetFullPath($env:MASTERDESK_VSDEVCMD)
} elseif (Test-Path -LiteralPath $VsWhere) {
    & $VsWhere `
        -latest `
        -products '*' `
        -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
        -find 'Common7\Tools\VsDevCmd.bat' |
        Select-Object -First 1
} else {
    ''
}

$TargetTriple = 'i686-pc-windows-msvc'
$RustToolchain = 'nightly-2023-10-13-i686-pc-windows-msvc'
$VcpkgTriplet = 'x86-windows-static'
$ExpectedVcpkgCommit = '120deac3062162151622ca4860575a33844ba10b'
$ExpectedLlvmVersion = '15.0.6'
$ExpectedLlvmLibClangSha256 = '7B8B34A672F4DDD795FBF2057722EF4B0B5560AD5DDD3557C7B758BA91E45CC4'
$ExpectedSciterCommit = 'f33df075d9eb2f8d252cb88f1b2c8096e56197ed'
$ExpectedSciterSha256 = '285F3E6A051A7C61845CD7E4D2120781B6BDF411239F70A85C65B38A52D38F28'
$ExpectedRustSciterCommit = '674e07d3066ca9a92ced3816203ab6b652629d1e'
$BuildBaseVersion = '1.4.9-10'
$BuildDate = Get-Date -Format 'yyyy-MM-dd HH:mm'
$BuildDateForFileName = Get-Date -Format 'yyyy-MM-dd'
$DistDirectory = Join-Path $ProjectRoot 'dist'

if ($BetaNumber -eq 0) {
    $existingBetaNumbers = @()
    if (Test-Path -LiteralPath $DistDirectory) {
        $existingBetaNumbers = @(Get-ChildItem -LiteralPath $DistDirectory -File -Filter 'MasterDesk-*-beta-*-*-RDS-*.exe' |
            ForEach-Object {
                if ($_.Name -match '-beta-(\d+)-\d{4}-\d{2}-\d{2}-RDS-(?:x86_64|x86-sciter)\.exe$') {
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

$expectedOutputFileName = "MasterDesk-$BuildBaseVersion-beta-$BetaNumber-$BuildDateForFileName-RDS-x86-sciter.exe"
if ([string]::IsNullOrWhiteSpace($OutputFileName)) {
    $OutputFileName = $expectedOutputFileName
} elseif ($OutputFileName -cne $expectedOutputFileName) {
    throw "OutputFileName must follow the build identity rule: $expectedOutputFileName"
}
$OutputExe = Join-Path $DistDirectory $OutputFileName
$ArtifactDirectory = Join-Path $ProjectRoot "artifacts\build\beta-$BetaNumber-x86-sciter-$BuildDateForFileName"
$PayloadDirectory = Join-Path $ArtifactDirectory 'payload'
$SciterCacheDirectory = Join-Path $ToolsRoot 'sciter\x86'
$SciterDll = Join-Path $SciterCacheDirectory "sciter-$ExpectedSciterCommit.dll"

function Invoke-Checked {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter()][string[]]$Arguments = @()
    )

    Write-Host "`n> $FilePath $($Arguments -join ' ')"
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
    if ([string]::IsNullOrWhiteSpace($VsDevCmd) -or -not (Test-Path -LiteralPath $VsDevCmd)) {
        throw 'Visual Studio developer environment with x86 C++ tools was not found.'
    }
    $environmentLines = & $env:COMSPEC /s /c "`"$VsDevCmd`" -arch=x86 -host_arch=x64 >nul && set"
    if ($LASTEXITCODE -ne 0) {
        throw 'VsDevCmd.bat failed for the x86 target.'
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
}

function Assert-Toolchain {
    $clangExe = Join-Path $LlvmBin 'clang.exe'
    $libClangDll = Join-Path $LlvmBin 'libclang.dll'
    foreach ($required in @($CargoExe, $RustupExe, $PythonExe, $clangExe, $libClangDll)) {
        if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
            throw "Required build tool was not found: $required"
        }
    }
    $reader = [System.IO.BinaryReader]::new([System.IO.File]::OpenRead($libClangDll))
    try {
        $reader.BaseStream.Position = 0x3c
        $peOffset = $reader.ReadInt32()
        $reader.BaseStream.Position = $peOffset + 4
        $machine = $reader.ReadUInt16()
    } finally {
        $reader.Dispose()
    }
    if ($machine -ne 0x014c) {
        throw "The x86 build requires a 32-bit libclang.dll (PE machine 0x014c): $libClangDll"
    }
    $actualLibClangHash = (Get-FileHash -LiteralPath $libClangDll -Algorithm SHA256).Hash
    if ($actualLibClangHash -cne $ExpectedLlvmLibClangSha256) {
        throw "The x86 build requires LLVM $ExpectedLlvmVersion libclang.dll (actual SHA-256: $actualLibClangHash)"
    }
    $installedToolchains = & $RustupExe toolchain list
    if (-not ($installedToolchains | Select-String -SimpleMatch $RustToolchain)) {
        throw "Install the pinned x86 Rust toolchain first: rustup toolchain install $RustToolchain --profile minimal"
    }
    if (-not (Select-String -LiteralPath (Join-Path $ProjectRoot 'Cargo.lock') -Quiet -SimpleMatch $ExpectedRustSciterCommit)) {
        throw "Cargo.lock does not pin rust-sciter dyn_x86 to $ExpectedRustSciterCommit"
    }
}

function Assert-Vcpkg {
    if (-not (Test-Path -LiteralPath $VcpkgExe -PathType Leaf)) {
        throw "Pinned x86 vcpkg was not found: $VcpkgExe"
    }
    $actualCommit = (& git -C $VcpkgRoot rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0 -or $actualCommit -cne $ExpectedVcpkgCommit) {
        throw "x86 vcpkg must be at $ExpectedVcpkgCommit (actual: $actualCommit)"
    }
    if (-not (Test-Path -LiteralPath (Join-Path $VcpkgRoot 'triplets\community\x86-windows-static.cmake'))) {
        throw 'The x86-windows-static vcpkg triplet is missing.'
    }
}

function Install-VcpkgDependencies {
    Invoke-Checked $VcpkgExe @(
        'install',
        '--triplet', $VcpkgTriplet,
        "--x-install-root=$(Join-Path $VcpkgRoot 'installed')"
    )
}

function Initialize-SciterRuntime {
    New-Item -ItemType Directory -Force -Path $SciterCacheDirectory | Out-Null
    if (-not (Test-Path -LiteralPath $SciterDll -PathType Leaf)) {
        $url = "https://raw.githubusercontent.com/c-smile/sciter-sdk/$ExpectedSciterCommit/bin.win/x32/sciter.dll"
        Invoke-Checked (Join-Path $env:SystemRoot 'System32\curl.exe') @(
            '-L', '--fail', '--retry', '3', '--output', $SciterDll, $url
        )
    }
    $actualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $SciterDll).Hash
    if ($actualHash -cne $ExpectedSciterSha256) {
        throw "Unexpected x86 Sciter SHA-256: $actualHash"
    }
}

if (Test-Path -LiteralPath $OutputExe) {
    throw "Refusing to overwrite an existing candidate: $OutputExe"
}
if (Test-Path -LiteralPath (Join-Path $ArtifactDirectory 'build-result.json')) {
    throw "Refusing to reuse a completed build-artifact directory: $ArtifactDirectory"
}

Assert-Toolchain
Assert-Vcpkg
Import-VisualStudioEnvironment

# VsDevCmd points VCPKG_ROOT at the Visual Studio copy. Restore the dedicated,
# pinned x86 checkout after importing the compiler environment.
$env:VCPKG_ROOT = $VcpkgRoot
$env:VCPKG_INSTALLED_ROOT = Join-Path $VcpkgRoot 'installed'
$env:VCPKG_DEFAULT_TRIPLET = $VcpkgTriplet
$env:VCPKG_DEFAULT_HOST_TRIPLET = $VcpkgTriplet
$env:LIBCLANG_PATH = $LlvmBin
$env:MASTERDESK_BUILD_BETA_NUMBER = $BetaNumber.ToString([System.Globalization.CultureInfo]::InvariantCulture)
$env:MASTERDESK_BUILD_DATE = $BuildDate
$env:Path = "$(Join-Path $env:USERPROFILE '.cargo\bin');$GitBin;$LlvmBin;$([System.IO.Path]::GetDirectoryName($PythonExe));$env:Path"

Write-Host 'Pinned x86 toolchain:'
Write-Host "MasterDesk build: $BuildBaseVersion beta $BetaNumber ($BuildDate)"
Invoke-Checked $CargoExe @("+$RustToolchain", '--version')
Invoke-Checked (Join-Path $LlvmBin 'clang.exe') @('--version')
Invoke-Checked $PythonExe @('--version')

if (-not $SkipVcpkg) {
    Install-VcpkgDependencies
}
Initialize-SciterRuntime

New-Item -ItemType Directory -Force -Path $PayloadDirectory | Out-Null
Push-Location $ProjectRoot
try {
    Invoke-Checked $PythonExe @('res\inline-sciter.py')
    Invoke-Checked $CargoExe @(
        "+$RustToolchain",
        'build', '--locked', '--release', '--bins',
        '--target', $TargetTriple,
        '--features', 'inline,vram,hwcodec'
    )
} finally {
    Pop-Location
}

$BuiltExe = Join-Path $ProjectRoot "target\$TargetTriple\release\rustdesk.exe"
if (-not (Test-Path -LiteralPath $BuiltExe -PathType Leaf)) {
    throw "The x86 application was not produced: $BuiltExe"
}
Copy-Item -LiteralPath $BuiltExe -Destination (Join-Path $PayloadDirectory 'MasterDesk.exe')
Copy-Item -LiteralPath $SciterDll -Destination (Join-Path $PayloadDirectory 'sciter.dll')
@(
    '# MasterDesk self-hosted Windows build'
    "Version: $BuildBaseVersion beta $BetaNumber"
    "Build date: $BuildDate"
    'Architecture: x86 (i686-pc-windows-msvc)'
    'UI runtime: Sciter x86'
) | Set-Content -LiteralPath (Join-Path $PayloadDirectory 'CUSTOM_BUILD.md') -Encoding UTF8

$previousToolchain = $env:RUSTUP_TOOLCHAIN
try {
    $env:RUSTUP_TOOLCHAIN = $RustToolchain
    Push-Location (Join-Path $ProjectRoot 'libs\portable')
    try {
        Invoke-Checked $PythonExe @('-m', 'pip', 'install', '-r', '.\requirements.txt')
        Invoke-Checked $PythonExe @(
            'generate.py',
            '-f', $PayloadDirectory,
            '-o', '.',
            '-e', (Join-Path $PayloadDirectory 'MasterDesk.exe'),
            '-t', $TargetTriple
        )
    } finally {
        Pop-Location
    }
} finally {
    $env:RUSTUP_TOOLCHAIN = $previousToolchain
}

$PackedExe = Join-Path $ProjectRoot "target\$TargetTriple\release\rustdesk-portable-packer.exe"
if (-not (Test-Path -LiteralPath $PackedExe -PathType Leaf)) {
    throw "The x86 portable package was not produced: $PackedExe"
}
New-Item -ItemType Directory -Force -Path $DistDirectory | Out-Null
Copy-Item -LiteralPath $PackedExe -Destination $OutputExe

$result = [ordered]@{
    output = $OutputExe
    sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $OutputExe).Hash
    architecture = 'x86'
    target = $TargetTriple
    ui_runtime = 'Sciter'
    beta = $BetaNumber
    build_date = $BuildDate
    rust_toolchain = $RustToolchain
    llvm_version = $ExpectedLlvmVersion
    llvm_libclang_sha256 = $ExpectedLlvmLibClangSha256
    vcpkg_commit = $ExpectedVcpkgCommit
    rust_sciter_commit = $ExpectedRustSciterCommit
    sciter_commit = $ExpectedSciterCommit
    sciter_sha256 = $ExpectedSciterSha256
}
$result | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $ArtifactDirectory 'build-result.json') -Encoding UTF8
$result | Format-List
