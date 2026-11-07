[CmdletBinding()]
param([Parameter(Mandatory)][string]$OutputPath)
$ErrorActionPreference='Stop'
$env:GIT_TERMINAL_PROMPT='0'; $env:GCM_INTERACTIVE='Never'
# Existing credential is used in memory/stdin only, never in argv or output.
$rows=@("protocol=https`nhost=github.com`n`n" | git credential fill 2>$null)
$credential=@{}
foreach($row in $rows){$pair=$row -split '=',2;if($pair.Count -eq 2){$credential[$pair[0]]=$pair[1]}}
$rows=$null
function Read-Api([string]$Path){
    if($Path -notmatch '^/[A-Za-z0-9_./?=&%+-]+$'){throw 'Unexpected read-only API path'}
    $config='url = "https://api.github.com'+$Path+'"'+"`n"+'header = "Accept: application/vnd.github+json"'+"`n"+'header = "User-Agent: MasterDesk-signing-audit"'
    if($credential.password){
        if($credential.password -match '[\r\n"\\]'){throw 'Unsupported existing credential encoding'}
        $config+="`n"+'header = "Authorization: Bearer '+$credential.password+'"'
    }
    $raw=@($config | curl.exe --silent --show-error --max-time 30 --config - --write-out '\n%{http_code}' 2>$null)
    $config=$null
    if($LASTEXITCODE -or $raw.Count -lt 1){return @{Http=0;Data=$null}}
    $code=[int]$raw[-1];$data=$null
    if($code -eq 200){$data=(($raw|Select-Object -SkipLast 1) -join "`n")|ConvertFrom-Json}
    return @{Http=$code;Data=$data}
}
try {
    $repo='Alex777rast/MasterDesk'
    $r=Read-Api "/repos/$repo"
    $u=Read-Api '/user'
    $default=$r.Data.default_branch
    $branches=@(foreach($branch in @($default,'codex/x64-signing-source-20261106')|Select-Object -Unique){
        if(-not $branch){continue}
        $encoded=[Uri]::EscapeDataString($branch)
        $b=Read-Api "/repos/$repo/branches/$encoded"
        $p=Read-Api "/repos/$repo/branches/$encoded/protection"
        $rules=Read-Api "/repos/$repo/rules/branches/$encoded"
        [ordered]@{Branch=$branch;BranchHttp=$b.Http;Protected=$b.Data.protected;
            ProtectionHttp=$p.Http;RequireCodeOwners=$p.Data.required_pull_request_reviews.require_code_owner_reviews;
            RequiredApprovals=$p.Data.required_pull_request_reviews.required_approving_review_count;
            AdminEnforcement=$p.Data.enforce_admins.enabled;RequiredChecks=$p.Data.required_status_checks.contexts;
            ActiveRulesHttp=$rules.Http;ActiveRuleTypes=@($rules.Data|ForEach-Object {$_.type})}
    })
    $rs=Read-Api "/repos/$repo/rulesets?includes_parents=true&per_page=100"
    $envs=Read-Api "/repos/$repo/environments?per_page=100"
    $wf=Read-Api "/repos/$repo/actions/workflows?per_page=100"
    $perms=Read-Api "/repos/$repo/actions/permissions/workflow"
    $upstream=@(foreach($item in @(
        @('default_net','78f8f70cd85151a3a2c4a3230d80d5272703c02e'),
        @('hwcodec','778df1f99597722473b29443bac22ae6c23946fe'),
        @('impersonate-system','2f429010a5a10b1fe5eceb553c6672fd53d20167')
    )){
        $path="/repos/rustdesk-org/$($item[0])/git/trees/$($item[1])?recursive=1"
        $tree=Read-Api $path
        [ordered]@{Repository="rustdesk-org/$($item[0])";Commit=$item[1];Http=$tree.Http;
            Truncated=$tree.Data.truncated;TreeSHA=$tree.Data.sha;
            LicensePaths=@($tree.Data.tree|Where-Object {$_.type -ceq 'blob' -and $_.path -match '(^|/)(licen[cs]e|copying|notice)([._-].*)?$'}|ForEach-Object {$_.path});
            EvidenceOnlyNotLegalClearance=$true}
    })
    $report=[ordered]@{Schema=1;InspectedAt=[DateTime]::UtcNow.ToString('o');ReadOnly=$true;
        Repository=$repo;RepositoryHttp=$r.Http;DefaultBranch=$default;IsFork=$r.Data.fork;Parent=$r.Data.parent.full_name;
        Authenticated=$u.Http -eq 200;Account=$u.Data.login;Mfa=$u.Data.two_factor_authentication;
        MfaMeaning='null means unavailable, not disabled; no SignPath account inspection';
        Branches=$branches;RulesetsHttp=$rs.Http;Rulesets=@($rs.Data|Select-Object name,enforcement,target);
        EnvironmentsHttp=$envs.Http;Environments=@($envs.Data.environments|Select-Object name,protection_rules,deployment_branch_policy);
        WorkflowsHttp=$wf.Http;Workflows=@($wf.Data.workflows|Select-Object name,path,state);
        WorkflowPermissionsHttp=$perms.Http;DefaultTokenPermissions=$perms.Data.default_workflow_permissions;
        UpstreamExactRevisionTrees=$upstream;
        CanApprovePullRequests=$perms.Data.can_approve_pull_request_reviews;
        Caveat='HTTP 403/404 may reflect missing access. File presence is not enforcement. No remote settings changed.'}
    New-Item -ItemType Directory -Path (Split-Path -Parent ([IO.Path]::GetFullPath($OutputPath))) -Force|Out-Null
    $report|ConvertTo-Json -Depth 12|Set-Content -LiteralPath $OutputPath -Encoding utf8
    Write-Output "READ_ONLY_GITHUB_AUDIT=$OutputPath"
} finally {$credential.Clear();$credential=$null}
