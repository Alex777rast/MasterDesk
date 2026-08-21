[CmdletBinding()]
param()

$workspace = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))

function Set-FirstExistingEnvironmentPath {
    param(
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] [string[]]$Candidates,
        [string]$RequiredChild = ''
    )

    if ([Environment]::GetEnvironmentVariable($Name, 'Process')) {
        return
    }
    foreach ($candidate in $Candidates) {
        $resolved = [System.IO.Path]::GetFullPath($candidate)
        $probe = if ($RequiredChild) { Join-Path $resolved $RequiredChild } else { $resolved }
        if (Test-Path -LiteralPath $probe) {
            [Environment]::SetEnvironmentVariable($Name, $resolved, 'Process')
            return
        }
    }
}

Set-FirstExistingEnvironmentPath -Name 'MASTERDESK_LLVM_BIN' -Candidates @(
    (Join-Path $workspace '.tools\llvm-15.0.6\bin'),
    (Join-Path $workspace '.tools.partial-transfer\llvm-15.0.6\bin')
) -RequiredChild 'clang.exe'
Set-FirstExistingEnvironmentPath -Name 'MASTERDESK_VCPKG_ROOT' -Candidates @(
    (Join-Path $workspace '.tools\vcpkg'),
    (Join-Path $workspace '.tools.partial-transfer\vcpkg')
) -RequiredChild 'vcpkg.exe'
Set-FirstExistingEnvironmentPath -Name 'MASTERDESK_FLUTTER_ROOT' -Candidates @(
    (Join-Path $workspace '.tools\flutter'),
    (Join-Path $workspace '.tools.partial-transfer\flutter')
) -RequiredChild 'bin\flutter.bat'
Set-FirstExistingEnvironmentPath -Name 'MASTERDESK_PUB_CACHE' -Candidates @(
    (Join-Path $workspace '.tools\pub-cache'),
    (Join-Path $workspace '.tools.partial-transfer\pub-cache')
)
Set-FirstExistingEnvironmentPath -Name 'MASTERDESK_PYTHON' -Candidates @(
    (Join-Path $env:USERPROFILE '.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe')
)

if ($env:MASTERDESK_LLVM_BIN) {
    $env:LIBCLANG_PATH = $env:MASTERDESK_LLVM_BIN
}
if ($env:MASTERDESK_VCPKG_ROOT) {
    $env:VCPKG_ROOT = $env:MASTERDESK_VCPKG_ROOT
}

$pathCandidates = @(
    (Join-Path $env:ProgramFiles 'Git\cmd'),
    (Join-Path $env:USERPROFILE '.cargo\bin')
)
if ($env:MASTERDESK_PYTHON) {
    $pathCandidates += Split-Path -Parent $env:MASTERDESK_PYTHON
}
foreach ($candidate in $pathCandidates) {
    if ((Test-Path -LiteralPath $candidate) -and
        -not (($env:Path -split ';') -contains $candidate)) {
        $env:Path = "$candidate;$env:Path"
    }
}
