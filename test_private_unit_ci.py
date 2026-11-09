import copy
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
import zipfile
import private_unit_ci as p


class ProtocolTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='private-unit-guards-')
        self.root = Path(self.tmp.name)
        self.addCleanup(self.tmp.cleanup)

    def git(self, *args, cwd=None):
        return subprocess.run(['git', *args], cwd=cwd or self.root, check=True, capture_output=True,
                              creationflags=subprocess.CREATE_NO_WINDOW if os.name == 'nt' else 0).stdout

    def fixture(self):
        repo = self.root / 'repo'
        repo.mkdir()
        source = {'pom.xml': b'<project/>\n', 'SeleniumModule/pom.xml': b'<project/>\n',
                  'CaptchaSolverModule/pom.xml': b'<project/>\n', 'BaseModule/pom.xml': b'<project/>\n',
                  'BaseModule/A.java': b'class A { int n = 1; }\n',
                  'tests/one.test.js': b'// private fixture\n'}
        self.git('init', cwd=repo)
        self.git('config', 'core.autocrlf', 'false', cwd=repo)
        for name, raw in source.items():
            path = repo / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(raw)
        self.git('add', '.', cwd=repo)
        red_tree = self.git('write-tree', cwd=repo).decode().strip()
        (repo / 'BaseModule/A.java').write_bytes(b'class A { int n = 2; }\n')
        patch = self.git('diff', '--no-ext-diff', '--binary', cwd=repo)
        self.git('add', '.', cwd=repo)
        green_tree = self.git('write-tree', cwd=repo).decode().strip()
        green_source = dict(source, **{'BaseModule/A.java': b'class A { int n = 2; }\n'})

        def manifest(files, tree):
            inventory = [{'path': n, 'mode': '100644', 'git_blob': p.blob(v)} for n, v in files.items()]
            self.assertEqual(tree, p.merkle(inventory)[0])  # independent normal Git index proof
            return {'format': 'leadya-private-unit-manifest/v1', 'tree': tree, 'inventory': inventory,
                    'source_files': [{**r, 'bytes': len(files[r['path']]), 'sha256': p.digest(files[r['path']])} for r in inventory]}
        plan = {'format': 'leadya-private-unit-spec/v1', 'compile_modules': ['BaseModule'],
                'red': {'module': 'BaseModule', 'class': 'sample.Case', 'method': 'fails', 'failure_contains': 'expected blocked'},
                'green': [{'module': 'BaseModule', 'tests': ['sample.Case']}],
                'node': ['tests/one.test.js'], 'green_patch_sha256': p.digest(patch)}
        controls = {'control/source-manifest.json': json.dumps(manifest(source, red_tree)).encode(),
                    'control/green-manifest.json': json.dumps(manifest(green_source, green_tree)).encode(),
                    'control/unit-spec.json': json.dumps(plan).encode(), 'control/green.patch': patch}
        return source, controls, plan, red_tree, green_tree

    def archive(self, source, controls, extras=None):
        path = self.root / 'source.zip'
        with zipfile.ZipFile(path, 'w', zipfile.ZIP_DEFLATED) as archive:
            for name, raw in {**{'source/' + n: v for n, v in source.items()}, **controls, **(extras or {})}.items():
                archive.writestr(name, raw)
        return path

    def test_normal_git_tree_proves_source_then_exact_green_patch(self):
        source, controls, plan, red, green = self.fixture()
        archive = self.archive(source, controls)
        destination = self.root / 'materialized'
        evidence = p.materialize(archive, destination, red, green, p.digest(archive.read_bytes()))
        self.assertEqual(len(source), evidence['verified_source_files'])
        p.apply_green(destination / 'source', destination / 'control', red, green)
        self.assertIn(b'n = 2', (destination / 'source/BaseModule/A.java').read_bytes())

    def test_source_tampering_cannot_reuse_git_manifest(self):
        source, controls, _, red, green = self.fixture()
        source['BaseModule/A.java'] = b'class A { int n = 9; }\n'
        archive = self.archive(source, controls)
        with self.assertRaisesRegex(ValueError, 'SOURCE_BLOB_MISMATCH'):
            p.materialize(archive, self.root / 'out', red, green, p.digest(archive.read_bytes()))

    def test_unlisted_file_is_refused_before_extraction(self):
        source, controls, _, red, green = self.fixture()
        archive = self.archive(source, controls, {'source/unlisted.java': b'no'})
        with self.assertRaisesRegex(ValueError, 'ZIP_MANIFEST_CLOSURE'):
            p.materialize(archive, self.root / 'out', red, green, p.digest(archive.read_bytes()))
        self.assertFalse((self.root / 'out').exists())

    def test_git_metadata_limit_is_distinct_from_extracted_file_limit(self):
        inventory = [{'path': 'excluded/' + str(i), 'mode': '100644', 'git_blob': '1' * 40} for i in range(12001)]
        self.assertRegex(p.merkle(inventory)[0], r'^[0-9a-f]{40}$')
        with self.assertRaisesRegex(ValueError, 'BAD_INVENTORY'):
            p.merkle(inventory * 5)

    def test_checking_program_is_compile_only_and_cannot_select_its_tests(self):
        _, _, plan, _, _ = self.fixture()
        plan['compile_modules'].append('CheckingProgram')
        self.assertIn('CheckingProgram', p.spec(plan)['compile_modules'])
        bad = copy.deepcopy(plan)
        bad['red']['module'] = 'CheckingProgram'
        with self.assertRaisesRegex(ValueError, 'BAD_RED_SPEC'):
            p.spec(bad)
        bad = copy.deepcopy(plan)
        bad['green'].append({'module': 'CheckingProgram', 'tests': ['sample.Checking']})
        with self.assertRaisesRegex(ValueError, 'BAD_GREEN_MODULE'):
            p.spec(bad)

    def test_node_scope_is_bounded_at_128_files(self):
        _, _, plan, _, _ = self.fixture()
        plan['node'] = ['tests/guard-' + str(i) + '.test.cjs' for i in range(128)]
        self.assertEqual(128, len(p.spec(plan)['node']))
        plan['node'].append('tests/one-too-many.test.cjs')
        with self.assertRaisesRegex(ValueError, 'BAD_NODE_SPEC'):
            p.spec(plan)

    def test_only_named_n8n_workflow_suite_may_lack_a_test_directory(self):
        _, _, plan, _, _ = self.fixture()
        plan['node'] = ['docker/n8n/workflows/leadya-chat-rag-code.test.cjs']
        self.assertEqual(plan, p.spec(plan))
        plan['node'] = ['docker/n8n/workflows/another.test.cjs']
        with self.assertRaisesRegex(ValueError, 'BAD_NODE_PATH'):
            p.spec(plan)

    def test_path_traversal_windows_aliases_and_private_paths(self):
        for name in ('../bad', '/bad', 'a/../b', 'a\\b', 'a:b', 'x/NUL.txt', 'x/CON', 'x/a.', '.git/config', 'a/settings.xml', 'a/target/evil'):
            with self.subTest(name=name), self.assertRaises(ValueError):
                p.relative(name)

    def reports(self, body):
        reports = self.root / 'reports'
        reports.mkdir(exist_ok=True)
        (reports / 'TEST-sample.xml').write_text('<testsuite>' + body + '</testsuite>')
        return reports

    def test_red_requires_exact_assertion_not_compilation_error_skip_or_wrong_test(self):
        plan = {'red': {'class': 'sample.Case', 'method': 'fails', 'failure_contains': 'expected blocked'}}
        good = '<testcase classname="sample.Case" name="fails"><failure type="org.opentest4j.AssertionFailedError" message="expected blocked"/></testcase>'
        self.assertTrue(p.evaluate_red(self.reports(good), plan, 1)['causal_red'])
        for bad, code in [(good, 0), (good.replace('fails', 'other'), 1), (good.replace('failure', 'error'), 1),
                          (good.replace('expected blocked', 'unrelated'), 1), ('<testcase classname="sample.Case" name="fails"><skipped/></testcase>', 1), ('', 1)]:
            with self.subTest(body=bad), self.assertRaises(ValueError):
                p.evaluate_red(self.reports(bad), plan, code)

    def test_green_missing_class_or_skipped_case_cannot_pass(self):
        good = '<testcase classname="sample.Case" name="works"/>'
        self.assertEqual(1, p.evaluate_green(self.reports(good), ['sample.Case'], 0)['tests'])
        with self.assertRaises(ValueError):
            p.evaluate_green(self.reports(good), ['sample.Case', 'missing.Case'], 0)
        with self.assertRaises(ValueError):
            p.evaluate_green(self.reports(good.replace('/>', '><skipped/></testcase>')), ['sample.Case'], 0)

    def test_node_summary_requires_real_nonempty_no_skipped_run(self):
        log = self.root / 'node.log'
        good = '# tests 2\n# pass 2\n# fail 0\n# cancelled 0\n# skipped 0\n'
        log.write_text(good)
        self.assertEqual(2, p.evaluate_node(log, 0)['tests'])
        for bad in (good.replace('# skipped 0', '# skipped 1'), good + '# tests 2\n', ''):
            log.write_text(bad)
            with self.assertRaises(ValueError):
                p.evaluate_node(log, 0)

    def test_green_cannot_remove_the_red_regression(self):
        red = {'class': 'sample.Case', 'method': 'regression'}
        reports = self.reports('<testcase classname="sample.Case" name="another"/>')
        with self.assertRaisesRegex(ValueError, 'GREEN_MISSING_RED_REGRESSION'):
            p.evaluate_green(reports, ['sample.Case'], 0, red)
        reports = self.reports('<testcase classname="sample.Case" name="regression"/>')
        self.assertEqual(1, p.evaluate_green(reports, ['sample.Case'], 0, red)['tests'])

    def test_report_size_checked_before_read(self):
        reports = self.reports('')
        with (reports / 'TEST-sample.xml').open('wb') as stream:
            stream.truncate(8 * 1024 * 1024 + 1)
        with self.assertRaisesRegex(ValueError, 'TEST_REPORT_LIMIT'):
            p.test_cases(reports)

    def test_workflow_has_no_browser_auth_and_uploads_only_cipher(self):
        workflow = (Path(__file__).parent / '.github/workflows/build.yml').read_text()
        self.assertNotIn('BROWSER_AUTH', workflow)
        self.assertEqual(89, workflow.count('${{ secrets.LEADYA_RELEASE_B7A46C8D209E_P'))
        artifact = workflow.split('uses: actions/upload-artifact@')[1]
        self.assertNotIn('unit-private-result', artifact)
        self.assertIn('/result.cipher', artifact)
        self.assertIn('/result-envelope.json', artifact)
        self.assertIn("'--memory-gib','2','--disk-gib','3'", workflow)
        self.assertIn('-Log "$env:DEVUNIT_RESULT_ROOT/admission-acquire.log"', workflow)
        self.assertNotIn('-Log "$env:RUNNER_TEMP/unit-acquire-private.log"', workflow)

    @unittest.skipUnless(os.name == 'nt', 'Windows command transport')
    def test_real_inner_cmd_preserves_spaces_and_exit_code(self):
        from run_private_units import cmd_line, execute
        directory = self.root / 'command with spaces'
        directory.mkdir()
        command = directory / 'synthetic tool.cmd'
        command.write_bytes(b'@echo off\r\nif not "%~1"=="argument with spaces" exit /b 19\r\necho received-spaced-argument\r\nexit /b 7\r\n')
        log = self.root / 'cmd.log'
        code = execute(cmd_line([str(command), 'argument with spaces']), directory, log, 10)
        self.assertEqual(7, code)
        self.assertIn('received-spaced-argument', log.read_text())
        with self.assertRaisesRegex(ValueError, 'CMD_META_REFUSED'):
            cmd_line([str(command), 'safe & unsafe'])

    @unittest.skipUnless(os.name == 'nt', 'Windows Maven command transport')
    def test_every_maven_command_disables_only_deployment_copy_antrun(self):
        from run_private_units import cmd_line, execute, maven_command
        directory = self.root / 'fake maven path'
        directory.mkdir()
        command = directory / 'mvn.cmd'
        command.write_bytes(b'@echo off\r\nif not "%~4"=="-Dmaven.antrun.skip=true" exit /b 19\r\nif not "%~6"=="install" exit /b 20\r\nexit /b 7\r\n')
        code = execute(cmd_line(maven_command(str(command), directory / 'm2', ['install'])), directory, self.root / 'mvn.log', 10)
        self.assertEqual(7, code)


if __name__ == '__main__':
    import sys
    with Path(sys.argv[1]).open('w', encoding='utf-8') if len(sys.argv) == 2 else __import__('contextlib').nullcontext(sys.stderr) as output:
        unittest.main(argv=[sys.argv[0]], testRunner=unittest.TextTestRunner(stream=output, verbosity=2))
