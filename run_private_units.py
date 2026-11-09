"""Execute the authenticated closed unit specification inside an owned Windows job."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time
import private_unit_ci as protocol


def cmd_line(command):
    protocol.need(command and all(not any(c in item for c in '&|<>^%!"\r\n') for item in command), 'CMD_META_REFUSED')
    executable = os.environ['COMSPEC']
    protocol.need(not any(c in executable for c in '"\r\n'), 'COMSPEC_PATH_REFUSED')
    # cmd.exe parses a raw command line, not the CRT quoting used by list2cmdline.
    body = '"' + ' '.join('"' + item + '"' for item in command) + '"'
    return '"' + executable + '" /d /s /c ' + body


def maven_command(maven, repository, arguments):
    # Unit evidence installs dependency JARs into M2, never the POM's deployment-copy Ant targets.
    return [maven, '-B', '-ntp', '-Dstyle.color=never', '-Dmaven.antrun.skip=true',
            '-Dmaven.repo.local=' + str(repository), *arguments]


def execute(arguments, cwd, log, timeout=1200):
    # This process and all descendants already belong atomically to the outer native job.
    with log.open('xb') as output:
        child = subprocess.Popen(arguments, cwd=cwd, stdout=output, stderr=subprocess.STDOUT,
                                 creationflags=subprocess.CREATE_NO_WINDOW)
        deadline = time.monotonic() + timeout
        while child.poll() is None:
            if time.monotonic() > deadline or log.stat().st_size > 32 * 1024 * 1024:
                # Exit without releasing admission: the outer job terminates and verifies all children.
                os._exit(90)
            time.sleep(.1)
        protocol.need(log.stat().st_size <= 32 * 1024 * 1024, 'LOG_LIMIT')
        return child.returncode


def main():
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
    counter = 0

    def mvn(args, label, expect_success=True):
        nonlocal counter
        counter += 1
        # cmd's syntax is closed: every component is validated and no shell expansion is accepted.
        command = maven_command(maven, source.parent / 'm2', args)
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
    evidence['red'] = protocol.evaluate_red(reports, plan, code)
    shutil.copytree(reports, result / 'red-reports')
    # No patch runs unless the exact regression reached the expected failing assertion.
    protocol.apply_green(source, control, os.environ['DEVUNIT_RED_TREE'], os.environ['DEVUNIT_GREEN_TREE'])
    mvn(compile_args, 'green-compile')
    for suite in plan['green']:
        reports = source / suite['module'] / 'target' / 'surefire-reports'
        protocol.need(not reports.exists(), 'STALE_GREEN_REPORTS')
        code = mvn(['-f', suite['module'] + '/pom.xml', '-Dtest=' + ','.join(suite['tests']),
                    '-Dsurefire.rerunFailingTestsCount=0', '-DfailIfNoTests=true', 'test'], 'green-' + suite['module'])
        summary = protocol.evaluate_green(reports, suite['tests'], code, red if suite['module'] == red['module'] else None)
        evidence['green'].append({'module': suite['module'], **summary})
        shutil.copytree(reports, result / ('green-' + suite['module'] + '-reports'))
    node_root = source / 'SpringAppFrontend/src/test/js'
    protocol.need((node_root / 'package-lock.json').is_file(), 'NODE_LOCK_UNAVAILABLE')
    code = execute(cmd_line([npm, 'ci', '--ignore-scripts', '--no-audit', '--no-fund']), node_root, result / 'npm-ci.log')
    protocol.need(code == 0, 'NPM_CI_FAILED')
    for index, name in enumerate(plan['node']):
        log = result / f'node-{index}.log'
        code = execute([node, '--test', '--test-concurrency=1', name], source, log)
        evidence['node'].append({'path': name, **protocol.evaluate_node(log, code)})
    protocol.verify_files(source, protocol.manifest(protocol.load_json(control / 'green-manifest.json'), os.environ['DEVUNIT_GREEN_TREE']), generated=True)
    evidence['status'] = 'CAUSAL_RED_GREEN_PASS'
    (result / 'unit-status.json').write_text(json.dumps(evidence, indent=2))


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        # Native transport captures even this fixed diagnostic privately.
        raise SystemExit('PRIVATE_UNIT_EXECUTION_FAILED:' + type(error).__name__)
