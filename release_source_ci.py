"""Pinned private-source build transport; never executes an installer."""
import argparse
import base64
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import subprocess
import tarfile

DOMAINS = ('LEADYA_APP', 'LEADYA_PRO', 'TURBOT_PRO', 'TURBO_BOT_APP',
           'HOTFIX_LEADYA_APP', 'HOTFIX_LEADYA_PRO', 'HOTFIX_TURBOT_PRO', 'HOTFIX_TURBO_BOT_APP',
           'TESTOWY_LEADYA_APP', 'TESTOWY_LEADYA_PRO', 'TESTOWY_TURBOT_PRO', 'TESTOWY_TURBO_BOT_APP')


def sha(data):
    return hashlib.sha256(data).hexdigest()


def git(root, *args):
    env = dict(os.environ, GIT_NO_LAZY_FETCH='1', GIT_TERMINAL_PROMPT='0')
    return subprocess.run(['git', '-c', 'protocol.allow=never', '-C', str(root), *args],
                          env=env, capture_output=True, check=True,
                          creationflags=subprocess.CREATE_NO_WINDOW if os.name == 'nt' else 0).stdout


def members(archive):
    result = archive.getmembers()
    if len(result) > 500 or sum(m.size for m in result) > 32 * 1024 * 1024:
        raise ValueError('Source transport exceeds its bound')
    seen = set()
    for member in result:
        name = member.name
        path = PurePosixPath(name)
        if ('\\' in name or ':' in name or path.is_absolute() or '..' in path.parts
                or name != path.as_posix() or any(p.endswith((' ', '.')) for p in path.parts)
                or any(p.split('.')[0].upper() in {'CON','PRN','AUX','NUL',*(f'COM{n}' for n in range(1,10)),*(f'LPT{n}' for n in range(1,10))} for p in path.parts)
                or name.casefold() in seen or not member.isfile()
                or not (name == 'transport-manifest.json' or name.startswith('source/.git/'))
                or name.startswith('source/.git/hooks/') or name == 'source/.git/index'):
            raise ValueError('Unsafe or unexpected source member')
        seen.add(name.casefold())
    return result


def validate_files(root, closure):
    observed = set()
    for row in closure['source_files']:
        path = PurePosixPath(row['path'])
        if path.is_absolute() or '..' in path.parts or '\\' in row['path'] or ':' in row['path']:
            raise ValueError('Invalid source input name')
        full = root.joinpath(*path.parts)
        current = full
        while current != root.parent:
            info = current.lstat()
            if info.st_mode & 0o170000 == 0o120000 or getattr(info, 'st_file_attributes', 0) & 1024:
                raise ValueError('Aliased source input')
            current = current.parent
        raw = full.read_bytes()
        identity = hashlib.sha1(b'blob ' + str(len(raw)).encode() + b'\0' + raw).hexdigest()
        if len(raw) != row['bytes'] or sha(raw) != row['sha256'] or identity != row['git_blob']:
            raise ValueError('Source input differs from frozen blob')
        observed.add(row['path'])
    if not set(closure['required_paths']) <= observed:
        raise ValueError('Required source closure missing')
    return len(observed)


def materialize(args):
    encoded = ''.join(os.environ[f'LEADYA_SOURCE_{n:03}'] for n in range(args.parts))
    raw = base64.b64decode(encoded, validate=True)
    if sha(raw) != args.archive_sha256:
        raise ValueError('Source archive SHA256 mismatch')
    destination = Path(args.destination)
    destination.mkdir(parents=True, exist_ok=False)
    with tarfile.open(fileobj=io.BytesIO(raw), mode='r:xz') as archive:
        for member in members(archive):
            target = destination.joinpath(*PurePosixPath(member.name).parts)
            target.parent.mkdir(parents=True, exist_ok=True)
            with archive.extractfile(member) as source, target.open('xb') as output:
                shutil.copyfileobj(source, output)
    closure = json.loads((destination / 'transport-manifest.json').read_text())
    if closure['commit'] != args.commit or closure['tree'] != args.tree:
        raise ValueError('Unexpected Git identity in source transport')
    root = destination / 'source'
    if (root / '.git/objects/info/alternates').exists() or (root / '.git/commondir').exists():
        raise ValueError('External object dependency refused')
    if Path(git(root, 'rev-parse', '--show-toplevel').decode().strip()).resolve() != root.resolve():
        raise ValueError('External working directory refused')
    if git(root, 'config', '--get', 'remote.origin.url').decode().strip() != 'https://invalid.invalid/offline-build-source':
        raise ValueError('Build source must be offline')
    if git(root, 'rev-parse', 'HEAD', 'HEAD^{tree}').decode().split() != [args.commit, args.tree]:
        raise ValueError('Git object identity mismatch')
    if git(root, 'rev-parse', '--is-shallow-repository').strip() != b'true':
        raise ValueError('Expected genuine shallow source')
    if git(root, 'config', '--get', 'remote.origin.promisor').strip() != b'true':
        raise ValueError('Expected genuine promisor source')
    git(root, 'checkout', '--detach', 'HEAD')
    count = validate_files(root, closure)
    if git(root, 'status', '--porcelain'):
        raise ValueError('Materialized source is dirty')
    git(root, 'fsck', '--connectivity-only', '--no-dangling')
    (destination / 'input-provenance.json').write_text(json.dumps(dict(
        source_commit=args.commit, source_tree=args.tree, archive_sha256=args.archive_sha256,
        verified_inputs=count, lazy_fetch_disabled=True, complete_working_checkout=False), indent=2))
    print(json.dumps({'materialized': True, 'verified_inputs': count, 'source_commit': args.commit}))


def collect(args):
    root = Path(args.source)
    result = Path(args.result)
    result.mkdir(parents=True, exist_ok=True)
    source = root / 'docker/botserver/installers'
    target = result / 'installers'
    target.mkdir(exist_ok=False)
    expected = []
    for domain in DOMAINS:
        expected.extend((f'LeadyaInstaller-{domain}.exe', f'LeadyaVpsInstaller-{domain}.exe',
                         f'LeadyaVpsInstaller-{domain}.manifest', f'LeadyaVpsInstaller-{domain}.txt'))
    expected.append('LeadyaInstaller-HOTFIX_TURBOT_PRO.manifest.json')
    frozen = []
    payload = (root / 'SpringAppFrontend/src/main/resources/scripts/Install-LeadYaVpsWindows.ps1').read_bytes()
    payload_sha = sha(payload.decode('utf-8-sig').replace('\r\n', '\n').encode())
    for name in expected:
        file = source / name
        if not file.is_file() or file.is_symlink() or file.stat().st_size > 8 * 1024 * 1024:
            raise ValueError('Missing or invalid final build output')
        raw = file.read_bytes()
        if name.endswith('.exe') and not raw.startswith(b'MZ'):
            raise ValueError('PE output required')
        if name.endswith('.manifest'):
            manifest = dict(line.split('=', 1) for line in raw.decode('utf-8-sig').splitlines())
            expected_exe = name[:-len('.manifest')] + '.exe'
            if manifest.get('installer') != expected_exe:
                raise ValueError('Unexpected VPS manifest filename')
            exe = source / expected_exe
            if (manifest.get('source_commit') != args.commit or manifest.get('source_dirty') != 'false'
                    or manifest.get('payload_sha256') != payload_sha
                    or manifest.get('exe_sha256') != sha(exe.read_bytes())):
                raise ValueError('VPS build provenance mismatch')
        shutil.copyfile(file, target / name)
        frozen.append(dict(filename=name, sha256=sha(raw), bytes=len(raw)))
    producer = json.loads((target / expected[-1]).read_text(encoding='utf-8-sig'))
    local_name = 'LeadyaInstaller-HOTFIX_TURBOT_PRO.exe'
    if (producer.get('producer_commit') != args.commit or producer.get('filename') != local_name
            or producer.get('exe_sha256') != sha((target / local_name).read_bytes())
            or producer.get('compile', {}).get('exit_code') != 0):
        raise ValueError('LOCAL producer receipt mismatch')
    (result / 'final-assets.json').write_text(json.dumps(dict(
        source_commit=args.commit, assets=frozen, signing='UNSIGNED',
        av_status='NOT_YET_ASSESSED', publication_ready=False), indent=2))
    print(json.dumps({'collected': len(frozen), 'publication_ready': False}))


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest='mode', required=True)
    load = sub.add_parser('materialize')
    for option in ('destination', 'archive-sha256', 'commit', 'tree'):
        load.add_argument('--' + option, required=True)
    load.add_argument('--parts', type=int, required=True)
    freeze = sub.add_parser('collect')
    for option in ('source', 'result', 'commit'):
        freeze.add_argument('--' + option, required=True)
    parsed = parser.parse_args()
    (materialize if parsed.mode == 'materialize' else collect)(parsed)
