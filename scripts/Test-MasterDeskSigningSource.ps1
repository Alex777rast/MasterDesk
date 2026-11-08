[CmdletBinding()]
param([string]$RepositoryRoot = (Join-Path $PSScriptRoot '..'),
      [Parameter(Mandatory)][string]$OutputPath, [switch]$ReportOnly)
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path -LiteralPath $RepositoryRoot).Path
function Read-Git([string]$Directory, [string[]]$Arguments) {
    $result = @(& git -C $Directory @Arguments 2>$null)
    if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect Git source provenance.' }
    return $result
}
$commit = [string](Read-Git $root @('rev-parse','HEAD'))
$required = @('Cargo.lock','Cargo.toml','src/core_main.rs','src/platform/windows/install_import.rs',
    'flutter/lib/common/peer_thumbnail_cache.dart','scripts/Build-CustomWindows.ps1',
    'scripts/Set-MasterDeskPeMetadata.ps1','scripts/Test-MasterDeskSigningSource.ps1',
    'scripts/Test-MasterDeskSigningPreparation.ps1','scripts/New-MasterDeskSigningInventory.ps1',
    'scripts/Test-DesktopDropWindowsPatch.ps1',
    'scripts/Test-CustomDefaults.ps1','scripts/Test-ServerDefaults.ps1','scripts/Test-DefaultsScope.ps1',
    'docs/signing-x64-preparation.md',
    'SIGNING_POLICY.md','PRIVACY.md','NOTICE','.github/workflows/masterdesk-windows.yml',
    '.github/workflows/masterdesk-signing-preflight.yml','.github/CODEOWNERS',
    'scripts/signing/pipeline.py','scripts/signing/preflight.py','scripts/signing/reserve_beta.py',
    'scripts/signing/request_state.py','scripts/signing/Read-TrustedSigningArtifact.ps1')
$missing = @()
$inputs = @(foreach ($name in $required) {
    $path = Join-Path $root $name
    $tracked = @(& git -C $root ls-files -- $name 2>$null).Count -eq 1
    if (-not $tracked -or -not (Test-Path -LiteralPath $path -PathType Leaf)) { $missing += $name }
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        [ordered]@{Path=$name;Tracked=$tracked;SHA256=(Get-FileHash -LiteralPath $path).Hash}
    }
})
$rootChanges = @(Read-Git $root @('status','--porcelain','--untracked-files=all'))
$submodules = @(Read-Git $root @('submodule','status','--recursive'))
$submoduleDirty = $false
$sourceDirectories = @([ordered]@{Directory=$root;Prefix=''})
foreach ($line in $submodules) {
    if ($line -match '^[+-U]') { $submoduleDirty = $true; continue }
    if ($line -match '^ [0-9a-f]{40} (\S+)') {
        $sourceDirectories += [ordered]@{Directory=(Join-Path $root $Matches[1]);Prefix=($Matches[1]+'/')}
        if (@(Read-Git (Join-Path $root $Matches[1]) @('status','--porcelain','--untracked-files=all')).Count) {
            $submoduleDirty = $true
        }
    }
}
if (-not @($submodules | Where-Object {$_ -match ' libs/hbb_common(?: |$)'}).Count) {
    $submoduleDirty = $true
}

# Match only high-confidence private-key/token indicators, never print values.
# This is a guard, not a replacement for a complete source/security review.
$pattern = '(-----BEGIN (RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----|gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{50,})'
$secretPaths = @()
$privateFiles = @()
foreach ($sourceDirectory in $sourceDirectories) {
    $indicators = @(& git -C $sourceDirectory.Directory grep -l -I -E -- $pattern 2>$null)
    if ($LASTEXITCODE -gt 1) { throw 'Source secret-indicator check could not run.' }
    $secretPaths += @($indicators | ForEach-Object {$sourceDirectory.Prefix+$_})
    $privateFiles += @(Read-Git $sourceDirectory.Directory @('ls-files') | Where-Object {
        $_ -match '(?i)(^|/)\.env$|\.(pfx|p12)$|(^|/)id_(rsa|ed25519)$'
    } | ForEach-Object {$sourceDirectory.Prefix+$_})
}
$clean = $rootChanges.Count -eq 0 -and -not $submoduleDirty -and $missing.Count -eq 0 -and
    $secretPaths.Count -eq 0 -and $privateFiles.Count -eq 0
$report = [ordered]@{
    Schema=1;Status=$(if($clean){'PASS'}else{'NOT_READY'});Commit=$commit.Trim();
    RootChangeCount=$rootChanges.Count;SubmoduleDirtyOrUninitialized=$submoduleDirty;
    MissingOrUntrackedRequiredInputs=$missing;RequiredInputs=$inputs;
    SecretIndicatorPaths=$secretPaths;ForbiddenPrivateFilePaths=$privateFiles;
    SecretScanCoverage='Tracked root and initialized recursive submodules; complete manual review still required';
    ProviderApproval='NOT_VERIFIED';SourcePublishedOrSigningRequested=$false
}
$parent = Split-Path -Parent ([IO.Path]::GetFullPath($OutputPath))
New-Item -ItemType Directory -Path $parent -Force | Out-Null
$report | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $OutputPath -Encoding utf8
if (-not $clean -and -not $ReportOnly) { throw 'Signing source gate failed; see paths/counts in the report. No signing request is allowed.' }
Write-Output ("SOURCE_GATE={0} report={1}" -f $report.Status,$OutputPath)
