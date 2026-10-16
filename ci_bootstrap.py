"""Prepare pinned official NSIS dependencies without running an installer."""
import argparse
import hashlib
from html.parser import HTMLParser
import json
from pathlib import Path, PurePosixPath
import re
import subprocess
import urllib.parse
import urllib.request
import zipfile

LIMIT = 10_000_000
PLUGINS = {'AccessControl.dll', 'INetC.dll', 'nsisunz.dll', 'ShellExecAsUser.dll'}


def digest(data):
    return hashlib.sha256(data).hexdigest()


def official_url(url):
    u = urllib.parse.urlsplit(url)
    host = (u.hostname or '').lower()
    if (u.scheme != 'https' or u.username or u.password or u.port not in (None, 443)
            or not any(host == suffix or host.endswith('.' + suffix)
                       for suffix in ('sourceforge.net', 'sourceforge.io'))):
        raise ValueError('Expected an official HTTPS SourceForge download')
    return url


class OfficialRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        official_url(newurl)
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def fetch(url):
    opener = urllib.request.build_opener(OfficialRedirect())
    with opener.open(official_url(url), timeout=45) as response:
        data = response.read(LIMIT + 1)
    if len(data) > LIMIT:
        raise ValueError('Dependency download exceeds size limit')
    return data


class DownloadRefresh(HTMLParser):
    def __init__(self):
        super().__init__()
        self.urls = []

    def handle_starttag(self, tag, attrs):
        values = dict(attrs)
        if tag == 'meta' and values.get('http-equiv', '').lower() == 'refresh':
            parts = re.split(r'url=', values.get('content', ''), maxsplit=1, flags=re.I)
            if len(parts) == 2:
                self.urls.append(parts[1].strip())


def filename(value):
    if not isinstance(value, str) or not value or value in ('.', '..') or any(c in value for c in '/\\:'):
        raise ValueError('Ordinary dependency filename required')
    return value


def obtain(entry, cache):
    target = cache / filename(entry['filename'])
    if target.is_file() and digest(target.read_bytes()) == entry['sha256']:
        return target
    data = fetch(entry['url'])
    if entry.get('sourceforge_path') and not data.startswith(b'MZ'):
        parser = DownloadRefresh()
        parser.feed(data.decode('utf-8', errors='replace'))
        if len(parser.urls) != 1:
            raise ValueError('No unambiguous official download link')
        url = official_url(parser.urls[0])
        if urllib.parse.unquote(urllib.parse.urlsplit(url).path) != entry['sourceforge_path']:
            raise ValueError('Unexpected SourceForge release path')
        data = fetch(url)
    if digest(data) != entry['sha256']:
        raise ValueError('Dependency SHA-256 mismatch: ' + entry['filename'])
    target.write_bytes(data)
    return target


def copy_plugin(archive, entry, destination):
    member = PurePosixPath(entry['member'])
    if member.is_absolute() or '..' in member.parts or any(c in entry['member'] for c in '\\:'):
        raise ValueError('Ordinary archive member required')
    with zipfile.ZipFile(archive) as package:
        info = package.getinfo(entry['member'])
        if info.file_size > LIMIT:
            raise ValueError('Plugin exceeds size limit')
        data = package.read(info)
    if not data.startswith(b'MZ') or digest(data) != entry['dll_sha256']:
        raise ValueError('Plugin SHA-256 or PE header mismatch: ' + entry['name'])
    (destination / filename(entry['name'])).write_bytes(data)


def bootstrap(config, output, seven_zip):
    names = [p['name'] for p in config['plugins']]
    if len(names) != len(PLUGINS) or set(names) != PLUGINS:
        raise ValueError('Exactly the four reviewed Unicode plugins are required')
    output.mkdir(parents=True, exist_ok=False)
    cache = output / 'archives'
    cache.mkdir()
    installer = obtain(config['compiler'], cache)
    sdk = output / 'nsis'
    # Read the official self-extracting archive; never execute its setup program.
    subprocess.run([str(seven_zip), 'x', '-y', '-o' + str(sdk), str(installer)],
                   check=True, timeout=60, capture_output=True)
    compiler = sdk / 'makensis.exe'
    if digest(compiler.read_bytes()) != config['compiler']['compiler_sha256']:
        raise ValueError('Extracted compiler SHA-256 mismatch')
    plugins = output / 'plugins'
    plugins.mkdir()
    for plugin in config['plugins']:
        copy_plugin(obtain(plugin, cache), plugin, plugins)
    receipt = {'compiler': str(compiler.resolve()), 'plugins': str(plugins.resolve()),
               'compiler_sha256': config['compiler']['compiler_sha256'],
               'dependencies': config, 'signing_configured': False}
    (output / 'ci-sdk.json').write_text(json.dumps(receipt, indent=2) + '\n', encoding='utf-8')
    return receipt


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--seven-zip', type=Path, required=True)
    args = parser.parse_args()
    config = json.loads(Path(__file__).with_name('ci-dependencies.json').read_text(encoding='utf-8-sig'))
    print(json.dumps(bootstrap(config, args.output.resolve(), args.seven_zip.resolve())))
