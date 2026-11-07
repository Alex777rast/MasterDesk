"""Preparation/integrity helpers only. There is deliberately NO signing client.

A JSON manifest is not trusted origin. Its digest/expected source must come from
the independently verified hosted artifact and reviewed workflow, not itself.
"""
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import stat
import zipfile

OWNED = frozenset({'MasterDesk.exe', 'libmasterdesk.dll', 'dylib_virtual_display.dll'})
HASH = re.compile(r'^[0-9a-f]{64}$')
COMMIT = re.compile(r'^[0-9a-f]{40}$')


def sha(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def read_json(path):
    def pairs(rows):
        result = {}
        for key, value in rows:
            if key in result:
                raise ValueError('Duplicate JSON key')
            result[key] = value
        return result
    if path.stat().st_size > 4*1024*1024:
        raise ValueError('Oversized JSON')
    return json.loads(path.read_text(encoding='utf-8-sig'), object_pairs_hook=pairs)


def safe_name(name):
    # Windows path, ADS, case alias, reserved device and traversal rejection.
    if not isinstance(name, str) or not name or '\\' in name or ':' in name or name.startswith('/'):
        raise ValueError('Unsafe artifact path')
    if len(name) > 240 or any(ord(c) < 32 for c in name):
        raise ValueError('Unsafe artifact path')
    for part in name.split('/'):
        if part in ('', '.', '..') or part.endswith((' ', '.')) or any(c in part for c in '<>"|?*'):
            raise ValueError('Unsafe artifact segment')
        if re.match(r'^(con|prn|aux|nul|com[0-9]|lpt[0-9])(?:\.|$)', part, re.I):
            raise ValueError('Reserved artifact path')
    return name


def files(root):
    if root.is_symlink() or root.is_junction():
        raise ValueError('Reparse root')
    rows = {}
    aliases = set()
    for p in sorted(root.rglob('*')):
        if p.is_symlink() or p.is_junction() or (getattr(p.lstat(), 'st_file_attributes', 0) & 0x400):
            raise ValueError('Reparse artifact')
        if p.is_file():
            name = safe_name(p.relative_to(root).as_posix())
            if name.casefold() in aliases:
                raise ValueError('Case-aliased artifact')
            aliases.add(name.casefold())
            rows[name] = p
    if not rows or len(rows) > 10000:
        raise ValueError('Unexpected payload size')
    return rows


def write_new(path, doc):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open('x', encoding='utf-8', newline='\n') as f:
        json.dump(doc, f, indent=2, sort_keys=True)
        f.write('\n')


def make_manifest(root, commit, submodules, beta):
    if not COMMIT.fullmatch(commit) or type(beta) is not int or not 110 <= beta <= 65535:
        raise ValueError('Invalid source/new beta (105..109 already issued)')
    if not submodules or any(not COMMIT.fullmatch(v) for v in submodules.values()):
        raise ValueError('Exact submodule revisions required')
    paths = files(root)
    if not OWNED <= paths.keys():
        raise ValueError('Missing owned payload')
    return {'schema': 1, 'commit': commit, 'submodules': submodules, 'beta': beta,
            'trust': 'UNSIGNED_LOCAL_MANIFEST_NOT_ORIGIN_PROOF',
            'files': [{'path': name, 'sha256': sha(p), 'size': p.stat().st_size,
                       'scope': 'candidate-owned' if name in OWNED else 'include-only'}
                      for name, p in paths.items()]}


def verify(root, manifest_path, expected_digest, commit, submodules):
    if not HASH.fullmatch(expected_digest) or sha(manifest_path) != expected_digest:
        raise ValueError('Manifest digest mismatch')
    doc = read_json(manifest_path)
    if doc.get('schema') != 1 or not COMMIT.fullmatch(commit) or doc.get('commit') != commit:
        raise ValueError('Source commit mismatch')
    if not submodules or doc.get('submodules') != submodules or any(not COMMIT.fullmatch(v) for v in submodules.values()):
        raise ValueError('Submodule mismatch')
    if type(doc.get('beta')) is not int or not 110 <= doc['beta'] <= 65535:
        raise ValueError('Invalid or already-issued beta')
    paths = files(root)
    rows = doc.get('files', [])
    names = [safe_name(row['path']) for row in rows]
    if len(set(n.casefold() for n in names)) != len(names) or set(names) != paths.keys() or not OWNED <= paths.keys():
        raise ValueError('Payload file set mismatch')
    for row in rows:
        name = row['path']
        if row.get('scope') != ('candidate-owned' if name in OWNED else 'include-only'):
            raise ValueError('Unauthorized scope')
        if type(row.get('size')) is not int or paths[name].stat().st_size != row['size']:
            raise ValueError('Size mismatch')
        if not HASH.fullmatch(row.get('sha256', '')) or sha(paths[name]) != row['sha256']:
            raise ValueError('File digest mismatch')
    return doc


def verify_origin(run, artifact, commit, beta):
    # Input JSON must be retrieved from authenticated GitHub REST by the trusted
    # workflow. Passing attacker-authored JSON here does not establish trust.
    if (not COMMIT.fullmatch(commit) or type(beta) is not int or not 110 <= beta <= 65535 or
        run.get('repository', {}).get('full_name') != 'Alex777rast/MasterDesk' or
        run.get('head_repository', {}).get('full_name') != 'Alex777rast/MasterDesk' or
        run.get('workflow_id') != 323927768 or run.get('event') != 'workflow_dispatch' or
        run.get('run_attempt') != 1 or
        run.get('conclusion') != 'success' or run.get('status') != 'completed' or
        run.get('head_sha') != commit or run.get('head_branch') != 'codex/x64-signing-source-20261106'):
        raise ValueError('Untrusted build run')
    if (type(run.get('id')) is not int or artifact.get('workflow_run', {}).get('id') != run['id'] or
        artifact.get('workflow_run', {}).get('head_sha') != commit or artifact.get('expired') is not False or
        artifact.get('name') != f'MasterDesk-x64-payload-beta-{beta}-{commit}' or
        not re.fullmatch(r'sha256:[0-9a-f]{64}', artifact.get('digest', ''))):
        raise ValueError('Untrusted artifact')


def extract_zip(archive, output, expected_digest):
    if not HASH.fullmatch(expected_digest) or sha(archive) != expected_digest or output.exists():
        raise ValueError('Archive digest mismatch or destination exists')
    with zipfile.ZipFile(archive) as z:
        members, seen, total = [], set(), 0
        for info in z.infolist():
            # ZipInfo.filename is normalized on Windows (and NUL-truncated).
            # Validate the raw central-directory spelling BEFORE normalization.
            raw = info.orig_filename
            name = safe_name(raw.rstrip('/') if info.is_dir() else raw)
            if name.casefold() in seen or stat.S_ISLNK(info.external_attr >> 16) or info.flag_bits & 1:
                raise ValueError('Duplicate/symlink/encrypted ZIP member')
            seen.add(name.casefold())
            total += info.file_size
            if total > 2*1024**3 or len(seen) > 10000:
                raise ValueError('ZIP expansion bound')
            members.append((info, name))
        # Reject file/directory collision before making any destination.
        file_names = {name.casefold() for info, name in members if not info.is_dir()}
        for _, name in members:
            if any(str(p).casefold() in file_names for p in PurePosixPath(name).parents if str(p) != '.'):
                raise ValueError('ZIP file/directory collision')
        output.mkdir(parents=True)
        for info, name in members:
            dest = output/name
            if info.is_dir():
                dest.mkdir(parents=True, exist_ok=True)
                continue
            dest.parent.mkdir(parents=True, exist_ok=True)
            with z.open(info) as source, dest.open('xb') as target:
                count = 0
                while chunk := source.read(65536):
                    count += len(chunk)
                    if count > info.file_size:
                        raise ValueError('ZIP size mismatch')
                    target.write(chunk)
            if count != info.file_size:
                raise ValueError('Truncated ZIP')


def activation_guard(_config):
    # No boolean/secret/environment input may activate signing in this revision.
    raise ValueError('BLOCKED: Foundation approval, reviewed configuration and a separately authorized implementation required')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('mode', choices=['manifest', 'verify', 'activation-check'])
    parser.add_argument('--payload', type=Path)
    parser.add_argument('--manifest', type=Path)
    parser.add_argument('--commit')
    parser.add_argument('--submodule')
    parser.add_argument('--beta', type=int)
    parser.add_argument('--digest')
    args = parser.parse_args()
    if args.mode == 'activation-check':
        activation_guard({})
    modules = {'libs/hbb_common': args.submodule}
    if args.mode == 'manifest':
        write_new(args.manifest, make_manifest(args.payload, args.commit, modules, args.beta))
    else:
        verify(args.payload, args.manifest, args.digest, args.commit, modules)
    print('PASS '+args.mode+'; no signing request or artifact execution')
