[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$ProjectRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$VcpkgRoot = Join-Path $ProjectRoot '.tools\vcpkg'
$CargoBin = Join-Path $env:USERPROFILE '.cargo\bin'
$LlvmBin = 'C:\Program Files\LLVM\bin'
$VsDevCmd = 'C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\Common7\Tools\VsDevCmd.bat'

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
