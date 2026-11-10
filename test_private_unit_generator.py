"""Guard tests use a fake generator; they never run Java or generate product locales."""
import copy
import json
from pathlib import Path
import tempfile
import unittest
import private_unit_ci as p
import private_unit_generator as g


class GeneratorGuards(unittest.TestCase):
    def fixture(self):
        temp = tempfile.TemporaryDirectory(prefix='unit-generator-guard-')
        self.addCleanup(temp.cleanup)
        root = Path(temp.name).resolve()
        source, control, result = (root / name for name in ('source', 'control', 'result'))
        for directory in (source, control, result):
            directory.mkdir()
        key = 'user.cloud.payment.pending'
        translation = 'documentation/plans/fixture/translations.json'
        values = {Path(name).stem.removeprefix('messages_'): {key: 'Reviewed ' + Path(name).stem}
                  for name in g.LOCALES if not name.endswith('_pl.properties')}
        files = {'SpringAppFrontend/pom.xml': b'<project/>\n',
                 g.BASE: (key + ' = Polski tekst\nother=preserved\n').encode(),
                 g.GENERATOR: b'class PropertiesSorter {}\n', translation: json.dumps(values).encode()}
        files.update({name: b'other=preserved\n' for name in g.LOCALES})
        for name, raw in files.items():
            target = source / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(raw)
        jar = source / 'SpringAppFrontend/target/SpringAppFrontend-1.0-exec.jar'
        jar.parent.mkdir(parents=True)
        jar.write_bytes(b'fake-test-classpath')
        inventory = [{'path': name, 'mode': '100644', 'git_blob': p.blob(raw)} for name, raw in files.items()]
        tree = p.merkle(inventory)[0]
        manifest = {'format': 'leadya-private-unit-manifest/v1', 'tree': tree, 'inventory': inventory,
                    'source_files': [dict(row, bytes=len(files[row['path']]), sha256=p.digest(files[row['path']]))
                                     for row in inventory]}
        for name in ('source-manifest.json', 'green-manifest.json'):
            (control / name).write_text(json.dumps(manifest), encoding='utf8')
        plan = {'sorter': {'keys': [key], 'translations': translation}}

        def execute(command, cwd, log, timeout):
            self.assertEqual(source, cwd)
            self.assertEqual(120, timeout)
            self.assertIn('org.springframework.boot.loader.PropertiesLauncher', command)
            self.assertIn('-Xmx128m', command)
            log.write_text('FAKE GENERATOR: control guard test only', encoding='utf8')
            for name in g.LOCALES:
                language = Path(name).stem.removeprefix('messages_')
                value = 'Polski tekst' if language == 'pl' else values[language][key]
                (source / name).write_bytes(b'other=preserved\n' + (key + ' = ' + value + '\n').encode())
            return 0
        return source, control, result, plan, tree, execute

    def test_derived_tree_records_only_thirteen_generated_locales_and_preserves_input(self):
        source, control, result, plan, tree, execute = self.fixture()
        rows, derived = g.generate(source, control, result, plan, Path('java.exe'), execute, tree)
        self.assertNotEqual(tree, derived)
        proof = json.loads((result / 'properties-sorter-proof.json').read_text())
        self.assertEqual(13, len(proof['outputs']))
        self.assertEqual(tree, proof['inputGreenTree'])
        self.assertEqual(tree, json.loads((control / 'green-manifest.json').read_text())['tree'])
        p.verify_files(source, rows, generated=True)

    def test_unrelated_resource_mutation_is_refused(self):
        source, control, result, plan, tree, execute = self.fixture()
        def changed(*args, **kwargs):
            code = execute(*args, **kwargs)
            (source / g.LOCALES[0]).write_bytes((source / g.LOCALES[0]).read_bytes().replace(b'other=preserved', b'other=lost'))
            return code
        with self.assertRaisesRegex(ValueError, 'SORTER_CHANGED_UNRELATED_RESOURCE_BYTES'):
            g.generate(source, control, result, plan, Path('java.exe'), changed, tree)

    def test_wrong_reviewed_value_is_refused_even_with_correct_key_count(self):
        source, control, result, plan, tree, execute = self.fixture()
        def changed(*args, **kwargs):
            code = execute(*args, **kwargs)
            (source / g.LOCALES[0]).write_bytes((source / g.LOCALES[0]).read_bytes().replace(b'Reviewed', b'Wrong'))
            return code
        with self.assertRaisesRegex(ValueError, 'GENERATED_TRANSLATION_MISMATCH'):
            g.generate(source, control, result, plan, Path('java.exe'), changed, tree)

    def test_changed_generator_is_refused_before_any_execution(self):
        source, control, result, plan, tree, execute = self.fixture()
        red = json.loads((control / 'source-manifest.json').read_text())
        altered = next(row for row in red['inventory'] if row['path'] == g.GENERATOR)
        altered['git_blob'] = p.blob(b'class Different {}\n')
        next(row for row in red['source_files'] if row['path'] == g.GENERATOR).update(
            git_blob=altered['git_blob'], bytes=len(b'class Different {}\n'), sha256=p.digest(b'class Different {}\n'))
        red['tree'] = p.merkle(red['inventory'])[0]
        (control / 'source-manifest.json').write_text(json.dumps(red))
        calls = []
        with self.assertRaisesRegex(ValueError, 'GENERATOR_CHANGED_SINCE_COMPILE'):
            g.generate(source, control, result, plan, Path('java.exe'), lambda *a, **k: calls.append(1), tree)
        self.assertEqual([], calls)


if __name__ == '__main__':
    unittest.main()
