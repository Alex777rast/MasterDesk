[CmdletBinding()]
param([Parameter(Mandatory)][ValidatePattern('^[1-9][0-9]{0,19}$')][string]$RunId,
      [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{40}$')][string]$ExpectedCommit,
      [Parameter(Mandatory)][ValidateRange(110,65535)][int]$Beta,
      [Parameter(Mandatory)][string]$OutputDirectory)
$ErrorActionPreference='Stop'
if($env:GITHUB_ACTIONS -cne 'true' -or $env:RUNNER_ENVIRONMENT -cne 'github-hosted' -or
   $env:GITHUB_REPOSITORY -cne 'Alex777rast/MasterDesk'){throw 'Disposable first-party GitHub-hosted preflight only'}
if(Test-Path -LiteralPath $OutputDirectory){throw 'Fresh output directory required'}
New-Item -ItemType Directory -Path $OutputDirectory|Out-Null
$headers=@{Authorization="Bearer $env:GITHUB_TOKEN";Accept='application/vnd.github+json';'User-Agent'='MasterDesk-signing-preflight'}
try {
    $run=Invoke-RestMethod -Headers $headers -Uri "https://api.github.com/repos/Alex777rast/MasterDesk/actions/runs/$RunId"
    if($run.repository.full_name -cne 'Alex777rast/MasterDesk' -or $run.head_repository.full_name -cne 'Alex777rast/MasterDesk' -or
       $run.workflow_id -ne 323927768 -or $run.run_attempt -ne 1 -or $run.event -cne 'workflow_dispatch' -or $run.status -cne 'completed' -or
       $run.conclusion -cne 'success' -or $run.head_sha -cne $ExpectedCommit -or
       $run.head_branch -cne 'codex/x64-signing-source-20261106'){throw 'Untrusted build source'}
    $list=Invoke-RestMethod -Headers $headers -Uri "https://api.github.com/repos/Alex777rast/MasterDesk/actions/runs/$RunId/artifacts?per_page=100"
    if($list.total_count -gt 100){throw 'Unexpected artifact count; do not accept incomplete pagination'}
    foreach($kind in @('payload','unsigned')){
        $name="MasterDesk-x64-$kind-beta-$Beta-$ExpectedCommit"
        $matches=@($list.artifacts|Where-Object {$_.name -ceq $name -and -not $_.expired})
        if($matches.Count -ne 1){throw 'One exact unexpired artifact per kind required'}
        $artifact=Invoke-RestMethod -Headers $headers -Uri "https://api.github.com/repos/Alex777rast/MasterDesk/actions/artifacts/$($matches[0].id)"
        if($artifact.workflow_run.id -ne $run.id -or $artifact.workflow_run.head_sha -cne $ExpectedCommit -or
           $artifact.digest -notmatch '^sha256:[0-9a-f]{64}$'){throw 'Artifact attribution/digest missing'}
        $artifact|Select-Object id,name,expired,digest,workflow_run|
            ConvertTo-Json -Depth 5|Set-Content (Join-Path $OutputDirectory "$kind-artifact.json")
        "$kind-id=$($artifact.id)" >> $env:GITHUB_OUTPUT
    }
    $tree=Invoke-RestMethod -Headers $headers -Uri "https://api.github.com/repos/Alex777rast/MasterDesk/git/trees/$($ExpectedCommit)?recursive=1"
    $shared=@($tree.tree|Where-Object {$_.path -ceq 'libs/hbb_common' -and $_.type -ceq 'commit'})
    if($tree.truncated -or $shared.Count -ne 1){throw 'Exact source gitlink unavailable'}
    @{ 'libs/hbb_common'=$shared[0].sha }|ConvertTo-Json|Set-Content (Join-Path $OutputDirectory 'submodules.json')
    # Reports contain only public GitHub build metadata, never authorization.
    $run|Select-Object id,run_attempt,repository,head_repository,workflow_id,event,status,conclusion,head_sha,head_branch|
        ConvertTo-Json -Depth 5|Set-Content (Join-Path $OutputDirectory 'run.json')
    Write-Output 'PASS authenticated origin metadata; NOT provider approval or a signing request'
} catch {
    throw 'Trusted artifact preflight failed; HTTP response/credentials suppressed'
} finally {$headers.Clear()}
