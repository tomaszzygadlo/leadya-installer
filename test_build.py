import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
import subprocess
import sys
from unittest.mock import patch
from types import SimpleNamespace

spec = importlib.util.spec_from_file_location('installer_build', Path(__file__).with_name('build.py'))
build = importlib.util.module_from_spec(spec)
spec.loader.exec_module(build)


class BuildBoundaryTests(unittest.TestCase):
    def test_adapter_refuses_raw_validator_pin_mismatch_before_compiler(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            helper = root / 'ValidateLocalInstall.ps1'
            helper.write_bytes(b'Write-Output "LOCAL_VALID"\n')
            script = root / 'Leadya.generated.nsi'
            script.write_text('!define LEADYA_VALIDATOR_SHA256 "' + build.sha256(helper).upper() + '"\n', encoding='utf-8')
            arguments = ['build.py', '--source-directory', str(root), '--generated-script', str(script)]
            with patch.object(sys, 'argv', arguments), patch.object(build, 'compile_script') as compiler:
                build.main()
                compiler.assert_called_once()
            # A normal text-source inventory tolerates checkout EOL changes; the runtime pin cannot.
            helper.write_bytes(b'Write-Output "LOCAL_VALID"\r\n')
            with patch.object(sys, 'argv', arguments), patch.object(build, 'compile_script') as compiler:
                with self.assertRaisesRegex(ValueError, 'validator pin'):
                    build.main()
                compiler.assert_not_called()
            helper.unlink()
            with patch.object(sys, 'argv', arguments), patch.object(build, 'compile_script') as compiler:
                with self.assertRaisesRegex(ValueError, 'validator pin'):
                    build.main()
                compiler.assert_not_called()

    def test_render_cli_works_without_monorepo_or_version_file(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            template = '!define url "old"\nOutFile "old"\n!define public_origin "old"\n  !define chromium_ver "1"\n; Zażółć\n'
            (root / 'Leadya.nsi').write_text(template, encoding='utf-8')
            script = root / 'Leadya.generated.nsi'
            output = root / 'package.exe'
            subprocess.run([sys.executable, str(Path(build.__file__)), '--source-directory', str(root),
                            '--render-script', str(script), '--output', str(output),
                            '--backend-url', 'http://127.0.0.1:8082', '--public-origin', 'http://localhost:8080',
                            '--allow-loopback-http'], check=True, timeout=15)
            self.assertTrue(script.read_bytes().startswith(b'\xef\xbb\xbf'))
            text = script.read_text(encoding='utf-8-sig')
            self.assertIn('  !define chromium_ver "142"', text)
            self.assertIn('; Zażółć', text)
            self.assertFalse(output.exists())

    def test_compiler_keeps_sdk_and_package_versions_separate(self):
        for package_version in (None, '0.11.38.148'):
            with self.subTest(version=package_version), patch.object(build.shutil, 'which', return_value='makensis'), \
                    patch.object(build, 'sha256', return_value='a'*64), \
                    patch.object(build.subprocess, 'run', side_effect=[SimpleNamespace(stdout='v3.13\n'), SimpleNamespace()]) as run:
                sdk = build.compile_script('Leadya.generated.nsi', version=package_version)
                self.assertEqual('v3.13', sdk['version'])
                arguments = run.call_args_list[1].args[0]
                definitions = [arg for arg in arguments if 'DLEADYA_INSTALLER_VERSION=' in arg]
                self.assertEqual([] if package_version is None else
                                 [('/' if build.os.name == 'nt' else '-') + 'DLEADYA_INSTALLER_VERSION=' + package_version], definitions)

    def test_windows_version_has_four_bounded_numeric_parts(self):
        self.assertEqual('0.11.38.148', build.installer_version('0.11.38.148'))
        for value in ('1.2.3', '1.2.3.65536', '1.2.3.-1', '1.2.3.4\n', '1.2.3.$0'):
            with self.subTest(value=value), self.assertRaises(ValueError):
                build.installer_version(value)

    def test_render_preserves_unicode_and_has_literal_nsis_output(self):
        template = '!define url "old"\n!define public_origin "old"\nOutFile "old"\n !define chromium_ver "1"\n; Zażółć\n'
        rendered = build.render(template, Path('target/space $value.exe'),
                                'https://backend.example.test', 'https://example.test', '142')
        self.assertIn('Zażółć', rendered)
        self.assertIn('$$value.exe', rendered)
        self.assertIn('!define chromium_ver "142"', rendered)
        self.assertIn('\n !define chromium_ver "142"\n', rendered)

    def test_http_is_limited_to_explicit_local_development(self):
        for value in ('http://localhost:8082', 'http://127.0.0.1:8082', 'http://[::1]:8082'):
            with self.subTest(value=value):
                self.assertEqual(value, build.origin(value, allow_loopback_http=True))
                with self.assertRaises(ValueError): build.origin(value)
        for value in ('http://example.test', 'http://0.0.0.0', 'http://localhost.example.test'):
            with self.subTest(value=value), self.assertRaises(ValueError):
                build.origin(value, allow_loopback_http=True)

    def test_ambiguous_declaration_refused(self):
        with self.assertRaises(ValueError):
            build.render('!define url "old"\n!define url "other"\n', 'out.exe',
                         'https://example.test', 'https://example.test', '142')

    def test_unsafe_origins_refused(self):
        for value in ['http://example.test', 'https://user:secret@example.test',
                      'https://example.test/path', 'https://example.test/?query=1',
                      'https://example.test/#fragment', 'https://example.test/$0',
                      'https://example.test/\n!system anything', 'https://example.test:invalid',
                      'https://bad host.example', 'https://example.test\x00evil',
                      'https://@example.test', 'https://example.test?', 'https://example.test#',
                      'https://exa\tmple.test', 'https://[::1]extra', 'https://-bad.example']:
            with self.subTest(value=value), self.assertRaises(ValueError):
                build.origin(value)

    def test_dns_length_is_measured_after_idna_encoding(self):
        with self.assertRaises(ValueError):
            build.origin('https://' + '.'.join(['ü' * 47] * 5))

    def test_valid_dns_unicode_ipv6_and_port_origins(self):
        for value in ['https://example.test', 'https://EXAMPLE.test:8443',
                      'https://[::1]:8443', 'https://żółć.example']:
            self.assertEqual(value, build.origin(value))

    def test_flat_layout_stages_sources_and_external_plugins(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source, destination, plugins = (root / name for name in ('source', 'staged', 'plugins'))
            for path in (source, destination, plugins): path.mkdir()
            (source / 'Polish.nsh').write_bytes(b'language source')
            (source / 'installer-inputs.json').write_text(json.dumps({'Polish.nsh':'Language/Polish.nsh'}))
            for name in ('AccessControl.dll', 'INetC.dll', 'nsisunz.dll', 'ShellExecAsUser.dll'):
                (plugins / name).write_bytes(b'fixture; never loaded')
            self.assertEqual(destination, build.stage_inputs(source, destination, plugins))
            self.assertEqual(b'language source', (destination / 'Language/Polish.nsh').read_bytes())
            self.assertEqual(b'fixture; never loaded', (destination / 'plugins/INetC.dll').read_bytes())
            (plugins / 'INetC.dll').unlink()
            with self.assertRaises(ValueError): build.stage_inputs(source, destination, plugins)

    def test_flat_layout_refuses_escape_alias_and_ambiguous_targets(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'a.txt').write_text('input')
            (root / 'b.txt').write_text('input')
            for entries in ({'a.txt':'../escape'}, {'a.txt':'C:/escape'}, {'../a.txt':'ok'},
                            {'a.txt':'same', 'b.txt':'SAME'}, [], {'a.txt':None}):
                with self.subTest(entries=entries):
                    (root / 'installer-inputs.json').write_text(json.dumps(entries))
                    with self.assertRaises(ValueError): build.stage_inputs(root, root / 'out')

    def test_pinned_snapshot_rejects_changed_missing_and_traversal_sources(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / 'source.txt'; source.write_bytes(b'original\r\n')
            lock = {'schema':'leadya-installer-source/v1',
                    'repository':'https://github.com/tomaszzygadlo/leadya-installer',
                    'commit':'a'*40, 'normalization':'strip-utf8-bom+lf',
                    'files':{'source.txt':build.source_sha256(source)}}
            path = root / 'lock.json'; path.write_text(json.dumps(lock), encoding='utf-8')
            self.assertEqual('a'*40, build.verify_snapshot(root, path))
            source.write_bytes(b'\xef\xbb\xbforiginal\n')
            self.assertEqual('a'*40, build.verify_snapshot(root, path))
            source.write_bytes(b'changed')
            with self.assertRaises(ValueError): build.verify_snapshot(root, path)
            source.unlink()
            with self.assertRaises(ValueError): build.verify_snapshot(root, path)
            lock['files'] = {'../source.txt':'0'*64}; path.write_text(json.dumps(lock), encoding='utf-8')
            with self.assertRaises(ValueError): build.verify_snapshot(root, path)


if __name__ == '__main__':
    unittest.main()
