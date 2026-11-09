import argparse
import hashlib
import io
import json
import tarfile
import tempfile
from pathlib import Path
import unittest

import release_source_ci as ci


class SourceTransportTests(unittest.TestCase):
    def archive(self, names):
        raw = io.BytesIO()
        with tarfile.open(fileobj=raw, mode='w') as archive:
            for name, kind in names:
                entry = tarfile.TarInfo(name)
                entry.type = kind
                entry.size = 1 if kind == tarfile.REGTYPE else 0
                archive.addfile(entry, io.BytesIO(b'x') if entry.size else None)
        return tarfile.open(fileobj=io.BytesIO(raw.getvalue()))

    def test_rejects_traversal_links_hooks_and_case_collisions(self):
        for name, kind in [('../escape', tarfile.REGTYPE), ('/absolute', tarfile.REGTYPE),
                           ('source\\..\\escape', tarfile.REGTYPE),
                           ('source/.git/hooks/post-checkout', tarfile.REGTYPE),
                           ('source/.git/link', tarfile.SYMTYPE),
                           ('source/.git/hardlink', tarfile.LNKTYPE),
                           ('source/.git/index', tarfile.REGTYPE)]:
            with self.subTest(name=name), self.archive([(name, kind)]) as archive:
                with self.assertRaises(ValueError):
                    ci.members(archive)
        with self.archive([('source/.git/HEAD', tarfile.REGTYPE),
                           ('source/.git/head', tarfile.REGTYPE)]) as archive:
            with self.assertRaises(ValueError):
                ci.members(archive)

    def test_accepts_only_regular_transport_members(self):
        with self.archive([('source/.git/HEAD', tarfile.REGTYPE),
                           ('transport-manifest.json', tarfile.REGTYPE)]) as archive:
            self.assertEqual(2, len(ci.members(archive)))

    def test_detects_missing_and_changed_required_bytes(self):
        raw = b'actual immutable source\n'
        row = dict(path='required.txt', bytes=len(raw), sha256=ci.sha(raw),
                   git_blob=hashlib.sha1(b'blob ' + str(len(raw)).encode() + b'\0' + raw).hexdigest())
        closure = dict(source_files=[row], required_paths=['required.txt'])
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with self.assertRaises(FileNotFoundError):
                ci.validate_files(root, closure)
            (root / 'required.txt').write_bytes(raw)
            self.assertEqual(1, ci.validate_files(root, closure))
            (root / 'required.txt').write_bytes(raw.replace(b'actual', b'forged'))
            with self.assertRaises(ValueError):
                ci.validate_files(root, closure)

    def test_manifest_cannot_silently_omit_a_required_path(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(ValueError):
                ci.validate_files(Path(directory), dict(source_files=[], required_paths=['missing']))

    def test_real_producer_false_flag_and_complete_twelve_domain_outputs(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / 'source'
            outputs = root / 'docker/botserver/installers'
            outputs.mkdir(parents=True)
            payload = root / 'SpringAppFrontend/src/main/resources/scripts/Install-LeadYaVpsWindows.ps1'
            payload.parent.mkdir(parents=True)
            payload.write_bytes(b'\xef\xbb\xbf# fixture payload\r\n')
            commit = '1' * 40
            for domain in ci.DOMAINS:
                for prefix in ('LeadyaInstaller-', 'LeadyaVpsInstaller-'):
                    (outputs / (prefix + domain + '.exe')).write_bytes(b'MZ' + domain.encode())
                name = 'LeadyaVpsInstaller-' + domain
                manifest = {'format': '1', 'installer': name + '.exe',
                            'exe_sha256': ci.sha((outputs / (name + '.exe')).read_bytes()),
                            'payload': 'scripts/Install-LeadYaVpsWindows.ps1',
                            'payload_sha256': ci.sha(b'# fixture payload\n'),
                            'source_commit': commit, 'source_dirty': 'false',
                            'built_at': '2026-11-09T00:00:00Z'}
                (outputs / (name + '.manifest')).write_text(''.join(k + '=' + v + '\n' for k, v in manifest.items()))
                (outputs / (name + '.txt')).write_text('leadya_backend_url=https://example.invalid\n')
            local = 'LeadyaInstaller-HOTFIX_TURBOT_PRO.exe'
            (outputs / 'LeadyaInstaller-HOTFIX_TURBOT_PRO.manifest.json').write_text(json.dumps({
                'producer_commit': commit, 'filename': local,
                'exe_sha256': ci.sha((outputs / local).read_bytes()), 'compile': {'exit_code': 0}}))
            result = Path(directory) / 'result'
            ci.collect(argparse.Namespace(source=str(root), result=str(result), commit=commit))
            assets = json.loads((result / 'final-assets.json').read_text())['assets']
            self.assertEqual(24, sum(row['filename'].endswith('.exe') for row in assets))
            self.assertEqual(49, len(assets))
            bad = outputs / 'LeadyaVpsInstaller-LEADYA_APP.manifest'
            bad.write_text(bad.read_text().replace('source_dirty=false', 'source_dirty=true'))
            with self.assertRaises(ValueError):
                ci.collect(argparse.Namespace(source=str(root), result=str(Path(directory) / 'bad-result'), commit=commit))


if __name__ == '__main__':
    unittest.main()
