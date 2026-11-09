import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from browser_result_transport import collect


class TransportBoundaryTests(unittest.TestCase):
    def test_real_landing_tab_screenshot_name_is_supported(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.fixture(root)
            (root / 'landing_tab.png').write_bytes(b'\x89PNG\r\n\x1a\nfixture')
            result = collect(root)
            self.assertEqual('landing_tab.png', result['screenshots'][0]['filename'])

    def fixture(self, root, status='PASS'):
        (root / 'result.json').write_text(json.dumps(dict(kind='automated-selenium-e2e', version='0.12.4.0', status=status)))

    def test_preserves_browser_status_and_exact_screenshot_bytes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.fixture(root)
            raw = b'\x89PNG\r\n\x1a\nexact-private-test-bytes'
            (root / 'user-loaded.png').write_bytes(raw)
            result = collect(root)
            self.assertEqual('PASS', result['result']['status'])
            self.assertEqual(hashlib.sha256(raw).hexdigest(), result['screenshots'][0]['sha256'])

    def test_does_not_turn_browser_failure_into_success(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.fixture(root, 'FAIL')
            self.assertEqual('FAIL', collect(root)['result']['status'])

    def test_private_auth_file_cannot_enter_output_transport(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.fixture(root)
            (root / 'session.json').write_text('{"private": true}')
            with self.assertRaises(ValueError):
                collect(root)

    def test_missing_browser_result_is_not_evidence(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(ValueError):
                collect(directory)

    def test_wrong_target_version_is_refused(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'result.json').write_text('{"kind":"automated-selenium-e2e","version":"0.12.3.12"}')
            with self.assertRaises(ValueError):
                collect(root)


if __name__ == '__main__':
    unittest.main()
