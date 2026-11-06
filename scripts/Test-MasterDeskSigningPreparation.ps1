[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$out=Join-Path $repo ('artifacts\signing-tests\'+(Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
New-Item -ItemType Directory -Path $out | Out-Null
$compiler=Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if(-not (Test-Path -LiteralPath $compiler)){throw 'Framework C# compiler required for non-executed PE fixtures'}
$fixture=Join-Path $out 'fixture.cs'
@'
using System.Reflection;
[assembly:AssemblyProduct("Metadata test fixture")]
[assembly:AssemblyCompany("Original test publisher")]
[assembly:AssemblyCopyright("Original fixture copyright")]
public class VersionFixture { public static void Main() {} }
'@ | Set-Content -LiteralPath $fixture -Encoding UTF8
$stamp=Join-Path $PSScriptRoot 'Set-MasterDeskPeMetadata.ps1'
$passed=0
foreach($name in @('MasterDesk.exe','libmasterdesk.dll','dylib_virtual_display.dll')){
    $path=Join-Path $out $name
    $target=if($name.EndsWith('.dll')){'library'}else{'winexe'}
    & $compiler /nologo /target:$target "/out:$path" $fixture
    if($LASTEXITCODE){throw 'Fixture compilation failed'}
    & $stamp -Path $path -BetaNumber 106 -BuildDate '2026-11-06 12:34' | Out-Null
    $v=[Diagnostics.FileVersionInfo]::GetVersionInfo($path)
    if($v.ProductVersion -cne '1.4.9-10 beta 106' -or $v.FileVersion -cne $v.ProductVersion -or
       $v.FileMajorPart -ne 1 -or $v.FileMinorPart -ne 4 -or $v.FileBuildPart -ne 9 -or $v.FilePrivatePart -ne 106 -or
       $v.CompanyName -cne 'MasterDesk contributors' -or $v.Comments -cne 'Build date: 2026-11-06 12:34' -or
       -not $v.LegalCopyright.Contains('Original fixture copyright')){throw 'Version/attribution roundtrip failed'}
    $first=(Get-FileHash $path).Hash
    & $stamp -Path $path -BetaNumber 106 -BuildDate '2026-11-06 12:34' | Out-Null
    if((Get-FileHash $path).Hash -cne $first){throw 'Metadata stamping is not idempotent'}
    $passed++
}
$protected=Join-Path $out 'MasterDesk.exe'
$before=(Get-FileHash $protected).Hash
$refused=$false
try { & $stamp -Path $protected -BetaNumber 105 -BuildDate '2026-11-06 12:34' | Out-Null } catch {$refused=$true}
if(-not $refused -or (Get-FileHash $protected).Hash -cne $before){throw 'Issued-beta guard failed'}
$passed++
$refused=$false
try { & $stamp -Path (Join-Path $env:SystemRoot 'System32\kernel32.dll') -BetaNumber 106 -BuildDate '2026-11-06 12:34' | Out-Null } catch {$refused=$true}
if(-not $refused){throw 'Workspace boundary guard failed'}
$passed++
$foreign=Join-Path $out 'sciter.dll'
Copy-Item -LiteralPath $protected -Destination $foreign
$refused=$false
try { & $stamp -Path $foreign -BetaNumber 106 -BuildDate '2026-11-06 12:34' | Out-Null } catch {$refused=$true}
if(-not $refused -or (Get-FileHash $foreign).Hash -cne $before){throw 'Third-party filename guard failed'}
$passed++
$signedFixtureRoot=Join-Path $out 'signed-protected'
New-Item -ItemType Directory -Path $signedFixtureRoot | Out-Null
$signedFixture=Join-Path $signedFixtureRoot 'MasterDesk.exe'
Copy-Item -LiteralPath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -Destination $signedFixture
if((Get-AuthenticodeSignature -LiteralPath $signedFixture).Status -eq 'NotSigned'){throw 'Expected a signed/unverifiable system fixture; it will never be executed'}
$signedHash=(Get-FileHash $signedFixture).Hash
$refused=$false
try { & $stamp -Path $signedFixture -BetaNumber 106 -BuildDate '2026-11-06 12:34'|Out-Null } catch {$refused=$true}
if(-not $refused -or (Get-FileHash $signedFixture).Hash -cne $signedHash){throw 'Signed-file protection failed'}
$passed++
$parsed=@('Set-MasterDeskPeMetadata.ps1','Test-MasterDeskSigningSource.ps1',
    'Test-MasterDeskSigningPreparation.ps1','Build-CustomWindows.ps1','New-MasterDeskSigningInventory.ps1',
    'Test-DesktopDropWindowsPatch.ps1')
foreach($name in $parsed){$tokens=$null;$errors=$null;[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot $name),[ref]$tokens,[ref]$errors)|Out-Null;if($errors){throw ('Syntax error: '+$name)}}

# Isolated Git fixtures only: never stage/commit the actual user worktree.
function Git-Fixture([string]$Directory,[string[]]$Arguments){
    & git -C $Directory @Arguments 2>&1 | Out-Null
    if($LASTEXITCODE){throw 'Isolated source-gate fixture preparation failed'}
}
$source=Join-Path $out 'source-fixture'
$shared=Join-Path $out 'shared-fixture'
New-Item -ItemType Directory -Path $source,$shared | Out-Null
foreach($fixtureRoot in @($source,$shared)){
    Git-Fixture $fixtureRoot @('init','--quiet')
    'non-executable source fixture'|Set-Content (Join-Path $fixtureRoot 'README.txt')
    Git-Fixture $fixtureRoot @('add','README.txt')
    Git-Fixture $fixtureRoot @('-c','user.name=MasterDesk test fixture','-c','user.email=fixture@example.invalid','commit','--quiet','-m','fixture')
}
Git-Fixture $source @('-c','protocol.file.allow=always','submodule','add','--quiet',$shared,'libs/hbb_common')
$required=@('Cargo.lock','Cargo.toml','src/core_main.rs','src/platform/windows/install_import.rs',
    'flutter/lib/common/peer_thumbnail_cache.dart','scripts/Build-CustomWindows.ps1',
    'scripts/Set-MasterDeskPeMetadata.ps1','scripts/Test-MasterDeskSigningSource.ps1',
    'scripts/Test-MasterDeskSigningPreparation.ps1','scripts/New-MasterDeskSigningInventory.ps1',
    'scripts/Test-DesktopDropWindowsPatch.ps1',
    'docs/signing-x64-preparation.md',
    'SIGNING_POLICY.md','PRIVACY.md','NOTICE','.github/workflows/masterdesk-windows.yml')
foreach($relative in $required){
    $path=Join-Path $source $relative
    New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force|Out-Null
    'non-executable source fixture'|Set-Content -LiteralPath $path
}
Git-Fixture $source @('add','.')
Git-Fixture $source @('-c','user.name=MasterDesk test fixture','-c','user.email=fixture@example.invalid','commit','--quiet','-m','complete fixture')
$gate=Join-Path $PSScriptRoot 'Test-MasterDeskSigningSource.ps1'
& $gate -RepositoryRoot $source -OutputPath (Join-Path $out 'source-clean.json') | Out-Null
if((Get-Content (Join-Path $out 'source-clean.json') -Raw|ConvertFrom-Json).Status -cne 'PASS'){throw 'Clean source gate failed'}
'uncommitted fixture change'|Add-Content (Join-Path $source 'Cargo.toml')
$refused=$false
try{& $gate -RepositoryRoot $source -OutputPath (Join-Path $out 'source-dirty.json')|Out-Null}catch{$refused=$true}
if(-not $refused){throw 'Dirty source was accepted'}
'submodule fixture change'|Add-Content (Join-Path $source 'libs/hbb_common/README.txt')
& $gate -RepositoryRoot $source -OutputPath (Join-Path $out 'source-submodule.json') -ReportOnly | Out-Null
if(-not (Get-Content (Join-Path $out 'source-submodule.json') -Raw|ConvertFrom-Json).SubmoduleDirtyOrUninitialized){throw 'Submodule change was missed'}
# Synthetic, nonfunctional token-shaped fixture; no live credential is used.
('ghp_'+('A'*36))|Set-Content (Join-Path $source 'synthetic-token.txt')
Git-Fixture $source @('add','synthetic-token.txt')
& $gate -RepositoryRoot $source -OutputPath (Join-Path $out 'source-secret-indicator.json') -ReportOnly | Out-Null
$indicator=Get-Content (Join-Path $out 'source-secret-indicator.json') -Raw|ConvertFrom-Json
if($indicator.SecretIndicatorPaths -notcontains 'synthetic-token.txt' -or $indicator.Status -cne 'NOT_READY'){throw 'Secret-indicator guard failed'}
[ordered]@{Status='PASS';MetadataAndGuards=$passed;SourceGateCases=4;SyntaxFiles=$parsed;FixturesNeverExecuted=$true;Evidence=$out}|
    ConvertTo-Json -Depth 3 | Set-Content (Join-Path $out 'result.json')
Write-Output "PASS metadata/guards=$passed source-gates=4 syntax=$($parsed.Count) fixtures-not-executed evidence=$out"
