"""Reserve unsigned CI identities, NOT release tags or signing requests.

Only the reservation job has contents:write. GitHub serializes that job globally;
create-ref is the final atomic uniqueness check. Failed/abandoned builds consume
their beta. Local builders must still check this registry; this is not DRM.
"""
import datetime
import json
import os
import re
from urllib.error import HTTPError, URLError
from urllib.request import Request, build_opener, HTTPRedirectHandler

from pipeline import COMMIT, REVIEWED_BRANCH

REPOSITORY = 'Alex777rast/MasterDesk'
PREFIX = 'refs/tags/masterdesk-beta-reserved/'
RELEASE = re.compile(r'^v1\.4\.9-masterdesk\.10-beta\.(\d+)$')


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


class Api:
    def __init__(self, token):
        if not token or any(c in token for c in '\r\n'):
            raise ValueError('Missing GitHub job credential')
        self.token = token

    def __call__(self, method, path, body=None):
        if method not in ('GET', 'POST') or not path.startswith(f'/repos/{REPOSITORY}/'):
            raise ValueError('Unexpected API operation')
        data = None if body is None else json.dumps(body).encode()
        request = Request('https://api.github.com'+path, data=data, method=method,
                          headers={'Authorization': 'Bearer '+self.token,
                                   'Accept': 'application/vnd.github+json',
                                   'Content-Type': 'application/json',
                                   'User-Agent': 'MasterDesk-beta-reservation'})
        try:
            with build_opener(NoRedirect()).open(request, timeout=30) as response:
                # Matching-refs has no documented pagination. Fail rather than
                # silently use a partial registry if GitHub adds pagination.
                if response.headers.get('Link'):
                    raise ValueError('Unexpected API pagination; reservation stopped')
                raw = response.read(32*1024*1024+1)
                if len(raw) > 32*1024*1024:
                    raise ValueError('Oversized registry response')
                return json.loads(raw)
        except (HTTPError, URLError, OSError, TimeoutError):
            # Do not include responses, request headers or token in diagnostics.
            raise ValueError('GitHub operation failed/uncertain; inspect registry, never blindly retry') from None


def beta_number(value):
    if not isinstance(value, str) or not re.fullmatch(r'[1-9][0-9]{0,4}', value):
        raise ValueError('Invalid beta identity')
    number = int(value)
    if not 110 <= number <= 65535:
        raise ValueError('105..109 reserved; new beta must be 110..65535')
    return number


def reserve(api, beta, commit, run_id, date):
    beta = beta_number(beta)
    if not COMMIT.fullmatch(commit) or not re.fullmatch(r'[1-9][0-9]{0,19}', run_id):
        raise ValueError('Exact source/run attribution required')
    if datetime.date.fromisoformat(date).isoformat() != date:
        raise ValueError('Canonical UTC reservation date required')
    base = f'/repos/{REPOSITORY}'
    refs = api('GET', base+'/git/matching-refs/tags/masterdesk-beta-reserved/')
    if not isinstance(refs, list):
        raise ValueError('Incomplete beta registry')
    maximum = 109
    for ref in refs:
        name = ref.get('ref', '')
        if not name.startswith(PREFIX):
            raise ValueError('Unexpected beta registry ref')
        maximum = max(maximum, beta_number(name[len(PREFIX):]))
    # All pages, including drafts/older published identities. Bounded fail-closed.
    for page in range(1, 1001):
        releases = api('GET', base+f'/releases?per_page=100&page={page}')
        if not isinstance(releases, list) or len(releases) > 100:
            raise ValueError('Invalid release inventory')
        for release in releases:
            match = RELEASE.fullmatch(release.get('tag_name', ''))
            if match:
                maximum = max(maximum, int(match[1]))
        if len(releases) < 100:
            break
    else:
        raise ValueError('Release inventory pagination limit; no reservation')
    if beta <= maximum:
        raise ValueError(f'Beta already issued/reserved; choose a number above {maximum}')
    identity = {'schema': 1, 'beta': beta, 'commit': commit, 'runId': run_id,
                'dateUtc': date, 'branch': REVIEWED_BRANCH, 'purpose': 'UNSIGNED_BUILD_RESERVATION'}
    tag = api('POST', base+'/git/tags',
              {'tag': f'masterdesk-beta-reserved/{beta}', 'message': json.dumps(identity, sort_keys=True),
               'object': commit, 'type': 'commit'})
    if not COMMIT.fullmatch(tag.get('sha', '')):
        raise ValueError('Invalid annotated reservation object')
    target = PREFIX+str(beta)
    # No PATCH/delete and no retries. Concurrent creation of the same N must fail.
    created = api('POST', base+'/git/refs', {'ref': target, 'sha': tag['sha']})
    if created.get('ref') != target or created.get('object', {}).get('sha') != tag['sha']:
        raise ValueError('Reservation result uncertain; inspect before any new build')
    return identity


def main():
    expected = f'{REPOSITORY}/.github/workflows/masterdesk-windows.yml@refs/heads/{REVIEWED_BRANCH}'
    if (os.environ.get('GITHUB_ACTIONS') != 'true' or
        os.environ.get('RUNNER_ENVIRONMENT') != 'github-hosted' or
        os.environ.get('GITHUB_REPOSITORY') != REPOSITORY or
        os.environ.get('GITHUB_WORKFLOW_REF') != expected or
        os.environ.get('GITHUB_RUN_ATTEMPT') != '1'):
        raise ValueError('First attempt of reviewed GitHub-hosted workflow only')
    result = reserve(Api(os.environ.get('GITHUB_TOKEN')), os.environ.get('REQUESTED_BETA', ''),
                     os.environ.get('GITHUB_SHA', ''), os.environ.get('GITHUB_RUN_ID', ''),
                     datetime.datetime.now(datetime.timezone.utc).date().isoformat())
    with open(os.environ['GITHUB_OUTPUT'], 'a', encoding='utf-8') as output:
        output.write(f"beta={result['beta']}\n")
    print(f"PASS reserved beta {result['beta']}; no release/signing request")


if __name__ == '__main__':
    try:
        main()
    except (ValueError, KeyError) as error:
        raise SystemExit(str(error)) from None
