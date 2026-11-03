"""Run only the workflow's readiness function with synthetic Defender command boundaries."""
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import unittest

ROOT = Path(__file__).resolve().parent
POWERSHELL = shutil.which('powershell.exe') or shutil.which('pwsh')


def run_blocks(path):
    lines = path.read_text(encoding='utf-8-sig').splitlines()
    blocks = []
    for index, line in enumerate(lines):
        match = re.fullmatch(r'( *)run: \|[-+]?', line)
        if not match:
            inline = re.fullmatch(r' *run: (.+)', line)
            if inline:
                blocks.append(inline.group(1))
            continue
        indent = len(match.group(1))
        body = []
        for following in lines[index + 1:]:
            if following.strip() and len(following) - len(following.lstrip(' ')) <= indent:
                break
            body.append(following[indent + 2:] if following.strip() else '')
        blocks.append('\n'.join(body))
    return blocks


def powershell(script):
    encoded = base64.b64encode(script.encode('utf-16-le')).decode('ascii')
    command = [POWERSHELL, '-NoProfile', '-NonInteractive']
    if os.name == 'nt':
        command += ['-WindowStyle', 'Hidden']
    result = subprocess.run(
        command + ['-ExecutionPolicy', 'Bypass', '-EncodedCommand', encoded],
        capture_output=True, text=True, timeout=45,
        creationflags=subprocess.CREATE_NO_WINDOW if os.name == 'nt' else 0)
    if result.returncode:
        raise AssertionError(result.stdout + result.stderr)
    return result.stdout


@unittest.skipUnless(POWERSHELL, 'PowerShell required for actual workflow AST tests')
class AssessmentReadinessTests(unittest.TestCase):
    def test_repository_policy_is_the_pinned_workflow_helper(self):
        preparation = run_blocks(ROOT / '.github/workflows/assess-windows-packages.yml')[0]
        pins = re.findall(r" -ne '([0-9a-f]{64})'", preparation)
        self.assertEqual(pins, [hashlib.sha256((ROOT / 'InstallerReleaseSecurity.ps1').read_bytes()).hexdigest()])

    def scenario(self, mode):
        preparation = run_blocks(ROOT / '.github/workflows/assess-windows-packages.yml')[0]
        source = base64.b64encode(preparation.encode('utf-8')).decode('ascii')
        helper = str(ROOT / 'InstallerReleaseSecurity.ps1').replace("'", "''")
        script = r'''
$ErrorActionPreference = 'Stop'
. '__HELPER__'
$preparation = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__SOURCE__'))
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseInput($preparation,[ref]$tokens,[ref]$errors)
if ($errors.Count) { throw 'Invalid preparation syntax' }
$definition=$ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Wait-QualifiedDefenderDefinitions'},$true)
if ($definition.Count -eq 1) { Invoke-Expression $definition[0].Extent.Text }
else {
  # Baseline replay uses only the actual old readiness commands, never the preparation/mutations.
  $commands=$ast.FindAll({param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -in @('Update-MpSignature','Assert-InstallerScanPolicy','Assert-InstallerLocalThreatPolicy')},$true)
  if ($commands.Count -ne 3) { throw 'No unambiguous readiness implementation' }
  Invoke-Expression ('function Wait-QualifiedDefenderDefinitions { param($Evidence) ' + (($commands | ForEach-Object {$_.Extent.Text}) -join "`n") + ' }')
}
$script:updates=0; $script:checks=0; $script:sleeps=0; $script:localChecks=0
$script:mode='__MODE__'
function Get-MpComputerStatus {
  $script:checks++
  if ($script:mode -eq 'unknown') { return $null }
  $fresh=$script:mode -notin @('stale','rpc-fresh') -or ($script:mode -eq 'rpc-fresh' -and $script:updates -gt 0)
  [pscustomobject]@{AntivirusEnabled=($script:mode -ne 'disabled'); RealTimeProtectionEnabled=$true;
    AntivirusSignatureVersion='1.2.3.4'; AMEngineVersion='1.2.3.4';
    AntivirusSignatureLastUpdated=([DateTime]::UtcNow.AddHours($(if($fresh){-1}else{-25})))}
}
function Get-MpPreference {
  [pscustomobject]@{ExclusionPath=@($(if($script:mode -eq 'excluded'){'C:\user-policy'}));
    ExclusionProcess=@(); ExclusionExtension=@(); ThreatIDDefaultAction_Ids=@(); DisableArchiveScanning=$false}
}
function Assert-InstallerLocalThreatPolicy {
  $script:localChecks++
  if ($script:mode -eq 'local-override') { throw 'Synthetic local threat override' }
}
function Update-MpSignature {
  param($UpdateSource,$ErrorAction)
  $script:updates++
  if ($UpdateSource -and $UpdateSource -ne 'MMPC') { throw 'Unexpected update source' }
  throw [Runtime.InteropServices.COMException]::new('Synthetic RPC failure; do not log this message',-2147023170)
}
function Start-Sleep { param($Seconds) if($Seconds -ne 10){throw 'Unexpected wait'}; $script:sleeps++ }
function Set-MpPreference { throw 'Test must never change Defender policy' }
function Remove-MpPreference { throw 'Test must never remove Defender exclusions' }
$evidence=[ordered]@{}; $qualified=$false
try { Wait-QualifiedDefenderDefinitions -Evidence $evidence; $qualified=$true } catch { }
[ordered]@{qualified=$qualified; updates=$script:updates; checks=$script:checks;
  sleeps=$script:sleeps; local_checks=$script:localChecks; evidence=$evidence} | ConvertTo-Json -Depth 8 -Compress
'''.replace('__HELPER__', helper).replace('__SOURCE__', source).replace('__MODE__', mode)
        return json.loads(powershell(script).strip())

    def test_already_qualified_never_updates(self):
        result = self.scenario('fresh')
        self.assertTrue(result['qualified'], result)
        self.assertEqual((result['updates'], result['checks'], result['sleeps']), (0, 1, 0))
        self.assertEqual(result['local_checks'], 1)
        self.assertTrue(result['evidence']['qualified'])

    def test_rpc_failure_can_only_pass_with_actual_fresh_policy(self):
        result = self.scenario('rpc-fresh')
        self.assertTrue(result['qualified'], result)
        self.assertEqual((result['updates'], result['checks'], result['sleeps']), (1, 2, 1))
        self.assertEqual(result['evidence']['update_failures'], 1)
        self.assertEqual(result['evidence']['update_attempts'], 1)
        self.assertEqual(result['local_checks'], 1)
        self.assertTrue(result['evidence']['qualified'])
        self.assertNotIn('Synthetic RPC failure', json.dumps(result['evidence']))

    def test_stale_excluded_disabled_or_unknown_policy_is_bounded_and_refused(self):
        for mode in ('stale', 'excluded', 'disabled', 'unknown', 'local-override'):
            with self.subTest(mode=mode):
                result = self.scenario(mode)
                self.assertFalse(result['qualified'], result)
                self.assertEqual((result['updates'], result['checks'], result['sleeps']), (2, 3, 2))
                self.assertEqual(result['evidence']['update_failures'], 2)
                self.assertFalse(result['evidence']['qualified'])

    def test_all_workflow_powershell_run_blocks_parse(self):
        for workflow in sorted((ROOT / '.github/workflows').glob('*.yml')):
            for index, block in enumerate(run_blocks(workflow)):
                with self.subTest(workflow=workflow.name, block=index):
                    source = base64.b64encode(block.encode('utf-8')).decode('ascii')
                    powershell("$tokens=$null;$errors=$null;[void][Management.Automation.Language.Parser]::ParseInput("
                               "[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('" + source + "')),"
                               "[ref]$tokens,[ref]$errors);if($errors.Count){throw ($errors.Message -join '; ')}")


if __name__ == '__main__':
    unittest.main()
