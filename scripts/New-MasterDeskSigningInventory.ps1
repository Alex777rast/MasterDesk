[CmdletBinding()]
param([Parameter(Mandatory)][ValidateRange(106,65535)][int]$BetaNumber,
      [Parameter(Mandatory)][string]$OutputDirectory)
$ErrorActionPreference='Stop'
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$payload=Join-Path $repo 'flutter\build\windows\x64\runner\Release'
$manifest=Get-Content -LiteralPath (Join-Path $payload 'data\masterdesk-build-manifest.json') -Raw | ConvertFrom-Json
if($manifest.Beta -ne $BetaNumber){throw 'Payload beta mismatch'}
$expectedName="MasterDesk-1.4.9-10-beta-$BetaNumber-$($manifest.BuildDate.Substring(0,10))-RDS-x86_64.exe"
$package=Get-Item -LiteralPath (Join-Path $repo "dist\$expectedName")
$owned=@('MasterDesk.exe','libmasterdesk.dll','dylib_virtual_display.dll')
$pe=@(foreach($file in @($package)+@(Get-ChildItem -LiteralPath $payload -Recurse -File | Where-Object {$_.Extension -in '.exe','.dll','.sys'})){
    $isPackage=$file.FullName -ceq $package.FullName
    $relative=if($isPackage){$file.Name}else{$file.FullName.Substring($payload.Length+1).Replace('\','/')}
    if($file.Name -ieq 'sciter.dll' -or $file.Extension -ieq '.sys' -or $relative -match '(?i)usbmmidd|amyuni'){
        throw 'Unreviewed Sciter/driver binary is outside the x64 signing scope'
    }
    $own=$isPackage -or $relative -cin $owned
    $v=[Diagnostics.FileVersionInfo]::GetVersionInfo($file.FullName)
    $signature=(Get-AuthenticodeSignature -LiteralPath $file.FullName).Status.ToString()
    if($own -and ($v.ProductName -cne 'MasterDesk' -or $v.ProductVersion -cne "1.4.9-10 beta $BetaNumber" -or
                 $v.CompanyName -cne 'MasterDesk contributors' -or $signature -cne 'NotSigned')){
        throw ('Unsigned own-binary metadata/signature mismatch: '+$relative)
    }
    [ordered]@{Path=$relative;OwnerScope=$(if($own){'MasterDesk own build'}else{'Upstream component; do not sign with project certificate'});
        Size=$file.Length;SHA256=(Get-FileHash -LiteralPath $file.FullName).Hash;
        Product=$v.ProductName;Version=$v.ProductVersion;Company=$v.CompanyName;Signature=$signature}
})
foreach($name in $owned){if(-not @($pe|Where-Object{$_.Path -ceq $name}).Count){throw ('Missing own payload binary: '+$name)}}
foreach($name in @('NOTICE','PRIVACY.md','LICENCE')){if(-not(Test-Path -LiteralPath (Join-Path $payload $name))){throw ('Missing bundled notice: '+$name)}}
if((Get-FileHash -LiteralPath (Join-Path $payload 'libmasterdesk.dll')).Hash -cne $manifest.RustDllSha256){throw 'Stamped DLL does not match build manifest'}
$rootDirty=@(& git -C $repo status --porcelain --untracked-files=all).Count -gt 0
$sharedDirty=@(& git -C (Join-Path $repo 'libs/hbb_common') status --porcelain --untracked-files=all).Count -gt 0
$report=[ordered]@{Schema=1;Status='UNSIGNED_PREPARATION';Beta=$BetaNumber;BuildDate=$manifest.BuildDate;
    SourceCommit=([string](& git -C $repo rev-parse HEAD)).Trim();
    SourceCommitMeaning=$(if($rootDirty -or $sharedDirty){'Historical base only; NOT an exact source snapshot'}else{'Checked-out source commit; origin still requires provider verification'});
    RootWorktreeDirty=$rootDirty;SharedWorktreeDirty=$sharedDirty;
    GitHubHostedOrigin='Must be verified by SignPath connector, not this local JSON';
    Package=$expectedName;Binaries=$pe;ProviderApproval='NOT_VERIFIED';SigningRequested=$false;
    DependencyLicenseReview='PENDING: inventory is not a license/SBOM clearance';
    FutureSigningOrder=@('Own payload binaries only','Recompute signed payload manifest and pack','Outer portable package','Final verification and hashes')}
New-Item -ItemType Directory -Path $OutputDirectory -Force|Out-Null
$report|ConvertTo-Json -Depth 5|Set-Content -LiteralPath (Join-Path $OutputDirectory 'signing-inventory.json') -Encoding utf8
$hash=(Get-FileHash -LiteralPath $package.FullName).Hash
"$hash  $expectedName"|Set-Content -LiteralPath (Join-Path $OutputDirectory 'SHA256.txt') -Encoding ascii
Write-Output "PASS unsigned x64 inventory=$OutputDirectory beta=$BetaNumber package=$expectedName"
