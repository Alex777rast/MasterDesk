[CmdletBinding()]
param([Parameter(Mandatory)][string]$OutputDirectory)
$ErrorActionPreference='Stop'
if(Test-Path -LiteralPath $OutputDirectory){throw 'Fresh evidence directory required'}
New-Item -ItemType Directory -Path $OutputDirectory|Out-Null
$parsed=@(Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.ps1' -File)
foreach($file in $parsed){
    $tokens=$null;$errors=$null
    [Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors)|Out-Null
    if($errors){throw "PowerShell syntax failure: $($file.Name)"}
}
$fixture=Join-Path $OutputDirectory 'unsigned.exe'
[IO.File]::WriteAllBytes([IO.Path]::GetFullPath($fixture),[Text.Encoding]::ASCII.GetBytes('non-executable test fixture'))
$checker=Join-Path $PSScriptRoot 'Test-SignedArtifact.ps1'
$rejected=0
foreach($file in @($fixture,(Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'))){
    $before=(Get-FileHash -LiteralPath $file).Hash
    try{
        & $checker -Path $file -ExpectedCertificateSha256 ('0'*64) -ExpectedSubject 'INVALID FIXTURE ONLY' -ExpectedProductVersion 'fixture' -OutputPath (Join-Path $OutputDirectory 'must-not-exist.json')
        throw 'TEST ACCEPTED AN UNAPPROVED SIGNATURE'
    }catch{
        if($_.Exception.Message -notmatch 'Valid Authenticode signature AND timestamp required|Unexpected signer identity/certificate'){throw}
        $rejected++
    }
    if((Get-FileHash -LiteralPath $file).Hash -cne $before){throw 'Signature verifier changed input bytes'}
}
if(Test-Path -LiteralPath (Join-Path $OutputDirectory 'must-not-exist.json')){throw 'False signature success report'}
$config=Get-Content (Join-Path $PSScriptRoot '../../.signpath/config.example.json') -Raw|ConvertFrom-Json
if($config.enabled -or $config.approvedScope.Count){throw 'Signing configuration must be inert/empty'}
$ns=@{sp='http://signpath.io/artifact-configuration/v1'}
foreach($name in @('payload','outer')){
    [xml]$xml=Get-Content -LiteralPath (Join-Path $PSScriptRoot "../../.signpath/$name.xml.template") -Raw
    $nodes=Select-Xml -Xml $xml -XPath '//sp:pe-file' -Namespace $ns
    if($nodes.Count -ne $(if($name -eq 'payload'){3}else{1})){throw 'Unexpected signing XML scope'}
    foreach($node in $nodes){if($node.Node.'product-name' -cne 'MasterDesk' -or $node.Node.'company-name' -cne 'MasterDesk contributors'){throw 'Missing metadata restrictions'}}
}
@{Status='PASS';PowerShellSyntaxFiles=$parsed.Count;RealSignatureRejections=$rejected;
    TemplateXml='Well-formed/exact paths; see separate official XSD result. Provider acceptance NOT_RUN';
    RealApprovedSignature='NOT_RUN';SigningPerformed=$false}|ConvertTo-Json|Set-Content (Join-Path $OutputDirectory 'result.json')
Write-Output "PASS syntax=$($parsed.Count) signature-rejections=$rejected inert-config/XML"
