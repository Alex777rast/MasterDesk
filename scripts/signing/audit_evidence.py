"""Sanitized local/workflow and public exact-revision evidence; never execute payload."""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import re
import subprocess
from urllib.request import Request, urlopen


def sha_bytes(content):
    return hashlib.sha256(content).hexdigest()


def public_json(url):
    with urlopen(Request(url, headers={'User-Agent':'MasterDesk-signing-audit'}), timeout=25) as response:
        return json.load(response)


def audit(repo, out):
    out.mkdir(parents=True, exist_ok=True)
    workflows = []
    for f in sorted((repo/'.github/workflows').glob('*.yml')):
        text = f.read_text(encoding='utf-8')
        active = '\n'.join(line for line in text.splitlines() if not line.lstrip().startswith('#'))
        uses = re.findall(r'(?m)^\s*(?:-\s*)?uses:\s*[\'"]?([^\s\'"#]+)', active)
        external = [x for x in uses if not x.startswith('./')]
        unpinned = [x for x in external if not re.fullmatch(r'[^@]+@[0-9a-f]{40}', x)]
        workflows.append({'file': f.relative_to(repo).as_posix(), 'sha256': sha_bytes(f.read_bytes()),
            'actionReferences': sorted(set(uses)), 'unpinned': sorted(set(unpinned)),
            'pullRequestTarget': 'pull_request_target:' in active,
            'selfHostedMention': 'self-hosted' in active,
            'secretNamesOnly': sorted(set(re.findall(r'secrets\.([A-Z0-9_]+)', active))),
            'writePermissionsMention': bool(re.search(r'contents:\s*write|write-all', active)),
            'note': 'Text inventory, not a proof of job reachability or effective remote permissions'})
    upstream = []
    for name, commit in [('default_net','78f8f70cd85151a3a2c4a3230d80d5272703c02e'),
                         ('hwcodec','778df1f99597722473b29443bac22ae6c23946fe'),
                         ('impersonate-system','2f429010a5a10b1fe5eceb553c6672fd53d20167')]:
        url = f'https://api.github.com/repos/rustdesk-org/{name}/git/trees/{commit}?recursive=1'
        row = {'repository':f'rustdesk-org/{name}', 'commit':commit, 'source':url}
        try:
            tree = public_json(url)
            if tree.get('truncated'):
                raise ValueError('Incomplete recursive tree')
            evidence = [e['path'] for e in tree['tree'] if e['type']=='blob' and
                        re.search(r'(^|/)(licen[cs]e|copying|notice)([._-].*)?$', e['path'], re.I)]
            row.update(status='PASS exact tree retrieved; NOT license clearance', licensePaths=evidence,
                       topLevelLicensePaths=[p for p in evidence if '/' not in p], treeSha=tree['sha'])
        except Exception as e:
            row.update(status='NOT_RUN remote retrieval', errorType=type(e).__name__)
        upstream.append(row)
    inputs = []
    commit = '99441ca7182f49b55b6e62726b50850c24343018'
    for name in ['Cargo.lock', 'Cargo.toml', 'flutter/pubspec.lock', 'vcpkg.json']:
        original = subprocess.check_output(['git','cat-file','blob',f'{commit}:{name}'], cwd=repo)
        current = (repo/name).read_bytes()
        # Check working bytes separately from Git's LF-filtered content.
        inputs.append({'path':name,'historicalBuildCommit':commit,'originalGitBlobSha256':sha_bytes(original),
                       'currentBytesSha256':sha_bytes(current),'sameIgnoringCRLF':original.replace(b'\r\n',b'\n')==current.replace(b'\r\n',b'\n')})
    inventory = json.loads((out/'dependencies/inventory.json').read_text(encoding='utf-8'))
    components = inventory['components']
    summary = {'counts':dict(Counter(c['kind'] for c in components)),
        'cargoNoLicenseField':[{'name':c['name'],'version':c['version'],'evidence':c['licenseEvidence']} for c in components
                               if c['kind']=='cargo' and not c['declaredLicense']],
        'dartNoTopLevelLicense':[c['name'] for c in components if c['kind'].startswith('dart') and not c['licenseEvidence']],
        'inputsComparedTo108':inputs, 'upstreamExactRevisionChecks':upstream,
        'automaticSigningScope':[], 'legalConclusion':'NEEDS_OWNER/UPSTREAM/FOUNDATION; no inferred license grants'}
    for name, doc in [('workflows-audit.json',workflows),('license-risk-evidence.json',summary)]:
        path = out/name
        with path.open('x',encoding='utf-8') as stream: json.dump(doc,stream,indent=2)
    print(json.dumps({'workflowFiles':len(workflows),'unpinnedFiles':[x['file'] for x in workflows if x['unpinned']],
                      'upstreamChecks':upstream}))


if __name__=='__main__':
    ap=argparse.ArgumentParser()
    ap.add_argument('--repo',required=True,type=Path)
    ap.add_argument('--out',required=True,type=Path)
    audit(**vars(ap.parse_args()))
