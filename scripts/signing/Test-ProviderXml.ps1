[CmdletBinding()]
param([Parameter(Mandatory)][string]$SchemaPath,
      [Parameter(Mandatory)][string]$OutputPath)
$ErrorActionPreference='Stop'
if(Test-Path -LiteralPath $OutputPath){throw 'Do not overwrite validation evidence'}
$settings=[Xml.XmlReaderSettings]::new()
$settings.XmlResolver=$null
$settings.DtdProcessing=[Xml.DtdProcessing]::Prohibit
$settings.ValidationType=[Xml.ValidationType]::Schema
$settings.Schemas.XmlResolver=$null
$null=$settings.Schemas.Add('http://signpath.io/artifact-configuration/v1',[IO.Path]::GetFullPath($SchemaPath))
$settings.Schemas.Compile()
$messages=[Collections.Generic.List[string]]::new()
$settings.add_ValidationEventHandler({param($sender,$event) $messages.Add($event.Message)})
$results=@(foreach($file in Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot '../../.signpath') -Filter '*.xml.template'){
    $reader=[Xml.XmlReader]::Create($file.FullName,$settings)
    try{while($reader.Read()){} }finally{$reader.Dispose()}
    if($messages.Count){throw 'Official XML schema validation failed'}
    @{File=$file.Name;SHA256=(Get-FileHash -LiteralPath $file.FullName).Hash}
})
if($results.Count -ne 2){throw 'Expected exactly two templates'}
@{Status='PASS';Engine='System.Xml (official XSD unmodified)';
    SchemaSource='https://app.signpath.io/Web/artifact-configuration/v1.xsd';
    SchemaSHA256=(Get-FileHash -LiteralPath $SchemaPath).Hash;Templates=$results;
    ProviderConfigurationAccepted='NOT_RUN; no request submitted'}|ConvertTo-Json -Depth 5|Set-Content -LiteralPath $OutputPath
Write-Output 'PASS official XSD validation; provider acceptance NOT_RUN'
