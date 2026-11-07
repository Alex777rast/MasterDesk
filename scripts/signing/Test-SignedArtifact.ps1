[CmdletBinding()]
param([Parameter(Mandatory)][string]$Path,
      [Parameter(Mandatory)][ValidatePattern('^[A-Fa-f0-9]{64}$')][string]$ExpectedCertificateSha256,
      [Parameter(Mandatory)][string]$ExpectedSubject,
      [Parameter(Mandatory)][string]$ExpectedProductVersion,
      [Parameter(Mandatory)][string]$OutputPath)
$ErrorActionPreference='Stop'
$file=Get-Item -LiteralPath $Path
if($file.Extension -notin '.exe','.dll' -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Expected an ordinary PE file'}
$signature=Get-AuthenticodeSignature -LiteralPath $file.FullName
if($signature.Status -ne 'Valid' -or -not $signature.SignerCertificate -or -not $signature.TimeStamperCertificate){
    throw 'Valid Authenticode signature AND timestamp required'
}
$certificate=$signature.SignerCertificate
$fingerprint=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($certificate.RawData))
if($fingerprint -ine $ExpectedCertificateSha256 -or $certificate.Subject -cne $ExpectedSubject){throw 'Unexpected signer identity/certificate'}
$eku=@($certificate.Extensions | Where-Object {$_.Oid.Value -eq '2.5.29.37'} | ForEach-Object {$_.EnhancedKeyUsages.Value})
if($eku -notcontains '1.3.6.1.5.5.7.3.3'){throw 'Code-signing EKU missing'}
$info=[Diagnostics.FileVersionInfo]::GetVersionInfo($file.FullName)
if($info.ProductName -cne 'MasterDesk' -or $info.ProductVersion -cne $ExpectedProductVersion){throw 'Signed PE identity mismatch'}
$signtool=@(Get-ChildItem -Path "${env:ProgramFiles(x86)}\Windows Kits\10\bin\*\x64\signtool.exe" -File | Sort-Object FullName -Descending)[0]
if(-not $signtool){throw 'Windows SDK signtool required; cannot skip chain/timestamp verification'}
# /pa uses Authenticode policy, /all checks all signatures; /tw warns without
# timestamp. Nonzero (including warning2) is failure. OS verifies timestamped
# lifetime/revocation semantics, not a naive current-date certificate check.
& $signtool.FullName verify /pa /all /tw /v $file.FullName | Out-Null
if($LASTEXITCODE -ne 0){throw 'Authenticode chain/timestamp verification failed or warned'}
$report=[ordered]@{Status='PASS';Path=$file.Name;SHA256=(Get-FileHash -LiteralPath $file.FullName).Hash;
    SignerSubject=$certificate.Subject;CertificateSHA256=$fingerprint;TimestampPresent=$true;
    Verification='Windows Authenticode + SDK signtool /pa /all /tw; online trust/revocation environment required';SignedOrModifiedFile=$false}
New-Item -ItemType Directory -Path (Split-Path -Parent ([IO.Path]::GetFullPath($OutputPath))) -Force|Out-Null
if(Test-Path -LiteralPath $OutputPath){throw 'Do not overwrite signature evidence'}
$report|ConvertTo-Json -Depth 3|Set-Content -LiteralPath $OutputPath -Encoding utf8
Write-Output "PASS signature verification=$OutputPath"
