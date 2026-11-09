"""Package private real-browser evidence into the existing authenticated transport."""
import argparse
import base64
import hashlib
import json
import pathlib
import re


def collect(directory, kind='automated-selenium-e2e'):
    root = pathlib.Path(directory)
    if not root.is_dir() or root.is_symlink():
        raise ValueError('Missing real browser output')
    files = list(root.iterdir())
    if len(files) > 24:
        raise ValueError('Too many evidence files')
    results = None
    screenshots = []
    total = 0
    for path in sorted(files):
        if path.is_symlink() or not path.is_file():
            raise ValueError('Unexpected evidence entry')
        size = path.stat().st_size
        total += size
        if total > 10 * 1024 * 1024:
            raise ValueError('Evidence exceeds bound')
        raw = path.read_bytes()
        if path.name == 'result.json':
            results = json.loads(raw)
            if results.get('kind') != kind or results.get('version') != '0.12.4.0':
                raise ValueError('Wrong browser result purpose')
        elif re.fullmatch(r'[a-z0-9_-]{1,80}\.png', path.name) and raw.startswith(b'\x89PNG\r\n\x1a\n'):
            screenshots.append(dict(filename=path.name, bytes=len(raw), sha256=hashlib.sha256(raw).hexdigest(), png_base64=base64.b64encode(raw).decode()))
        else:
            raise ValueError('Unexpected evidence filename/type')
    if results is None:
        raise ValueError('No real browser result')
    return dict(format='leadya-browser-evidence/v1', target_commit='4bbdebc6fbdf74a2ae9e592774fa98f927c675a6', url='https://hotfix.turbot.pro', result=results, screenshots=screenshots)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--directory', required=True)
    parser.add_argument('--queue-directory', required=True)
    parser.add_argument('--output', required=True)
    args = parser.parse_args()
    payload = collect(args.directory)
    payload['queue'] = collect(args.queue_directory, 'automated-queue-browser-smoke')
    payload['status'] = 'PASS' if payload['result']['status'] == 'PASS' and payload['queue']['result']['status'] == 'PASS' else 'FAIL'
    with open(args.output, 'xb') as stream:
        stream.write((json.dumps(payload, ensure_ascii=False) + '\n').encode())
