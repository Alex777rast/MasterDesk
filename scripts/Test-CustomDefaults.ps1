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

} finally {
    Pop-Location
}
