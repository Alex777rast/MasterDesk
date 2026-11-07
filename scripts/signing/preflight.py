"""GitHub-only byte checks; no binary execution, packaging or signing."""
import argparse
from pathlib import Path
import pipeline as p


def preflight(root, commit, beta):
    run = p.read_json(root/'origin/run.json')
    artifact = p.read_json(root/'origin/payload-artifact.json')
    p.verify_origin(run, artifact, commit, beta)
    evidence_artifact = p.read_json(root/'origin/unsigned-artifact.json')
    mirror = dict(evidence_artifact)
    mirror['name'] = artifact['name']
    p.verify_origin(run, mirror, commit, beta)
    if evidence_artifact['name'] != f'MasterDesk-x64-unsigned-beta-{beta}-{commit}':
        raise ValueError('Wrong unsigned evidence name')
    manifests = list((root/'evidence').rglob('payload-manifest.json'))
    gates = list((root/'evidence').rglob('source-gate.json'))
    if len(manifests) != 1 or len(gates) != 1:
        raise ValueError('Exactly one build-time manifest/source gate required')
    gate = p.read_json(gates[0])
    if (gate.get('Status') != 'PASS' or gate.get('Commit') != commit or gate.get('RootChangeCount') != 0 or
        gate.get('SubmoduleDirtyOrUninitialized') is not False or gate.get('MissingOrUntrackedRequiredInputs') or
        gate.get('SecretIndicatorPaths') or gate.get('ForbiddenPrivateFilePaths')):
        raise ValueError('Build source gate not clean')
    modules = p.read_json(root/'origin/submodules.json')
    # Digest is anchored by the Actions archive validation, NOT this self-hash.
    doc = p.verify(root/'payload', manifests[0], p.sha(manifests[0]), commit, modules)
    if doc['beta'] != beta:
        raise ValueError('Wrong beta manifest')
    p.write_new(root/'preflight-result.json', {'status': 'PASS', 'commit': commit, 'beta': beta,
        'filesVerified': len(doc['files']), 'manifestSha256': p.sha(manifests[0]),
        'origin': 'Authenticated GitHub metadata + action-enforced archive digests; not SignPath approval',
        'signing': 'DISABLED', 'executedArtifact': False})


if __name__ == '__main__':
    ap = argparse.ArgumentParser()
    ap.add_argument('--root', type=Path, required=True)
    ap.add_argument('--commit', required=True)
    ap.add_argument('--beta', type=int, required=True)
    preflight(**vars(ap.parse_args()))
