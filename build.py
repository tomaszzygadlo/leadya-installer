#!/usr/bin/env python3
"""Build one NSIS variant or verify a pinned, offline source snapshot (stdlib only)."""
import argparse
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
from urllib.parse import urlsplit


def sha256(path):
    with Path(path).open('rb') as source:
        digest = hashlib.sha256()
        for chunk in iter(lambda: source.read(1024 * 1024), b''):
            digest.update(chunk)
        return digest.hexdigest()


def source_sha256(path):
    if Path(path).suffix.lower() in ('.ico', '.bmp', '.dll'):
        return sha256(path)
    data = Path(path).read_bytes()
    if data.startswith(b'\xef\xbb\xbf'):
        data = data[3:]
    return hashlib.sha256(data.replace(b'\r\n', b'\n')).hexdigest()


def verify_snapshot(root, lock_path):
    root = Path(root).resolve()
    lock = json.loads(Path(lock_path).read_text(encoding='utf-8-sig'))
    if (lock.get('schema') != 'leadya-installer-source/v1' or
            lock.get('repository') != 'https://github.com/tomaszzygadlo/leadya-installer' or
            lock.get('normalization') != 'strip-utf8-bom+lf' or
            not re.fullmatch(r'[0-9a-f]{40}', lock.get('commit', '')) or
            not isinstance(lock.get('files'), dict) or not lock['files']):
        raise ValueError('Invalid installer source lock')
    for relative, expected in lock['files'].items():
        name = Path(relative)
        if (name.is_absolute() or '..' in name.parts or '\\' in relative or
                ':' in relative or not re.fullmatch(r'[0-9a-f]{64}', expected)):
            raise ValueError('Invalid installer source entry')
        path = root / name
        current = path
        while current != root:
            if current.exists() and (current.is_symlink() or
                    getattr(current.lstat(), 'st_file_attributes', 0) & 0x400):
                raise ValueError('Aliased installer source refused')
            current = current.parent
        if not path.is_file() or source_sha256(path) != expected:
            raise ValueError('Installer source differs from pinned snapshot: ' + relative)
    return lock['commit']


def origin(value, allow_loopback_http=False):
    if (not isinstance(value, str) or any(ord(c) <= 32 or ord(c) == 127 or c.isspace() for c in value) or
            any(c in value for c in '?#"$\\')):
        raise ValueError('Invalid HTTPS origin characters')
    parsed = urlsplit(value)
    host = parsed.hostname
    try:
        local = host == 'localhost' or ipaddress.ip_address(host).is_loopback
    except ValueError:
        local = False
    scheme_allowed = parsed.scheme == 'https' or (allow_loopback_http and parsed.scheme == 'http' and local)
    if (not scheme_allowed or not host or parsed.username is not None or
            parsed.password is not None or parsed.path not in ('', '/')):
        raise ValueError('An HTTPS origin without credentials, path or NSIS tokens is required')
    host = parsed.hostname
    try:
        ipaddress.ip_address(host)
    except ValueError:
        dns_name = host[:-1] if host.endswith('.') else host
        ascii_name = dns_name.encode('idna').decode('ascii')
        labels = ascii_name.split('.')
        if len(ascii_name) > 253 or any(not re.fullmatch(r'[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?', label) for label in labels):
            raise ValueError('Invalid HTTPS origin host')
    authority = re.escape('[' + host + ']' if ':' in host else host)
    if not re.fullmatch(authority + r'(?::[0-9]{1,5})?', parsed.netloc, flags=re.IGNORECASE):
        raise ValueError('Invalid HTTPS origin authority')
    # Also force validation of an optional port.
    parsed.port
    return value.rstrip('/')


def nsis_string(value):
    if any(c in value for c in '\r\n\x00'):
        raise ValueError('Invalid NSIS string')
    return value.replace('$', '$$').replace('"', '$\\"')


def stage_inputs(source, destination, plugin_directory=None):
    """Map the small public source bundle to NSIS's historical include layout."""
    layout = source / 'installer-inputs.json'
    if not layout.exists():
        return source
    entries = json.loads(layout.read_text(encoding='utf-8'))
    if not isinstance(entries, dict) or not entries:
        raise ValueError('Installer input layout must be a nonempty object')
    destinations = set()
    for filename, relative in entries.items():
        if not isinstance(relative, str):
            raise ValueError('Invalid installer input layout')
        name, target = Path(filename), Path(relative)
        if (name.name != filename or filename in ('', '.', '..') or
                any(c in filename for c in '\\:') or name.is_absolute() or
                target.is_absolute() or not target.name or '..' in target.parts or
                '\\' in relative or ':' in relative or
                str(target).casefold() in destinations):
            raise ValueError('Invalid installer input layout')
        destinations.add(str(target).casefold())
        path = source / name
        if path.is_symlink() or not path.is_file() or getattr(path.lstat(), 'st_file_attributes', 0) & 0x400:
            raise ValueError('Missing or aliased installer input: ' + filename)
        output = destination / target
        output.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(path, output)
    plugins = Path(plugin_directory) if plugin_directory else source / 'plugins'
    for filename in ('AccessControl.dll', 'INetC.dll', 'nsisunz.dll', 'ShellExecAsUser.dll'):
        path = plugins / filename
        if not path.is_file() or path.is_symlink() or getattr(path.lstat(), 'st_file_attributes', 0) & 0x400:
            raise ValueError('Provide the separately licensed Unicode plugin: ' + filename)
        output = destination / 'plugins' / filename
        output.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(path, output)
    return destination


def render(template, output, backend_url, public_origin, chromium_version, allow_loopback_http=False):
    if not re.fullmatch(r'[1-9][0-9]{0,4}', chromium_version):
        raise ValueError('Invalid Chromium version')
    replacements = {
        r'^(!define url )[^\r\n]*$': origin(backend_url, allow_loopback_http),
        r'^(!define public_origin )[^\r\n]*$': origin(public_origin, allow_loopback_http),
        r'^(OutFile )[^\r\n]*$': nsis_string(str(Path(output).resolve())),
        r'^([ \t]*!define chromium_ver )[^\r\n]*$': chromium_version,
    }
    text = template.replace('\r\n', '\n')
    for pattern, replacement in replacements.items():
        text, count = re.subn(pattern, lambda match: match.group(1) + '"' + replacement + '"', text, flags=re.MULTILINE)
        if count != 1:
            raise ValueError('Installer template must contain exactly one declaration: ' + pattern)
    return text


def installer_version(value):
    if (not re.fullmatch(r'[0-9]{1,5}(?:\.[0-9]{1,5}){3}', value) or
            any(int(part) > 65535 for part in value.split('.'))):
        raise ValueError('Installer version must contain four integers in 0..65535')
    return value


def verify_validator_pin(template, source):
    # The elevated runtime hashes exact bytes, independently of text-source EOL normalization.
    if 'LEADYA_VALIDATOR_SHA256' not in template:
        return  # The separate VPS template does not use the LOCAL validator.
    pins = re.findall(r'^!define LEADYA_VALIDATOR_SHA256 "([0-9A-Fa-f]{64})"[ \t]*$',
                      template, flags=re.MULTILINE)
    helper = source / 'ValidateLocalInstall.ps1'
    if (len(pins) != 1 or not helper.is_file() or helper.is_symlink() or
            getattr(helper.lstat(), 'st_file_attributes', 0) & 0x400 or
            sha256(helper) != pins[0].lower()):
        raise ValueError('LOCAL validator pin differs from the exact helper bytes')


def resolve_compiler(compiler='makensis'):
    """Verify the same stable SDK requirement for release builds and native test fixtures."""
    compiler = shutil.which(compiler)
    if not compiler:
        raise ValueError('NSIS compiler unavailable; install NSIS 3.13 or later')
    prefix = '/' if os.name == 'nt' else '-'
    result = subprocess.run([compiler, prefix + 'VERSION'], capture_output=True, text=True,
                            check=True, timeout=15, **({'creationflags': subprocess.CREATE_NO_WINDOW} if os.name == 'nt' else {}))
    sdk_version = result.stdout.strip()
    match = re.fullmatch(r'v?(\d+)\.(\d+)(?:\.(\d+))?', sdk_version)
    if not match or tuple(int(x or 0) for x in match.groups()) < (3, 13, 0):
        raise ValueError('Supported stable NSIS >=3.13 required; observed ' + sdk_version)
    return compiler, sdk_version


def compile_script(script, compiler='makensis', working_directory=None, version=None):
    compiler, sdk_version = resolve_compiler(compiler)
    prefix = '/' if os.name == 'nt' else '-'
    definitions = [prefix + 'DLEADYA_INSTALLER_VERSION=' + installer_version(version)] if version else []
    subprocess.run([compiler, prefix + 'NOCONFIG', prefix + 'NOCD'] + definitions + [str(Path(script).resolve())],
                   cwd=working_directory, check=True, timeout=300,
                   **({'creationflags': subprocess.CREATE_NO_WINDOW} if os.name == 'nt' else {}))
    return {'version': sdk_version, 'compiler_sha256': sha256(compiler)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--verify-snapshot', type=Path)
    parser.add_argument('--source-directory', type=Path, default=Path(__file__).resolve().parent)
    parser.add_argument('--generated-script', type=Path)
    parser.add_argument('--render-script', type=Path, help='Render a private adapter script without compiling it')
    parser.add_argument('--output', type=Path)
    parser.add_argument('--backend-url', default='https://backend.turbot.pro')
    parser.add_argument('--public-origin', default='https://hotfix.turbot.pro')
    parser.add_argument('--chromium-version', default='142')
    parser.add_argument('--compiler', default='makensis')
    parser.add_argument('--verify-compiler', action='store_true', help='Verify the SDK without compiling or executing a fixture')
    parser.add_argument('--installer-version', help='Four-part Windows file version; defaults to installer-version.txt')
    parser.add_argument('--plugin-directory', type=Path)
    parser.add_argument('--allow-loopback-http', action='store_true', help='Allow HTTP only for explicit localhost/loopback development variants')
    options = parser.parse_args()
    if options.verify_compiler:
        compiler, sdk_version = resolve_compiler(options.compiler)
        print(json.dumps({'compiler': compiler, 'version': sdk_version, 'sha256': sha256(compiler)}))
        return
    source = options.source_directory.resolve()
    if options.verify_snapshot:
        commit = verify_snapshot(source, options.verify_snapshot)
        verify_validator_pin((source / 'Leadya.nsi').read_text(encoding='utf-8-sig'), source)
        print('Verified installer snapshot ' + commit)
        return
    if options.generated_script:
        # Adapter mode: caller owns rendering and the enclosing provenance manifest.
        verify_validator_pin(options.generated_script.read_text(encoding='utf-8-sig'), source)
        compile_script(options.generated_script, options.compiler, source)
        return
    if not options.output or options.output.suffix.lower() != '.exe':
        parser.error('--output must name an .exe package')
    output = Path(os.path.abspath(options.output))
    if output.is_symlink() or (output.exists() and (not output.is_file() or
            getattr(output.lstat(), 'st_file_attributes', 0) & 0x400)):
        raise ValueError('Output must be an ordinary package file')
    output.parent.mkdir(parents=True, exist_ok=True)
    template = (source / 'Leadya.nsi').read_text(encoding='utf-8-sig')
    verify_validator_pin(template, source)
    if options.render_script:
        text = render(template, output,
                      options.backend_url, options.public_origin, options.chromium_version, options.allow_loopback_http)
        with options.render_script.open('w', encoding='utf-8-sig', newline='\n') as stream:
            stream.write(text)
        return
    version = installer_version(options.installer_version if options.installer_version is not None else
                                (source / 'installer-version.txt').read_text(encoding='utf-8-sig').strip())
    # Includes and plugin paths resolve against the explicit source directory.
    with tempfile.TemporaryDirectory(prefix='leadya-nsis-', dir=output.parent) as temporary:
        staged_source = Path(temporary) / 'source'
        staged_source.mkdir()
        working_directory = stage_inputs(source, staged_source, options.plugin_directory)
        candidate = Path(temporary) / output.name
        text = render(template, candidate,
                      options.backend_url, options.public_origin, options.chromium_version, options.allow_loopback_http)
        script = Path(temporary) / 'Leadya.generated.nsi'
        with script.open('w', encoding='utf-8-sig', newline='\n') as stream:
            stream.write(text)
        sdk = compile_script(script, options.compiler, working_directory, version)
        if not candidate.is_file() or candidate.stat().st_size < 2:
            raise ValueError('Compiler did not produce a Windows executable')
        with candidate.open('rb') as stream:
            if stream.read(2) != b'MZ':
                raise ValueError('Compiler output is not a Windows executable')
        evidence = {'schema': 'leadya-installer-build/v1', 'publication_ready': False,
                    'artifact_sha256': sha256(candidate), 'installer_version': version, 'sdk': sdk,
                    'generated_nsi_sha256': hashlib.sha256(text.encode('utf-8-sig')).hexdigest()}
        receipt = Path(temporary) / 'build.json'
        receipt.write_text(json.dumps(evidence, indent=2) + '\n', encoding='utf-8')
        os.replace(candidate, output)
        os.replace(receipt, output.with_suffix('.build.json'))


if __name__ == '__main__':
    main()
