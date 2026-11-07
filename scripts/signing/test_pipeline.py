import json
import shutil
from pathlib import Path
import tempfile
import unittest
import zipfile
import pipeline as p
import preflight


class IntegrityTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.root = self.base/'payload'
        self.root.mkdir()
        for name in sorted(p.OWNED | {'upstream.dll', 'data/asset.txt'}):
            path = self.root/name
            path.parent.mkdir(exist_ok=True)
            path.write_bytes(b'Non-executable synthetic fixture '+name.encode())
        self.commit = 'a'*40
        self.modules = {'libs/hbb_common': 'b'*40}
        self.manifest = self.base/'manifest.json'
        self.doc = p.make_manifest(self.root, self.commit, self.modules, 110)
        p.write_new(self.manifest, self.doc)
        self.digest = p.sha(self.manifest)

    def verify(self):
        return p.verify(self.root, self.manifest, self.digest, self.commit, self.modules)

    def rewrite(self):
        self.manifest.write_text(json.dumps(self.doc), encoding='utf-8')
        self.digest = p.sha(self.manifest)

    def test_exact_payload(self):
        self.assertEqual(self.verify(), self.doc)

    def test_manifest_generation_deterministic(self):
        again=p.make_manifest(self.root,self.commit,self.modules,110)
        self.assertEqual(again,self.doc)
        other=self.base/'second-manifest.json'
        p.write_new(other,again)
        self.assertEqual(p.sha(other),self.digest)

    def test_exe_substitution(self):
        (self.root/'MasterDesk.exe').write_bytes(b'changed')
        with self.assertRaises(ValueError): self.verify()

    def test_wrong_sha(self):
        self.doc['files'][0]['sha256'] = '0'*64
        self.rewrite()
        with self.assertRaises(ValueError): self.verify()

    def test_manifest_tamper(self):
        self.manifest.write_text('{}')
        with self.assertRaises(ValueError): self.verify()

    def test_commit_mismatch(self):
        self.commit = 'c'*40
        with self.assertRaises(ValueError): self.verify()

    def test_submodule_mismatch(self):
        self.modules['libs/hbb_common'] = 'd'*40
        with self.assertRaises(ValueError): self.verify()

    def test_unreviewed_scope(self):
        next(x for x in self.doc['files'] if x['path']=='upstream.dll')['scope']='candidate-owned'
        self.rewrite()
        with self.assertRaises(ValueError): self.verify()

    def test_extra_dll(self):
        (self.root/'extra.dll').write_bytes(b'fixture')
        with self.assertRaises(ValueError): self.verify()

    def test_missing_dll(self):
        (self.root/'libmasterdesk.dll').unlink()
        with self.assertRaises(ValueError): self.verify()

    def test_duplicate_file(self):
        self.doc['files'].append(self.doc['files'][0])
        self.rewrite()
        with self.assertRaises(ValueError): self.verify()

    def test_immutable_previous_betas(self):
        for beta in (105, 106, 107, 108, 109, True, 65536):
            with self.subTest(beta=beta), self.assertRaises(ValueError):
                p.make_manifest(self.root, self.commit, self.modules, beta)

    def test_no_overwrite_evidence(self):
        with self.assertRaises(FileExistsError): p.write_new(self.manifest, {})

    def test_duplicate_json(self):
        self.manifest.write_text('{"schema":1,"schema":2}')
        with self.assertRaises(ValueError): p.read_json(self.manifest)

    def test_path_attacks(self):
        for name in ('../x', 'a/../x', '/x', 'C:/x', 'a\\b', 'x:ads', 'x.', 'x ',
                     'NUL.exe', 'COM1', 'a//b', './x', 'a/*', 'a/\n'):
            with self.subTest(name=name), self.assertRaises(ValueError): p.safe_name(name)

    def test_activation_always_disabled(self):
        for config in ({}, {'enabled': True}, {'enabled': True, 'foundationApproval': 'yes',
                        'approvedScope': sorted(p.OWNED)}):
            with self.assertRaisesRegex(ValueError, 'BLOCKED'): p.activation_guard(config)

    def origin(self):
        run = {'repository': {'full_name': 'Alex777rast/MasterDesk'},
               'head_repository': {'full_name': 'Alex777rast/MasterDesk'},
               'workflow_id': 323927768, 'event': 'workflow_dispatch', 'conclusion': 'success',
               'status': 'completed', 'head_sha': self.commit, 'run_attempt': 1,
               'head_branch': 'codex/x64-signing-source-20261106', 'id': 123}
        artifact = {'workflow_run': {'id':123, 'head_sha': self.commit}, 'expired': False,
                    'name': f'MasterDesk-x64-payload-beta-110-{self.commit}', 'digest':'sha256:'+'e'*64}
        return run, artifact

    def test_origin_valid_structure_not_provider_proof(self):
        p.verify_origin(*self.origin(), self.commit, 110)

    def test_untrusted_runs(self):
        for field, value in [('event', 'pull_request'), ('workflow_id', 9), ('head_sha', 'f'*40),
                             ('head_branch', 'attacker'), ('conclusion', 'failure'),
                             ('status', 'in_progress'), ('run_attempt', 2), ('head_repository', {'full_name':'attacker/fork'})]:
            run, artifact = self.origin()
            run[field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                p.verify_origin(run, artifact, self.commit, 110)

    def test_untrusted_artifacts(self):
        for field, value in [('expired', True), ('digest', ''), ('name', 'uploaded.exe'),
                             ('workflow_run', {'id':321, 'head_sha':self.commit})]:
            run, artifact = self.origin()
            artifact[field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                p.verify_origin(run, artifact, self.commit, 110)

    def test_safe_zip(self):
        archive = self.base/'safe.zip'
        with zipfile.ZipFile(archive, 'w') as z: z.writestr('data/file.txt', b'fixture')
        output = self.base/'expanded'
        p.extract_zip(archive, output, p.sha(archive))
        self.assertEqual((output/'data/file.txt').read_bytes(), b'fixture')
        with self.assertRaises(ValueError): p.extract_zip(archive, output, p.sha(archive))

    def bundle(self):
        root=self.base/'bundle'
        shutil.copytree(self.root, root/'payload')
        origin=root/'origin'
        origin.mkdir()
        run, artifact=self.origin()
        p.write_new(origin/'run.json',run)
        p.write_new(origin/'payload-artifact.json',artifact)
        artifact=dict(artifact, name=f'MasterDesk-x64-unsigned-beta-110-{self.commit}')
        p.write_new(origin/'unsigned-artifact.json',artifact)
        p.write_new(origin/'submodules.json',self.modules)
        p.write_new(root/'evidence/payload-manifest.json',self.doc)
        p.write_new(root/'evidence/source-gate.json',{'Status':'PASS','Commit':self.commit,
            'RootChangeCount':0,'SubmoduleDirtyOrUninitialized':False})
        return root

    def test_synthetic_preflight_never_signs(self):
        root=self.bundle()
        preflight.preflight(root,self.commit,110)
        self.assertEqual(p.read_json(root/'preflight-result.json')['signing'],'DISABLED')

    def test_preflight_dirty_source(self):
        root=self.bundle()
        gate=root/'evidence/source-gate.json'
        gate.write_text(json.dumps({'Status':'PASS','Commit':self.commit,'RootChangeCount':1,
                                    'SubmoduleDirtyOrUninitialized':False}))
        with self.assertRaises(ValueError): preflight.preflight(root,self.commit,110)
        self.assertFalse((root/'preflight-result.json').exists())

    def test_preflight_substituted_byte(self):
        root=self.bundle()
        (root/'payload/MasterDesk.exe').write_bytes(b'changed')
        with self.assertRaises(ValueError): preflight.preflight(root,self.commit,110)
        self.assertFalse((root/'preflight-result.json').exists())

    def test_hostile_zip(self):
        for index, names in enumerate([['../x'], ['x:ads'], ['x','X'], ['x','x/y'], ['CON'], ['a\\b']]):
            archive = self.base/f'bad{index}.zip'
            with zipfile.ZipFile(archive, 'w') as z:
                for name in names: z.writestr(name, b'fixture')
            if any('\\' in name for name in names):
                # zipfile normalizes OS separators on Windows when writing;
                # mutate only this synthetic ZIP's local/central filename bytes.
                raw = archive.read_bytes()
                for name in names:
                    raw = raw.replace(name.replace('\\', '/').encode(), name.encode())
                archive.write_bytes(raw)
            with self.subTest(names=names), self.assertRaises(ValueError):
                p.extract_zip(archive, self.base/f'out{index}', p.sha(archive))
            self.assertFalse((self.base/f'out{index}').exists())


if __name__ == '__main__': unittest.main(verbosity=2)
