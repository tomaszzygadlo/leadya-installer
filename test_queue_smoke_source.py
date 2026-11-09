import ast
import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

source = Path(__file__).with_name('postdeploy-queue-smoke.py')
spec = importlib.util.spec_from_file_location('queue_smoke', source)
smoke = importlib.util.module_from_spec(spec)
spec.loader.exec_module(smoke)


class QueueInputBoundaryTests(unittest.TestCase):
    def configuration(self):
        return dict(url='https://hotfix.turbot.pro', expected_version='0.12.4.0',
                    queue_account_inactive_verified=True, dedicated_disposable_user4_session_verified=True,
                    queue_session_cookie=dict(name='SESSION', value='FAKE_NOT_A_SESSION'),
                    queue_campaign_id=1001, queue_fixture_tag='[TEST] 0.12.4.0 queue b7a46c8d-209e-4f30-a65d-4bbdebc6fbdf',
                    queue_rows=[dict(id=index + 1, campaign=1001, mode=mode, period=period, account_name='')
                                for index, (mode, period) in enumerate(zip(('QUICK_REFRESH', 'DISCOVER_GROUPS', 'REFRESH'), (1, 24, 24)))])

    def parse(self, configuration):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'private-input.json'
            path.write_text(json.dumps(configuration))
            return smoke.configuration(path)

    def test_rendered_polish_literals_have_exact_unicode_codepoints(self):
        values = {node.value for node in ast.walk(ast.parse(source.read_text(encoding='utf8')))
                  if isinstance(node, ast.Constant) and isinstance(node.value, str)}
        self.assertIn('Sprawdzam kto odpisa\u0142', values)
        self.assertIn('Aktualizacja status\u00f3w', values)
        self.assertIn('\u2014', values)

    def test_known_private_input_is_accepted_without_browser(self):
        self.assertEqual(3, len(self.parse(self.configuration())['queue_rows']))

    def test_wrong_environment_is_refused(self):
        value = self.configuration()
        value['url'] = 'https://leadya.pro'
        with self.assertRaises(AssertionError):
            self.parse(value)

    def test_unknown_account_activity_is_refused(self):
        value = self.configuration()
        value['queue_account_inactive_verified'] = False
        with self.assertRaises(AssertionError):
            self.parse(value)

    def test_shared_session_is_refused(self):
        value = self.configuration()
        value['dedicated_disposable_user4_session_verified'] = False
        with self.assertRaises(AssertionError):
            self.parse(value)

    def test_extra_sql_row_is_not_silently_filtered(self):
        value = self.configuration()
        value['queue_rows'].append(copy.deepcopy(value['queue_rows'][0]))
        with self.assertRaises(AssertionError):
            self.parse(value)

    def test_changed_campaign_is_refused(self):
        value = self.configuration()
        value['queue_rows'][0]['campaign'] = 1
        with self.assertRaises(AssertionError):
            self.parse(value)

    def test_existing_protected_campaign_cannot_be_used_as_queue_fixture(self):
        value = self.configuration()
        value['queue_campaign_id'] = 242
        with self.assertRaises(AssertionError):
            self.parse(value)

    def test_unowned_queue_tag_is_refused(self):
        value = self.configuration()
        value['queue_fixture_tag'] = 'not an owned test fixture'
        with self.assertRaises(AssertionError):
            self.parse(value)


if __name__ == '__main__':
    unittest.main()
