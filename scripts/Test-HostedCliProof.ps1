[CmdletBinding()]
param([Parameter(Mandatory)][string]$ArtifactRoot,
      [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{40}$')][string]$ExpectedCommit,
      [Parameter(Mandatory)][ValidateRange(108,65535)][int]$BetaNumber,
      [Parameter(Mandatory)][string]$OutputPath)
$ErrorActionPreference='Stop'
$root=(Resolve-Path -LiteralPath $ArtifactRoot).Path
$inventoryFiles=@(Get-ChildItem -LiteralPath $root -Recurse -File -Filter signing-inventory.json)
$gateFiles=@(Get-ChildItem -LiteralPath $root -Recurse -File -Filter source-gate.json)
$runners=@(Get-ChildItem -LiteralPath $root -Recurse -File -Filter MasterDesk.exe)
if($inventoryFiles.Count -ne 1 -or $gateFiles.Count -ne 1 -or $runners.Count -ne 1){throw 'Expected one reviewed package/payload/source-gate artifact set'}
$inventory=Get-Content -LiteralPath $inventoryFiles[0].FullName -Raw|ConvertFrom-Json
$gate=Get-Content -LiteralPath $gateFiles[0].FullName -Raw|ConvertFrom-Json
if($inventory.Beta -ne $BetaNumber -or $inventory.SourceCommit -cne $ExpectedCommit -or
   $gate.Status -cne 'PASS' -or $gate.Commit -cne $ExpectedCommit -or $gate.RootChangeCount -ne 0 -or
   $gate.SubmoduleDirtyOrUninitialized){throw 'Artifact source/beta attribution mismatch'}
if($inventory.Package -notmatch ("^MasterDesk-1\.4\.9-10-beta-$BetaNumber-\d{4}-\d{2}-\d{2}-RDS-x86_64\.exe$")){throw 'Unexpected package identity'}
$packages=@(Get-ChildItem -LiteralPath $root -Recurse -File|Where-Object {$_.Name -ceq $inventory.Package})
if($packages.Count -ne 1){throw 'Expected one exact package'}
$payload=$runners[0].DirectoryName
foreach($required in @('MasterDesk.exe','libmasterdesk.dll','dylib_virtual_display.dll',$inventory.Package)){
    if(@($inventory.Binaries|Where-Object {$_.Path -ceq $required -and $_.OwnerScope -ceq 'MasterDesk own build'}).Count -ne 1){throw 'Missing or duplicate owned binary inventory entry'}
}
foreach($binary in $inventory.Binaries){
    if([IO.Path]::IsPathRooted($binary.Path) -or $binary.Path -match ':' -or $binary.Path.Split([char[]]'/\') -contains '..'){throw 'Unsafe inventory path'}
    $path=if($binary.Path -ceq $inventory.Package){$packages[0].FullName}else{Join-Path $payload $binary.Path}
    if((Get-FileHash -LiteralPath $path).Hash -cne $binary.SHA256){throw ('Artifact hash mismatch: '+$binary.Path)}
    if($binary.OwnerScope -ceq 'MasterDesk own build'){
        $info=[Diagnostics.FileVersionInfo]::GetVersionInfo($path)
        if($info.ProductName -cne 'MasterDesk' -or $info.ProductVersion -cne "1.4.9-10 beta $BetaNumber" -or
           (Get-AuthenticodeSignature -LiteralPath $path).Status -ne 'NotSigned'){throw 'Owned PE identity/signature mismatch'}
    }
}
$cli=@{}
foreach($argument in @('--version','--build-date')){
    # Run only on the disposable GitHub-hosted verification VM. The portable
    # extraction wrapper, GUI, installation and network sessions are not run.
    $start=[Diagnostics.ProcessStartInfo]::new($runners[0].FullName,$argument)
    $start.WorkingDirectory=$payload;$start.UseShellExecute=$false;$start.CreateNoWindow=$true
    $start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
    $process=[Diagnostics.Process]::Start($start)
    if(-not $process.WaitForExit(30000)){$process.Kill();throw 'Runner CLI timed out; only its own probe process was stopped'}
    $stdout=$process.StandardOutput.ReadToEnd().Trim();$stderr=$process.StandardError.ReadToEnd().Trim()
    if($process.ExitCode -ne 0 -or $stderr){throw 'Runner/core CLI failed'}
    $cli[$argument]=$stdout
}
if($cli['--version'] -cne "1.4.9-10 beta $BetaNumber" -or $cli['--build-date'] -cne $inventory.BuildDate){throw 'Actual runner/core CLI identity mismatch'}
$report=[ordered]@{Status='PASS';BuildCommit=$ExpectedCommit;Beta=$BetaNumber;Package=$inventory.Package;
    PackageSHA256=(Get-FileHash -LiteralPath $packages[0].FullName).Hash;PayloadHashes='PASS';OwnedPEMetadata='PASS';
    Version=$cli['--version'];BuildDate=$cli['--build-date'];Execution='Disposable GitHub-hosted Windows VM; runner/core CLI only';
    RebuiltOrModifiedPackage=$false;Signed=$false;GuiInstallUpdateOrRemoteSessionRequested=$false;
    AcceptanceScope='Artifact content/PE/CLI proof, not GUI, installed update, network performance, SmartScreen or provider approval'}
New-Item -ItemType Directory -Path (Split-Path -Parent ([IO.Path]::GetFullPath($OutputPath))) -Force|Out-Null
$report|ConvertTo-Json -Depth 4|Set-Content -LiteralPath $OutputPath -Encoding utf8
$report|ConvertTo-Json -Depth 4
