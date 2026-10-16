"""Network and archive boundaries for the public CI dependency bootstrap."""
import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import zipfile

import ci_bootstrap as ci


class DependencyTests(unittest.TestCase):
    def test_bad_checksum_is_not_cached(self):
        with tempfile.TemporaryDirectory() as tmp:
            entry = {'filename': 'sdk.exe', 'url': 'https://downloads.sourceforge.net/sdk.exe',
                     'sha256': hashlib.sha256(b'expected').hexdigest()}
            with patch.object(ci, 'fetch', return_value=b'corrupt payload'):
                with self.assertRaisesRegex(ValueError, 'SHA-256 mismatch'):
                    ci.obtain(entry, Path(tmp))
            self.assertFalse((Path(tmp) / 'sdk.exe').exists())

    def test_sourceforge_refresh_is_followed_and_bytes_verified(self):
        payload = b'MZfixture'
        entry = {'filename': 'sdk.exe', 'url': 'https://prdownloads.sourceforge.net/sdk.exe',
                 'sourceforge_path': '/project/nsis/sdk.exe', 'sha256': ci.digest(payload)}
        page = b'<meta http-equiv="refresh" content="5; url=https://downloads.sourceforge.net/project/nsis/sdk.exe?ts=x&amp;r=">'
        with tempfile.TemporaryDirectory() as tmp, patch.object(ci, 'fetch', side_effect=[page, payload]) as fetch:
            self.assertEqual(ci.obtain(entry, Path(tmp)).read_bytes(), payload)
            self.assertEqual(fetch.call_args.args[0], 'https://downloads.sourceforge.net/project/nsis/sdk.exe?ts=x&r=')

    def test_refresh_cannot_switch_to_unrelated_host(self):
        entry = {'filename': 'sdk.exe', 'url': 'https://prdownloads.sourceforge.net/sdk.exe',
                 'sourceforge_path': '/project/nsis/sdk.exe', 'sha256': '0' * 64}
        page = b'<meta http-equiv="refresh" content="5; url=https://example.com/project/nsis/sdk.exe">'
        with tempfile.TemporaryDirectory() as tmp, patch.object(ci, 'fetch', return_value=page) as fetch:
            with self.assertRaisesRegex(ValueError, 'official HTTPS'):
                ci.obtain(entry, Path(tmp))
            self.assertEqual(fetch.call_count, 1)

    def test_http_redirect_is_refused(self):
        with self.assertRaisesRegex(ValueError, 'official HTTPS'):
            ci.official_url('http://downloads.sourceforge.net/sdk.exe')

    def test_wrong_plugin_does_not_write_output(self):
        with tempfile.TemporaryDirectory() as tmp:
            archive = Path(tmp) / 'plugin.zip'
            with zipfile.ZipFile(archive, 'w') as package:
                package.writestr('unicode/plugin.dll', b'MZwrong')
            entry = {'member': 'unicode/plugin.dll', 'name': 'plugin.dll', 'dll_sha256': '0' * 64}
            with self.assertRaisesRegex(ValueError, 'Plugin SHA-256'):
                ci.copy_plugin(archive, entry, Path(tmp))
            self.assertFalse((Path(tmp) / 'plugin.dll').exists())

    def test_unsafe_archive_member_is_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaisesRegex(ValueError, 'archive member'):
                ci.copy_plugin(Path(tmp) / 'unused.zip', {'member': '../escape.dll'}, Path(tmp))

    def test_manifest_pins_only_existing_runtime_plugins(self):
        config = json.loads(Path(__file__).with_name('ci-dependencies.json').read_text())
        self.assertEqual({p['name'] for p in config['plugins']}, ci.PLUGINS)
        for entry in [config['compiler'], *config['plugins']]:
            self.assertRegex(entry['sha256'], r'^[a-f0-9]{64}$')
            ci.official_url(entry['url'])


if __name__ == '__main__':
    unittest.main()
