"""Closed PropertiesSorter step with explicit input and derived source identities."""
import base64
import json
from pathlib import Path
import re
import private_unit_ci as p

BASE = 'SpringAppBase/src/main/resources/messages.properties'
GENERATOR = 'SpringAppBase/src/main/java/PropertiesSorter.java'
LOCALES = tuple('SpringAppBase/src/main/resources/messages_' + language + '.properties'
                for language in ('bg', 'cz', 'de', 'en', 'es', 'fr', 'it', 'ja', 'pl', 'ro', 'ru', 'ua', 'zh'))


def without_keys(raw, keys):
    pattern = re.compile(rb'^(?:' + b'|'.join(re.escape(key.encode('ascii')) for key in keys) + rb')[ \t]*[=:]')
    return b''.join(line for line in raw.splitlines(keepends=True) if not pattern.match(line))


def property_value(raw, key):
    matches = re.findall(rb'^' + re.escape(key.encode('ascii')) + rb'[ \t]*[=:][ \t]*([^\r\n]*)', raw, re.M)
    p.need(len(matches) == 1, 'GENERATED_KEY_MISSING_OR_DUPLICATE')
    text = matches[0].decode('utf8')
    # The selected strings are single-line Java properties. Decode its documented
    # escapes for comparison to the reviewed JSON, without writing a replacement.
    def escaped(match):
        return chr(int(match[1], 16)) if match[1] else {'n': '\n', 'r': '\r', 't': '\t', 'f': '\f'}.get(match[2], match[2])
    return re.sub(r'\\u([0-9A-Fa-f]{4})|\\(.)', escaped, text)


def generate(source, control, result, plan, java, execute, input_tree):
    green = p.load_json(control / 'green-manifest.json')
    rows = p.manifest(green, input_tree)
    request = plan.get('sorter')
    if request is None:
        return rows, input_tree
    red = p.load_json(control / 'source-manifest.json')
    red_rows = p.manifest(red, red['tree'])
    # The baseline compile supplies the real unchanged generator, not a handwritten
    # substitute or stale unrelated binary. Its classpath is freshly built in this run.
    p.need(GENERATOR in rows and GENERATOR in red_rows
           and rows[GENERATOR]['git_blob'] == red_rows[GENERATOR]['git_blob'], 'GENERATOR_CHANGED_SINCE_COMPILE')
    p.need(all(name in rows for name in (BASE, *LOCALES, request['translations'])), 'SORTER_SOURCE_CLOSURE')
    p.verify_files(source, rows, generated=True)
    original = {name: (source / name).read_bytes() for name in (BASE, *LOCALES, request['translations'])}
    reviewed = json.loads(original[request['translations']].decode('utf8'))
    jar = source / 'SpringAppFrontend/target/SpringAppFrontend-1.0-exec.jar'
    p.ordinary(jar)
    p.need(jar.is_file(), 'COMPILED_GENERATOR_CLASSPATH_MISSING')
    command = [str(java), '-Xmx128m', '-Dloader.main=PropertiesSorter', '-cp', str(jar),
               'org.springframework.boot.loader.PropertiesLauncher', '--keys=' + ','.join(request['keys']),
               '--translations-file=' + str(source / request['translations'])]
    code = execute(command, source, result / 'properties-sorter.log', timeout=120)
    p.need(code == 0, 'PROPERTIES_SORTER_FAILED')
    p.need((source / BASE).read_bytes() == original[BASE]
           and (source / request['translations']).read_bytes() == original[request['translations']],
           'SORTER_CHANGED_BASE_OR_REVIEWED_INPUT')
    updated = {}
    destination = result / 'generated-locales'
    destination.mkdir()
    for name in LOCALES:
        raw = (source / name).read_bytes()
        p.need(without_keys(raw, request['keys']) == without_keys(original[name], request['keys']),
               'SORTER_CHANGED_UNRELATED_RESOURCE_BYTES')
        for key in request['keys']:
            language = Path(name).stem.removeprefix('messages_')
            expected = property_value(original[BASE], key) if language == 'pl' else reviewed.get(language, {}).get(key)
            p.need(isinstance(expected, str) and property_value(raw, key) == expected, 'GENERATED_TRANSLATION_MISMATCH')
        row = dict(rows[name], bytes=len(raw), sha256=p.digest(raw), git_blob=p.blob(raw))
        updated[name] = row
        artifact = dict(row, contentBase64=base64.b64encode(raw).decode('ascii'))
        (destination / (Path(name).name + '.json')).write_text(json.dumps(artifact), encoding='utf8')
    derived = dict(green)
    derived['inventory'] = [dict(row, git_blob=updated[row['path']]['git_blob'])
                            if row['path'] in updated else dict(row) for row in green['inventory']]
    derived['source_files'] = [updated.get(row['path'], dict(row)) for row in green['source_files']]
    derived['tree'] = p.merkle(derived['inventory'])[0]
    final_rows = p.manifest(derived, derived['tree'])
    p.verify_files(source, final_rows, generated=True)
    (result / 'derived-green-manifest.json').write_text(json.dumps(derived), encoding='utf8')
    proof = {'inputGreenTree': input_tree, 'derivedSourceTree': derived['tree'],
             'generatorSourceBlob': rows[GENERATOR]['git_blob'], 'baselineClasspathSha256': p.digest(jar.read_bytes()),
             'reviewedTranslationsSha256': p.digest(original[request['translations']]),
             'keys': request['keys'], 'onlyAllowedLocalesChanged': True, 'outputs': list(updated.values()),
             'sorterExitCode': code, 'phase': 'before-green-compile'}
    (result / 'properties-sorter-proof.json').write_text(json.dumps(proof, indent=2), encoding='utf8')
    return final_rows, derived['tree']
