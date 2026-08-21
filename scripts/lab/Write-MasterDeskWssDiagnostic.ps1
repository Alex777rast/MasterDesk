[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ScenarioJsonPath,

    [Parameter(Mandatory = $true)]
    [string]$LogArchivePath,

    [Parameter(Mandatory = $true)]
    [string]$OutputDirectory
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$OutputDirectory = [System.IO.Path]::GetFullPath($OutputDirectory)
$ScenarioJsonPath = [System.IO.Path]::GetFullPath($ScenarioJsonPath)
$LogArchivePath = [System.IO.Path]::GetFullPath($LogArchivePath)
$scenario = Get-Content -LiteralPath $ScenarioJsonPath -Raw | ConvertFrom-Json
$extractRoot = Join-Path $OutputDirectory 'wss-log-extract'
if (Test-Path -LiteralPath $extractRoot) {
    Remove-Item -LiteralPath $extractRoot -Recurse -Force
}
Expand-Archive -LiteralPath $LogArchivePath -DestinationPath $extractRoot -Force

$events = @(
    Get-ChildItem -LiteralPath $extractRoot -Recurse -Filter '*.log' -File |
        Where-Object { $_.FullName -match '(?i)\\server\\MasterDesk_.*\.log$' } |
        ForEach-Object {
            $file = $_
            Get-Content -LiteralPath $file.FullName -ErrorAction SilentlyContinue |
                Where-Object {
                    $_ -match '(?i)(start tcp: wss://hbbs\.masterdesk\.online/ws/id|Direct WebSocket connected to hbbs\.masterdesk\.online|Client handshake done|unknown RegisterPkResponse|request_pk received|UUID_MISMATCH|NOT_DEPLOYED|keep_alive:|Connection reset without closing handshake|rendezvous mediator error:.*WebSocket|Failed to store\s+config)'
                } |
                ForEach-Object {
                    $timestamp = $null
                    if ($_ -match '^\[([^\]]+)\]') {
                        try {
                            $timestamp = ([DateTimeOffset]::Parse(
                                $matches[1],
                                [System.Globalization.CultureInfo]::InvariantCulture
                            )).UtcDateTime.ToString('o')
                        } catch { }
                    }
                    [pscustomobject]@{
                        TimestampUtc = $timestamp
                        File = $file.FullName.Substring($extractRoot.Length + 1)
                        Text = [string]$_
                    }
                }
        }
)

$id = @($events | Where-Object { $_.Text -match '(?i)start tcp: wss://hbbs\.masterdesk\.online/ws/id' })
$direct = @($events | Where-Object { $_.Text -match '(?i)Direct WebSocket connected to hbbs\.masterdesk\.online' })
$handshake = @($events | Where-Object { $_.Text -match '(?i)Client handshake done' })
$response = @($events | Where-Object { $_.Text -match '(?i)(unknown RegisterPkResponse|request_pk received|UUID_MISMATCH|NOT_DEPLOYED|keep_alive:)' })
$registration = @($events | Where-Object { $_.Text -match '(?i)(RegisterPkResponse.*\bOK\b|key_confirmed.*true)' })
$reset = @($events | Where-Object {
    $_.Text -match '(?i)websocket\.rs:\d+\].*WebSocket protocol error: Connection reset without closing handshake'
})
$configErrors = @($events | Where-Object { $_.Text -match '(?i)Failed to store\s+config' })

$criterion = {
    param([string]$Name)
    if ($scenario.Criteria.psobject.Properties.Name -contains $Name) {
        return [bool]$scenario.Criteria.$Name
    }
    return $false
}

$candidateMatch = (& $criterion 'deployed_package_matches_host_sha256') -and
    (& $criterion 'installed_payload_matches_host_sha256')
$classification = if (-not $candidateMatch) {
    'FAIL-CANDIDATE-MISMATCH'
} elseif ($handshake.Count -gt 0 -and $response.Count -gt 0 -and
    $registration.Count -eq 0 -and $reset.Count -gt 0) {
    'FAIL-SERVER-PROTOCOL'
} elseif ($id.Count -gt 0 -and $handshake.Count -eq 0) {
    'FAIL-CLIENT'
} elseif ($registration.Count -gt 0 -and $reset.Count -eq 0) {
    'PASS'
} else {
    'INCONCLUSIVE'
}

function New-TimelineEvent {
    param(
        [string]$Stage,
        [string]$Status,
        [AllowNull()][object]$Event,
        [string]$Evidence
    )
    return [ordered]@{
        Stage = $Stage
        Status = $Status
        TimestampUtc = if ($null -eq $Event) { $null } else { $Event.TimestampUtc }
        Evidence = $Evidence
        LogFile = if ($null -eq $Event) { $null } else { $Event.File }
    }
}

$generic = $scenario.Evidence.GenericEndpoints
$timeline = @(
    New-TimelineEvent 'DNS' $(if([bool]$generic.IdDns){'PASS'}else{'FAIL'}) $null 'hbbs.masterdesk.online'
    New-TimelineEvent 'TCP' $(if($direct.Count){'PASS'}else{'UNKNOWN'}) ($direct | Select-Object -First 1) 'candidate connected to hbbs:443 through direct interface'
    New-TimelineEvent 'TLS+WebSocket Upgrade' $(if($handshake.Count){'PASS'}else{'UNKNOWN'}) ($handshake | Select-Object -First 1) 'tungstenite Client handshake done'
    New-TimelineEvent '/ws/id' $(if($id.Count){'PASS'}else{'FAIL'}) ($id | Select-Object -First 1) 'exact candidate WSS URL'
    New-TimelineEvent 'MasterDesk first message' $(if($response.Count){'INDIRECT-PASS'}else{'UNKNOWN'}) ($response | Select-Object -First 1) 'server response proves an application message was sent'
    New-TimelineEvent 'Server response' $(if($response.Count){'PASS'}else{'UNKNOWN'}) ($response | Select-Object -First 1) $(if($response.Count){'RegisterPkResponse result is outside the client handler accepted set'}else{'not observed'})
    New-TimelineEvent 'Registration' $(if($registration.Count){'PASS'}else{'FAIL'}) ($registration | Select-Object -First 1) $(if($registration.Count){'confirmation observed'}else{'no successful registration confirmation'})
    New-TimelineEvent 'Disconnect' $(if($reset.Count){'FAIL'}else{'NONE'}) ($reset | Select-Object -First 1) $(if($reset.Count){'reset without closing handshake after server response'}else{'not observed'})
    New-TimelineEvent 'Reconnect' $(if($id.Count -gt 1){'OBSERVED'}else{'NOT-OBSERVED'}) ($id | Select-Object -Skip 1 -First 1) ("ID attempts={0}" -f $id.Count)
    New-TimelineEvent 'Relay WSS' $(if([bool]$generic.RelayWss){'GENERIC-PASS'}else{'GENERIC-FAIL'}) $null 'no MasterDesk relay session was opened'
)

$timelinePath = Join-Path $OutputDirectory 'wss-timeline.json'
$timeline | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $timelinePath -Encoding UTF8

$summary = [ordered]@{
    Classification = $classification
    CandidatePackageSha256 = [string]$scenario.Evidence.CandidateMetadata.HostSha256
    GuestPackageSha256 = [string]$scenario.Evidence.CandidateGuestSha256
    ExpectedInstalledSha256 = [string]$scenario.Evidence.InstalledCandidate.ExpectedInstalledSha256
    ServiceExecutableSha256 = [string]$scenario.Evidence.ServiceExecutableSha256
    Attempts = $id.Count
    Handshakes = $handshake.Count
    ServerResponses = $response.Count
    RegistrationConfirmations = $registration.Count
    Resets = $reset.Count
    ConfigStoreErrors = $configErrors.Count
    TimelinePath = $timelinePath
    ServerSideEvidence = 'Unavailable in this task; no production SSH was used.'
}
$summary | ConvertTo-Json -Depth 8 |
    Set-Content -LiteralPath (Join-Path $OutputDirectory 'wss-diagnostic-summary.json') -Encoding UTF8
[pscustomobject]$summary
