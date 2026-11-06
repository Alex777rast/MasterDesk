[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$output=Join-Path $repo ('artifacts/defaults-scope-tests/'+(Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
New-Item -ItemType Directory -Path $output | Out-Null
$tokens=$null;$parseErrors=$null
$gate=Join-Path $PSScriptRoot 'Test-CustomDefaults.ps1'
$ast=[Management.Automation.Language.Parser]::ParseFile($gate,[ref]$tokens,[ref]$parseErrors)
if($parseErrors){throw 'Defaults gate syntax failure'}
$scope=@($ast.ParamBlock.Parameters|Where-Object {$_.Name.VariablePath.UserPath -ceq 'ClientOnly'})
if($scope.Count -ne 1 -or $scope[0].DefaultValue -or $scope[0].StaticType -ne [Management.Automation.SwitchParameter]){throw 'Full defaults validation must remain the default'}
$calls=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.InvocationOperator -eq 'Ampersand' -and $node.Extent.Text -match "Test-ServerDefaults\.ps1"},$true))
if($calls.Count -ne 1){throw 'Expected one explicit server-gate invocation'}
$guard=$calls[0].Parent
while($guard -and $guard -isnot [Management.Automation.Language.IfStatementAst]){$guard=$guard.Parent}
if(-not $guard -or $guard.Clauses.Count -ne 1 -or $guard.Clauses[0].Item1.Extent.Text.Trim() -cne '-not $ClientOnly'){throw 'Server checks are not preserved behind the explicit client-only scope'}
$source=[IO.File]::ReadAllText($gate)
if($source -match 'deploy[\\/]masterdesk-(server|api)' -or $source -notmatch 'custom_defaults' -or
   $source -notmatch 'masterdesk_release_runs_portable_by_default' -or $source -notmatch 'verify_masterdesk_update_package'){throw 'Client gate lost a required client check or still reads deployment files'}
# Source assertions and Cargo tests remain outside the server-only guard.
if($guard.Extent.Text -match 'cargo\.exe|verify_masterdesk_update_package|masterdesk_release_runs_portable_by_default'){throw 'Client tests were accidentally scoped out'}
$serverGate=Join-Path $PSScriptRoot 'Test-ServerDefaults.ps1'
$passed=1
$aotGuard=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.IfStatementAst] -and $node.Extent.Text -match 'The targeted Dart UI path does not refresh only the cached Flutter runner'},$true))
if($aotGuard.Count -ne 1){throw 'Expected one incremental AOT source guard'}
$buildSource=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Build-CustomWindows.ps1'))
& {param($buildScript,$guardText) & ([ScriptBlock]::Create($guardText))} $buildSource $aotGuard[0].Extent.Text
$passed++
$refused=$false
try{& {param($buildScript,$guardText) & ([ScriptBlock]::Create($guardText))} $buildSource.Replace('windows-x64 Release','windows-x64 Debug') $aotGuard[0].Extent.Text}catch{$refused=$true}
if(-not $refused){throw 'Incremental AOT guard accepted a non-release backend'}
$passed++
$guardCases=@(
    @{Message='Portable MasterDesk can start a second server';Variable='core';Path='src/core_main.rs';Old='should_use_installed_server_identity()';New='incorrect_identity_route()'},
    @{Message='The updater does not wait for the portable process before reopening';Variable='windows';Path='src/platform/windows.rs';Old='vec!["--wait-for-portable", updater_pid]';New='Vec::new()'}
)
foreach($case in $guardCases){
    $message=$case.Message
    $sourceGuard=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.IfStatementAst] -and $node.Extent.Text -match [regex]::Escape($message)},$true))
    if($sourceGuard.Count -ne 1){throw 'Expected exactly one current client source guard'}
    $original=[IO.File]::ReadAllText((Join-Path $repo $case.Path))
    foreach($bad in @($false,$true)){
        $probe=if($bad){$original.Replace($case.Old,$case.New)}else{$original}
        if($bad -and $probe -ceq $original){throw 'Negative client fixture did not change the guarded path'}
        $refused=$false
        try{& {param($coreMain,$windowsPlatform,$text) & ([ScriptBlock]::Create($text))} $probe $probe $sourceGuard[0].Extent.Text}catch{$refused=$true}
        if($refused -ne $bad){throw 'Client route/handoff source guard regression'}
        $passed++
    }
}
function New-ScopeFixture([string]$Name,[string]$Patch,[string]$Version='1.4.9-10',[string]$URL='https://example.invalid/release',[bool]$PythonPass=$true){
    $fixture=Join-Path $output $Name
    $server=Join-Path $fixture 'deploy/masterdesk-server'
    $api=Join-Path $fixture 'deploy/masterdesk-api'
    New-Item -ItemType Directory -Path $server,$api | Out-Null
    $Patch|Set-Content -LiteralPath (Join-Path $server 'masterdesk-server-a7736be.patch')
    'non-executed source fixture'|Set-Content -LiteralPath (Join-Path $server 'Apply-MasterDeskServerPatch.ps1')
    'non-production fixture'|Set-Content -LiteralPath (Join-Path $server 'Caddyfile.example')
    @{version=$Version;url=$URL}|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $api 'latest.json')
    "import unittest`nclass ScopeFixture(unittest.TestCase):`n    def test_fixture(self):`n        self.assertTrue($($PythonPass.ToString()))"|Set-Content -LiteralPath (Join-Path $api 'test_fixture.py')
    return $fixture
}
$valid="require-relay-ticket relay_ed25519 CONSUMED_TICKETS MAX_ACTIVE_PER_IP DEVICE_LEASE_TIMEOUT`nif !relay_security_required() { return true; }"
$clean=New-ScopeFixture 'valid' $valid
& $serverGate -RepositoryRoot $clean *> (Join-Path $output 'valid.log')
$passed++
$cases=@(
    @{Name='missing-patch';Patch='';Expected='Server security patch is missing'},
    @{Name='missing-compatibility';Patch=$valid.Replace('return true;','return false;');Expected='Server compatibility mode'},
    @{Name='bad-version';Patch=$valid;Version='invalid';Expected='manifest version'},
    @{Name='insecure-url';Patch=$valid;URL='http://example.invalid/';Expected='must use HTTPS'},
    @{Name='failing-service-test';Patch=$valid;PythonPass=$false;Expected='Update-manifest tests failed'}
)
foreach($case in $cases){
    $fixtureArguments=@{Name=$case.Name;Patch=$case.Patch}
    foreach($key in @('Version','URL','PythonPass')){if($case.ContainsKey($key)){$fixtureArguments[$key]=$case[$key]}}
    $fixture=New-ScopeFixture @fixtureArguments
    $refused=$false
    try{& $serverGate -RepositoryRoot $fixture *> (Join-Path $output ($case.Name+'.log'))}catch{
        if($_.Exception.Message -notmatch [regex]::Escape($case.Expected)){throw}
        $refused=$true
    }
    if(-not $refused){throw ('Invalid server fixture accepted: '+$case.Name)}
    $passed++
}
Write-Output "PASS defaults-scope=$passed (full-by-default guard, incremental AOT guard, valid server/API fixture, fail-closed fixtures) evidence=$output"
