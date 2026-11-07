"""Local source/build-graph evidence, NOT a clearance or hosted binary SBOM.

Read-only package caches and lockfiles; output only to a new evidence directory.
No package install, source rewrite, key handling or arbitrary code execution.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
from urllib.parse import unquote, urlparse, quote
import uuid


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run(*args, cwd=None):
    return subprocess.check_output(args, cwd=cwd, stderr=subprocess.DEVNULL, text=True).strip()


def license_files(root):
    return [p for p in sorted(root.iterdir()) if p.is_file() and not p.is_symlink() and
            re.match(r'^(licen[cs]e|copying|notice|copyright)([._-].*)?$', p.name, re.I)]


def dart_lock_evidence(lock):
    # Read a small scalar subset, not a general YAML implementation. Unknown
    # structures remain in the hashed original lockfile, never inferred.
    records = {}
    starts = list(re.finditer(r'^  ([a-zA-Z0-9_]+):\s*$', lock, re.M))
    for index, start in enumerate(starts):
        block = lock[start.end():starts[index+1].start() if index+1<len(starts) else len(lock)]
        fields = {}
        for name, pattern in [('source',r'^    source:\s*(.+)$'),
                              ('resolvedGitCommit',r'^      resolved-ref:\s*(.+)$'),
                              ('hostedArchiveSha256',r'^      sha256:\s*(.+)$')]:
            match = re.search(pattern,block,re.M)
            if match:
                fields[name] = match[1].strip().strip('"\'')
        url = re.search(r'^      url:\s*(.+)$',block,re.M)
        if url:
            value=url[1].strip().strip('"\'')
            parsed=urlparse(value)
            if parsed.scheme=='https' and not parsed.username and not parsed.password and not parsed.query:
                fields['publicSourceUrl']=value
        fields['recordSha256']=hashlib.sha256(block.encode('utf-8')).hexdigest()
        records[start[1]]=fields
    return records


def collect(repo, out, flutter, native):
    if out.exists():
        raise ValueError('Use a fresh evidence directory; existing evidence is immutable')
    meta = json.loads(run(str(Path.home()/'.cargo/bin/cargo.exe'), 'metadata',
                          '--manifest-path', str(repo/'Cargo.toml'), '--format-version', '1',
                          '--locked', '--offline', '--filter-platform', 'x86_64-pc-windows-msvc',
                          '--features', 'hwcodec,vram,flutter', cwd=repo))
    nodes = {n['id']: n for n in meta['resolve']['nodes']}
    seen, todo = set(), [meta['resolve']['root']]
    while todo:
        ident = todo.pop()
        if ident in seen:
            continue
        seen.add(ident)
        todo.extend(d['pkg'] for d in nodes[ident]['deps'] if
                    any(k['kind'] != 'dev' for k in d['dep_kinds']))
    components, inventory, notices = [], [], []

    def add(kind, name, version, origin, root=None, declared=None, ref=None, files=None):
        ref = ref or f'{kind}:{name}@{version}'
        evidence = []
        for f in files if files is not None else (license_files(root) if root else []):
            content = f.read_text(encoding='utf-8', errors='replace')
            evidence.append({'file': f.name, 'sha256': digest(f), 'bytes': f.stat().st_size})
            notices.append(f'\n===== {kind}: {name} {version}; {origin}; {f.name}; SHA256 {digest(f)} =====\n{content}')
        row = {'kind': kind, 'name': name, 'version': version, 'origin': origin,
               'declaredLicense': declared, 'licenseEvidence': evidence, 'bomRef': ref}
        inventory.append(row)
        component = {'type': 'library', 'bom-ref': ref, 'name': name,
                     'properties': [{'name': 'masterdesk:origin', 'value': origin},
                                    {'name': 'masterdesk:coverage', 'value': kind},
                                    {'name': 'masterdesk:legal-clearance', 'value': 'NOT_REVIEWED'}]}
        if version:
            component['version'] = str(version)
        if kind == 'cargo':
            component['purl'] = f'pkg:cargo/{quote(name)}@{quote(str(version))}'
        if declared:
            # Preserve legacy slash expressions; do not silently invent an SPDX expression.
            component['licenses'] = [{'license': {'name': declared}}]
        components.append(component)

    for p in sorted(meta['packages'], key=lambda p: p['id']):
        if p['id'] not in seen:
            continue
        root = Path(p['manifest_path']).parent
        files = license_files(root)
        if p.get('license_file'):
            explicit = (root/p['license_file']).resolve()
            if explicit.is_relative_to(root.resolve()) and explicit.is_file() and not explicit.is_symlink() and explicit not in files:
                files.append(explicit)
        add('cargo', p['name'], p['version'], p['source'] or 'workspace (dirty attribution below)',
            root, p.get('license'), p['id'], files)
    cfgpath = repo/'flutter/.dart_tool/package_config.json'
    cfg = json.loads(cfgpath.read_text(encoding='utf-8'))
    locked_dart=dart_lock_evidence((repo/'flutter/pubspec.lock').read_text(encoding='utf-8'))
    for p in cfg['packages']:
        uri = p['rootUri']
        if uri.startswith('file:'):
            root = Path(unquote(urlparse(uri).path).lstrip('/') if os.name == 'nt' else unquote(urlparse(uri).path))
        else:
            root = (cfgpath.parent/unquote(uri)).resolve()
        pubspec = root/'pubspec.yaml'
        version = re.search(r'^version:\s*([^\r\n#]+)', pubspec.read_text(encoding='utf-8'), re.M) if pubspec.exists() else None
        add('dart-resolved-including-dev', p['name'], version[1].strip() if version else None,
            'local resolved SDK/cache; see pubspec.lock', root)
        inventory[-1]['lockEvidence']=locked_dart.get(p['name'], {'source':'NOT_IN_LOCK'})
        for key,value in inventory[-1]['lockEvidence'].items():
            components[-1]['properties'].append({'name':'masterdesk:dart-lock:'+key,'value':value})
    share = native/'installed/x64-windows-static/share'
    for port in sorted(p for p in share.iterdir() if p.is_dir()):
        spdxfile = port/'vcpkg.spdx.json'
        spdx = json.loads(spdxfile.read_text(encoding='utf-8')) if spdxfile.exists() else {}
        packages = spdx.get('packages', [])
        match = next((p for p in packages if p.get('name') == port.name), {})
        add('native-cache-port', port.name, match.get('versionInfo'),
            'vcpkg local cache (NOT exact hosted linkage)', port, match.get('licenseConcluded'))
        inventory[-1]['spdxPackages'] = packages
        inventory[-1]['spdxSha256'] = digest(spdxfile) if spdxfile.exists() else None
    # Inventory all vendored directories, including source without a Cargo manifest.
    for root in sorted(p for p in (repo/'libs').iterdir() if p.is_dir()):
        add('vendored-directory', root.name, None, 'workspace source directory', root)
    for name, path in [('masterdesk', repo/'LICENCE'), ('flutter-sdk', flutter/'LICENSE')]:
        add('parent-license-evidence', name, None, 'parent license, applicability NEEDS_REVIEW', files=[path])
    report = {'schema': 1, 'coverage': 'Source build graph including build deps, all resolved Dart incl dev, native cache; NOT binary linkage/clearance',
              'rootCommit': run('git', 'rev-parse', 'HEAD', cwd=repo),
              'dirty': bool(run('git', 'status', '--porcelain', cwd=repo)),
              'submodules': run('git', 'submodule', 'status', '--recursive', cwd=repo),
              'nativeCommit': run('git', 'rev-parse', 'HEAD', cwd=native),
              'nativeTrackedDirty': bool(run('git', 'status', '--porcelain', '--untracked-files=no', cwd=native)),
              'flutterSdkCommit':run('git','rev-parse','HEAD',cwd=flutter),
              'inputs': {p: digest(repo/p) for p in ['Cargo.lock', 'Cargo.toml', 'flutter/pubspec.lock', 'vcpkg.json']},
              'components': inventory}
    cdx = {'bomFormat': 'CycloneDX', 'specVersion': '1.5', 'serialNumber': 'urn:uuid:'+str(uuid.uuid4()), 'version': 1,
           'metadata': {'properties': [{'name': 'masterdesk:coverage', 'value': report['coverage']},
                                       {'name': 'masterdesk:source-commit', 'value': report['rootCommit']},
                                       {'name': 'masterdesk:source-dirty', 'value': str(report['dirty']).lower()}]},
           'components': components,
           'dependencies': [{'ref': ident, 'dependsOn': sorted(d['pkg'] for d in nodes[ident]['deps']
                             if d['pkg'] in seen and any(k['kind'] != 'dev' for k in d['dep_kinds']))} for ident in sorted(seen)]}
    out.mkdir(parents=True)
    (out/'inventory.json').write_text(json.dumps(report, ensure_ascii=False, indent=2)+'\n', encoding='utf-8')
    (out/'source-build-graph.cdx.json').write_text(json.dumps(cdx, ensure_ascii=False, indent=2)+'\n', encoding='utf-8')
    (out/'THIRD-PARTY-NOTICES.txt').write_text('EVIDENCE COLLECTION; NOT A FINAL DISTRIBUTION NOTICE OR LICENSE CLEARANCE.\n'
        'Includes build/dev/cache components that may not be distributed. Parent applicability unresolved.\n'+''.join(notices), encoding='utf-8')
    print(json.dumps({'output': str(out), 'counts': {kind: sum(x['kind'] == kind for x in inventory) for kind in sorted({x['kind'] for x in inventory})},
                      'cargoMissingDeclarations': [x['name'] for x in inventory if x['kind']=='cargo' and not x['declaredLicense']]}))


if __name__ == '__main__':
    parser=argparse.ArgumentParser()
    for name in ['repo','out','flutter','native']:
        parser.add_argument('--'+name, required=True, type=Path)
    collect(**vars(parser.parse_args()))
