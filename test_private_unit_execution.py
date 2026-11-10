"""Filesystem/report guards only; never starts Maven, Java or application code."""
import os
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import private_unit_ci as p
import run_private_units as r


class ExecutionGuards(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='unit-execution-guard-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.source = self.root / 'source'
        self.source.mkdir()
        self.reports = self.source / 'BaseModule/target/surefire-reports'
        self.reports.mkdir(parents=True)
        self.xml = self.reports / 'TEST-sample.xml'

    def write_red(self, method):
        self.xml.write_text('<testsuite><testcase classname="sample.Case" name="' + method +
                            '"><failure type="org.opentest4j.AssertionFailedError" message="expected blocked"/>'
                            '</testcase></testsuite>', encoding='utf8')
        return {'red': {'class': 'sample.Case', 'method': method, 'failure_contains': 'expected blocked'}}

    def test_two_reds_in_same_module_preserve_distinct_xml_and_refuse_stale_first(self):
        first = self.write_red('first')
        r.preserved_evaluation(self.reports, self.root / 'red0', p.evaluate_red, first, 1)
        saved = (self.root / 'red0/TEST-sample.xml').read_bytes()
        r.retire_owned_red_reports(self.source, 'BaseModule', self.reports)
        self.assertFalse(self.reports.exists())
        self.reports.mkdir()
        self.xml.write_bytes(saved)
        second = {'red': dict(first['red'], method='second')}
        with self.assertRaisesRegex(ValueError, 'RED_WRONG_FAILURE'):
            r.preserved_evaluation(self.reports, self.root / 'stale-refused', p.evaluate_red, second, 1)
        self.write_red('second')
        r.preserved_evaluation(self.reports, self.root / 'red1', p.evaluate_red, second, 1)
        r.retire_owned_red_reports(self.source, 'BaseModule', self.reports)
        self.assertEqual(saved, (self.root / 'red0/TEST-sample.xml').read_bytes())
        self.assertNotEqual(saved, (self.root / 'red1/TEST-sample.xml').read_bytes())

    def test_retirement_refuses_foreign_module_path_and_reparse_without_deleting(self):
        self.xml.write_text('preserve')
        for module, path, error in [('foreign', self.reports, 'FOREIGN_REPORT_MODULE'),
                                    ('CheckingProgram', self.reports, 'REPORT_RETIREMENT_OUTSIDE_SOURCE')]:
            with self.assertRaisesRegex(ValueError, error):
                r.retire_owned_red_reports(self.source, module, path)
        original = Path.lstat
        def reparse(path):
            info = original(path)
            return SimpleNamespace(st_mode=info.st_mode, st_file_attributes=1024) if path == self.reports else info
        with patch.object(Path, 'lstat', reparse), self.assertRaisesRegex(ValueError, 'REPARSE_OR_SYMLINK'):
            r.retire_owned_red_reports(self.source, 'BaseModule', self.reports)
        self.assertEqual('preserve', self.xml.read_text())

    def test_green_requires_every_causal_red_once_even_when_same_class(self):
        reds = [{'class': 'sample.Case', 'method': name} for name in ('first', 'second')]
        def report(names):
            self.xml.write_text('<testsuite>' + ''.join('<testcase classname="sample.Case" name="' + name +
                                '"/>' for name in names) + '</testsuite>')
        report(['first', 'second'])
        self.assertEqual(2, p.evaluate_green(self.reports, ['sample.Case'], 0, reds)['tests'])
        for names in (['first'], ['second'], ['first', 'second', 'second']):
            report(names)
            with self.assertRaisesRegex(ValueError, 'GREEN_MISSING_RED_REGRESSION'):
                p.evaluate_green(self.reports, ['sample.Case'], 0, reds)

    def test_native_heap_option_does_not_leak_into_server_modules(self):
        self.assertEqual(['-DargLine=-Xmx64m', '-Dleadya.test.smallHeap=true'], r.module_test_options('CheckingProgram'))
        self.assertEqual([], r.module_test_options('SpringAppBase'))
        self.assertEqual([], r.module_test_options('SpringAppFrontend'))

    def test_legacy_red_evidence_keeps_original_object_and_directory(self):
        v1 = {'format': 'leadya-private-unit-spec/v1'}
        v2 = {'format': 'leadya-private-unit-spec/v2'}
        rows = [{'tests': 1}]
        self.assertEqual(rows[0], r.red_evidence(v1, rows))
        self.assertEqual(rows, r.red_evidence(v2, rows))
        self.assertEqual(self.root / 'red-reports', r.red_report_destination(self.root, v1, 0))
        self.assertEqual(self.root / 'red-1-reports', r.red_report_destination(self.root, v2, 1))


if __name__ == '__main__':
    unittest.main()
