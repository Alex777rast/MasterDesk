[CmdletBinding()]
param([Parameter(Mandatory)][string]$EvidenceDirectory,
      [Parameter(Mandatory)][string]$OutputDirectory)
$ErrorActionPreference='Stop'
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$output=[IO.Path]::GetFullPath($OutputDirectory)
if(-not $output.StartsWith((Join-Path $repo 'artifacts')+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){
    throw 'Review output must be a new workspace artifacts directory'
}
if(Test-Path -LiteralPath $output){throw 'Do not overwrite an existing review packet'}
$evidence=(Resolve-Path -LiteralPath $EvidenceDirectory).Path
if(-not $evidence.StartsWith((Join-Path $repo 'artifacts')+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){
    throw 'Unexpected evidence location'
}
$sources=@(Get-ChildItem -LiteralPath (Join-Path $repo 'docs/signing') -Filter '*.md' -File)
$sources+=@(Get-ChildItem -LiteralPath $PSScriptRoot -File|Where-Object {$_.Extension -in '.ps1','.py'})
$sources+=@(Get-ChildItem -LiteralPath (Join-Path $repo '.signpath') -File)
$sources+=@(foreach($relative in @('github-controls-final.json','workflows-audit.json','license-risk-evidence.json',
    'sbom-detailed-validation.json','provider-xml-dotnet.json','beta108-content-recheck.json','native-configuration.json',
    'all-signing-tests-complete.log','actionlint-final.log','actionlint-all.log','final-attribution.json',
    'dependencies-detailed/inventory.json','dependencies-detailed/source-build-graph.cdx.json',
    'dependencies-detailed/THIRD-PARTY-NOTICES.txt','safety-packet/result.json')){
        Get-Item -LiteralPath (Join-Path $evidence $relative)
})
$rows=@(foreach($file in $sources){
    if(($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $file.Length -gt 30MB){throw 'Unexpected/reparse/oversized review file'}
    $relative=[IO.Path]::GetRelativePath($repo,$file.FullName).Replace('\','/')
    if($relative.StartsWith('../') -or $relative -match '(?i)\.(exe|dll|sys|iso|key|pfx|p12)$'){throw 'Disallowed review payload'}
    $text=[IO.File]::ReadAllText($file.FullName)
    # High-confidence indicator scan only, not a universal secret detector.
    if($text -match '(-----BEGIN (RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----|gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{50,})'){
        throw 'Private-key/token indicator in selected packet file; values suppressed'
    }
    @{Path=$relative;SHA256=(Get-FileHash -LiteralPath $file.FullName).Hash;Size=$file.Length;Source=$file.FullName}
})
if(@($rows.Path|Select-Object -Unique).Count -ne $rows.Count){throw 'Duplicate review path'}
New-Item -ItemType Directory -Path $output|Out-Null
$zipPath=Join-Path $output 'MasterDesk-SignPath-review-draft.zip'
$zip=[IO.Compression.ZipFile]::Open($zipPath,[IO.Compression.ZipArchiveMode]::Create)
try{
    foreach($row in $rows){[IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip,$row.Source,$row.Path,[IO.Compression.CompressionLevel]::Optimal)|Out-Null}
    $entry=$zip.CreateEntry('REVIEW-MANIFEST.json')
    $writer=[IO.StreamWriter]::new($entry.Open(),[Text.UTF8Encoding]::new($false))
    try{$writer.Write((@{Status='DRAFT_NOT_SENT';Files=@($rows|Select-Object Path,SHA256,Size);SigningEnabled=$false}|ConvertTo-Json -Depth 6))}finally{$writer.Dispose()}
}finally{$zip.Dispose()}
# Re-open and hash each archived text without extracting or executing anything.
$zip=[IO.Compression.ZipFile]::OpenRead($zipPath)
try{
    if($zip.Entries.Count -ne $rows.Count+1){throw 'Review archive file-set mismatch'}
    foreach($row in $rows){
        $stream=$zip.GetEntry($row.Path).Open()
        try{$hash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($stream))}finally{$stream.Dispose()}
        if($hash -cne $row.SHA256){throw 'Review archive content mismatch'}
    }
}finally{$zip.Dispose()}
$hash=(Get-FileHash -LiteralPath $zipPath).Hash
@{Status='PASS_LOCAL_DRAFT_NOT_SENT';Files=$rows.Count;SHA256=$hash;Archive=$zipPath;
    ExecutableIncluded=$false;SigningOrPublication=$false}|ConvertTo-Json|Set-Content (Join-Path $output 'packet-verification.json')
Write-Output "PASS review packet files=$($rows.Count) SHA256=$hash; NOT sent"
