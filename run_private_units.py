"""Execute the authenticated closed unit specification inside an owned Windows job."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time
import re
import xml.etree.ElementTree as ET
import private_unit_ci as protocol


def update_status(**changes):
    root = os.environ.get('DEVUNIT_RESULT_ROOT')
    if root is None:
        return
    path = Path(root) / 'unit-status.json'
    previous = json.loads(path.read_text()) if path.is_file() else {}
    previous.update(changes)
    path.write_text(json.dumps(previous, indent=2), encoding='utf-8')


def closed_error_code(error):
    text = str(error)
    return text if type(error) is ValueError and re.fullmatch(r'[A-Z][A-Z0-9_-]{1,127}', text) else type(error).__name__


def preserved_evaluation(reports, destination, evaluator, *arguments, logging_configuration=None):
    # Evidence must survive a guard refusal (wrong class, skip or malformed report).
    if reports.is_dir():
        protocol.ordinary(reports)
        files = sorted([*reports.glob('TEST-*.xml'), *reports.glob('*.txt')])
        protocol.need(len(files) <= 1000, 'REPORT_PRESERVATION_COUNT')
        destination.mkdir()
        total = 0
        for path in files:
            protocol.ordinary(path)
            size = path.stat().st_size
            total += size
            protocol.need(size <= 8 * 1024 * 1024 and total <= 64 * 1024 * 1024, 'REPORT_PRESERVATION_LIMIT')
            with path.open('rb') as incoming, (destination / path.name).open('xb') as outgoing:
                raw = incoming.read(8 * 1024 * 1024 + 1)
                protocol.need(len(raw) == size, 'REPORT_CHANGED_DURING_PRESERVATION')
                outgoing.write(raw)
    if logging_configuration is not None:
        # Surefire 2.22.2 forwards Maven user properties into the fork; verify actual XML evidence.
        protocol.test_cases(destination)
        for path in destination.glob('TEST-*.xml'):
            root = ET.fromstring(path.read_bytes())
            values = {item.get('name'): item.get('value') for item in root.findall('properties/property')}
            protocol.need(values.get('logback.configurationFile') == str(logging_configuration),
                          'LOGBACK_PROPERTY_NOT_FORWARDED')
    return evaluator(reports, *arguments)


def cmd_line(command):
    protocol.need(command and all(not any(c in item for c in '&|<>^%!"\r\n') for item in command), 'CMD_META_REFUSED')
    executable = os.environ['COMSPEC']
    protocol.need(not any(c in executable for c in '"\r\n'), 'COMSPEC_PATH_REFUSED')
    # cmd.exe parses a raw command line, not the CRT quoting used by list2cmdline.
    body = '"' + ' '.join('"' + item + '"' for item in command) + '"'
    return '"' + executable + '" /d /s /c ' + body


def write_logback_configuration(path):
    # Owned test-process configuration, outside the authenticated application tree.
    # The appender filter also retains WARN/ERROR when a library explicitly enables DEBUG.
    raw = '''<configuration>
  <appender name="UNIT_CONSOLE" class="ch.qos.logback.core.ConsoleAppender">
    <filter class="ch.qos.logback.classic.filter.ThresholdFilter"><level>WARN</level></filter>
    <encoder><charset>UTF-8</charset><pattern>%d{HH:mm:ss.SSS} %-5level %logger{48} - %msg%n%ex</pattern></encoder>
  </appender>
  <root level="WARN"><appender-ref ref="UNIT_CONSOLE"/></root>
</configuration>
'''
    with path.open('x', encoding='utf-8') as output:
        output.write(raw)
    return path.resolve()


def maven_command(maven, repository, arguments, logging_configuration=None):
    # Unit evidence installs dependency JARs into M2, never the POM's deployment-copy Ant targets.
    logging = [] if logging_configuration is None else [
        '-Dlogback.configurationFile=' + str(logging_configuration),
        '-Dlogging.config=' + str(logging_configuration)]
    return [maven, '-B', '-ntp', '-Dstyle.color=never', '-Dmaven.antrun.skip=true',
            '-Dmaven.repo.local=' + str(repository), *logging, *arguments]


def execute(arguments, cwd, log, timeout=1200):
    # This process and all descendants already belong atomically to the outer native job.
    with log.open('xb') as output:
        child = subprocess.Popen(arguments, cwd=cwd, stdout=output, stderr=subprocess.STDOUT,
                                 creationflags=subprocess.CREATE_NO_WINDOW)
        deadline = time.monotonic() + timeout
        while child.poll() is None:
            if time.monotonic() > deadline or log.stat().st_size > 32 * 1024 * 1024:
                # Exit without releasing admission: the outer job terminates and verifies all children.
                update_status(status='FAILED', error_code='OWNED_COMMAND_TIMEOUT_OR_LOG_LIMIT')
                os._exit(90)
            time.sleep(.1)
        protocol.need(log.stat().st_size <= 32 * 1024 * 1024, 'LOG_LIMIT')
        return child.returncode


def main():
    update_status(status='RUNNING', stage='prepare')
    protocol.need(os.name == 'nt', 'WINDOWS_ONLY')
    source = Path(os.environ['DEVUNIT_SOURCE_ROOT']).resolve()
    result = Path(os.environ['DEVUNIT_RESULT_ROOT']).resolve()
    control = source.parent / 'control'
    plan = protocol.spec(protocol.load_json(control / 'unit-spec.json'))
    maven = shutil.which('mvn.cmd')
    node = shutil.which('node.exe')
    npm = shutil.which('npm.cmd')
    protocol.need(maven and node and npm, 'BUILD_TOOL_UNAVAILABLE')
    java = Path(os.environ['JAVA_HOME']) / 'bin' / 'java.exe'
    protocol.need(java.is_file(), 'JAVA_UNAVAILABLE')
    code = execute([str(java), '-version'], source, result / 'java-version.log', 30)
    java_log = (result / 'java-version.log').read_text(errors='replace')
    protocol.need(code == 0 and 'version "17.' in java_log, 'JAVA_17_REQUIRED')
    evidence = {'status': 'RUNNING', 'red_tree': os.environ['DEVUNIT_RED_TREE'],
                'prospective_green_tree': os.environ['DEVUNIT_GREEN_TREE'],
                'source_zip_sha256': os.environ['DEVUNIT_ZIP_SHA256'], 'green': [], 'node': []}
    (result / 'unit-status.json').write_text(json.dumps(evidence, indent=2))
    protocol.need(not (result == source or source in result.parents), 'LOGGING_CONFIG_INSIDE_SOURCE')
    logging_configuration = write_logback_configuration(result / 'unit-logback.xml')
    counter = 0

    def mvn(args, label, expect_success=True):
        nonlocal counter
        counter += 1
        update_status(stage=label)
        # cmd's syntax is closed: every component is validated and no shell expansion is accepted.
        command = maven_command(maven, source.parent / 'm2', args, logging_configuration)
        log = result / f'{counter:02d}-{label}.log'
        code = execute(cmd_line(command), source, log)
        if expect_success:
            protocol.need(code == 0, 'MAVEN_' + label.upper() + '_FAILED')
        return code

    for vendor in protocol.VENDORS:
        mvn(['-f', vendor + '/pom.xml', 'clean', 'install', '-DskipTests'], 'vendor-' + vendor)
    modules = ','.join(plan['compile_modules'])
    compile_args = ['-pl', modules, '-am', 'clean', 'install', '-DskipTests']
    mvn(compile_args, 'red-compile')
    red = plan['red']
    reports = source / red['module'] / 'target' / 'surefire-reports'
    protocol.need(not reports.exists(), 'STALE_RED_REPORTS')
    code = mvn(['-f', red['module'] + '/pom.xml', '-Dtest=' + red['class'] + '#' + red['method'],
                '-Dsurefire.rerunFailingTestsCount=0', '-DfailIfNoTests=true', 'test'], 'red-test', False)
    update_status(stage='red-evidence')
    evidence['red'] = preserved_evaluation(reports, result / 'red-reports', protocol.evaluate_red, plan, code,
                                         logging_configuration=logging_configuration)
    update_status(red=evidence['red'])
    # No patch runs unless the exact regression reached the expected failing assertion.
    update_status(stage='apply-green')
    protocol.apply_green(source, control, os.environ['DEVUNIT_RED_TREE'], os.environ['DEVUNIT_GREEN_TREE'])
    mvn(compile_args, 'green-compile')
    for suite in plan['green']:
        reports = source / suite['module'] / 'target' / 'surefire-reports'
        protocol.need(not reports.exists(), 'STALE_GREEN_REPORTS')
        code = mvn(['-f', suite['module'] + '/pom.xml', '-Dtest=' + ','.join(suite['tests']),
                    '-Dsurefire.rerunFailingTestsCount=0', '-DfailIfNoTests=true', 'test'], 'green-' + suite['module'], False)
        update_status(stage='green-evidence-' + suite['module'])
        summary = preserved_evaluation(reports, result / ('green-' + suite['module'] + '-reports'), protocol.evaluate_green,
                                      suite['tests'], code, red if suite['module'] == red['module'] else None,
                                      logging_configuration=logging_configuration)
        evidence['green'].append({'module': suite['module'], **summary})
        update_status(green=evidence['green'])
    node_root = source / 'SpringAppFrontend/src/test/js'
    update_status(stage='npm-ci')
    protocol.need((node_root / 'package-lock.json').is_file(), 'NODE_LOCK_UNAVAILABLE')
    code = execute(cmd_line([npm, 'ci', '--ignore-scripts', '--no-audit', '--no-fund']), node_root, result / 'npm-ci.log')
    protocol.need(code == 0, 'NPM_CI_FAILED')
    for index, name in enumerate(plan['node']):
        update_status(stage='node-' + str(index))
        log = result / f'node-{index}.log'
        code = execute([node, '--test', '--test-concurrency=1', name], source, log)
        evidence['node'].append({'path': name, **protocol.evaluate_node(log, code)})
        update_status(node=evidence['node'])
    update_status(stage='final-source-verification')
    protocol.verify_files(source, protocol.manifest(protocol.load_json(control / 'green-manifest.json'), os.environ['DEVUNIT_GREEN_TREE']), generated=True)
    evidence['status'] = 'CAUSAL_RED_GREEN_PASS'
    evidence['stage'] = 'complete'
    (result / 'unit-status.json').write_text(json.dumps(evidence, indent=2))


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        # Native transport captures even this fixed diagnostic privately.
        code = closed_error_code(error)
        update_status(status='FAILED', error_code=code)
        raise SystemExit('PRIVATE_UNIT_EXECUTION_FAILED:' + code)
