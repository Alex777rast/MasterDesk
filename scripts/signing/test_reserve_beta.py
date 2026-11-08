import json
import unittest
from unittest.mock import patch
import reserve_beta as r


class FakeApi:
    def __init__(self):
        self.refs = []
        self.releases = {1: []}
        self.writes = []
        self.conflict = False

    def __call__(self, method, path, body=None):
        if method == 'GET':
            if '/matching-refs/' in path:
                return self.refs
            return self.releases.get(int(path.split('page=')[-1]), [])
        self.writes.append((path, body))
        if path.endswith('/git/tags'):
            return {'sha': 'b'*40}
        if self.conflict:
            raise ValueError('atomic ref conflict')
        self.refs.append({'ref': body['ref']})
        return {'ref': body['ref'], 'object': {'sha': body['sha']}}


class BetaReservationTests(unittest.TestCase):
    def setUp(self):
        self.api = FakeApi()

    def reserve(self, beta='110', commit='a'*40):
        return r.reserve(self.api, beta, commit, '123', '2026-11-09')

    def test_new_identity_and_no_release_api(self):
        self.assertEqual(self.reserve()['beta'], 110)
        self.assertTrue(all(path.endswith(('/git/refs', '/git/tags')) for path, _ in self.api.writes))
        doc = json.loads(self.api.writes[0][1]['message'])
        self.assertEqual(doc['runId'], '123')
        self.assertEqual(doc['commit'], 'a'*40)

    def test_unpublished_failed_build_never_reused(self):
        self.reserve()
        for commit in ('a'*40, 'c'*40):
            with self.assertRaisesRegex(ValueError, 'above 110'):
                self.reserve(commit=commit)
        self.assertEqual(len(self.api.writes), 2)

    def test_higher_reserved_number(self):
        self.api.refs = [{'ref': r.PREFIX+'112'}]
        with self.assertRaisesRegex(ValueError, 'above 112'):
            self.reserve()
        self.assertEqual(self.reserve('113')['beta'], 113)

    def test_release_pagination_not_just_first_page(self):
        self.api.releases = {1: [{'tag_name': 'other'}]*100,
                             2: [{'tag_name': 'v1.4.9-masterdesk.10-beta.115'}]}
        with self.assertRaisesRegex(ValueError, 'above 115'):
            self.reserve()
        self.assertFalse(self.api.writes)

    def test_atomic_conflict_never_retried(self):
        self.api.conflict = True
        with self.assertRaisesRegex(ValueError, 'atomic ref conflict'):
            self.reserve()
        self.assertEqual(len(self.api.writes), 2)

    def test_invalid_or_old_beta(self):
        for value in ('109', '0100', '65536', '', '110\n', True):
            with self.subTest(value=value), self.assertRaises(ValueError):
                self.reserve(value)
        self.assertFalse(self.api.writes)

    def test_malformed_registry_stops_before_write(self):
        for refs in ({}, [{'ref': r.PREFIX+'0100'}], [{'ref': 'refs/tags/v110'}]):
            self.api.refs = refs
            with self.subTest(refs=refs), self.assertRaises(ValueError):
                self.reserve()
        self.assertFalse(self.api.writes)

    def test_local_or_rerun_entrypoint_cannot_mutate(self):
        with patch.dict(r.os.environ, {}, clear=True), self.assertRaises(ValueError):
            r.main()
        env = {'GITHUB_ACTIONS': 'true', 'RUNNER_ENVIRONMENT': 'github-hosted',
               'GITHUB_REPOSITORY': r.REPOSITORY, 'GITHUB_RUN_ATTEMPT': '2',
               'GITHUB_WORKFLOW_REF': f'{r.REPOSITORY}/.github/workflows/masterdesk-windows.yml@refs/heads/{r.REVIEWED_BRANCH}'}
        with patch.dict(r.os.environ, env, clear=True), self.assertRaises(ValueError):
            r.main()


if __name__ == '__main__':
    unittest.main()
