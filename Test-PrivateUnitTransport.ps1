param([Parameter(Mandatory)][string]$Output)
$ErrorActionPreference='Stop'
$root=Join-Path ([IO.Path]::GetTempPath()) ('private-unit-transport-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
$savedTemp=$env:RUNNER_TEMP
$env:RUNNER_TEMP=$root
$env:DEVUNIT_SOURCE_KEY='synthetic-sentinel'
$env:LEADYA_RESULT_KEY='synthetic-sentinel'
$env:GITHUB_TOKEN='synthetic-sentinel'
$script=Join-Path $root 'fixture.py'
[IO.File]::WriteAllText((Join-Path $root 'synthetic_sibling.py'),'VALUE=73')
@'
import os
import sys
import synthetic_sibling
assert synthetic_sibling.VALUE == 73
assert not any(name in os.environ for name in ('DEVUNIT_SOURCE_KEY', 'LEADYA_RESULT_KEY', 'GITHUB_TOKEN'))
print('bounded synthetic fixture')
raise SystemExit(int(sys.argv[1]))
'@ | Set-Content -LiteralPath $script -Encoding utf8
try{
 foreach($number in @(0,7)){
  & (Join-Path $PSScriptRoot 'Invoke-PrivateUnitPython.ps1') -Script $script -ScriptArguments @([string]$number) -Log (Join-Path $root ('private-'+$number+'.log')) -Seconds 20 -CleanupMarker (Join-Path $root ('stopped-'+$number))
  if($LASTEXITCODE -ne $number -or -not(Test-Path -LiteralPath (Join-Path $root ('stopped-'+$number)))){throw 'Transport exit or cleanup marker lost'}
 }
 [IO.File]::WriteAllText($script,'raise RuntimeError("synthetic-private-exception")')
 & (Join-Path $PSScriptRoot 'Invoke-PrivateUnitPython.ps1') -Script $script -Log (Join-Path $root 'exception.log') -Seconds 20 -CleanupMarker (Join-Path $root 'exception-stopped')
 if($LASTEXITCODE -ne 1 -or (Get-Content -LiteralPath (Join-Path $root 'exception.log') -Raw) -notmatch 'synthetic-private-exception'){throw 'Private exception evidence lost'}
 if(-not(Test-Path -LiteralPath (Join-Path $root 'exception-stopped'))){throw 'Exception child cleanup proof lost'}
 @{status='PASS';checks=@('actual-wrapper-secret-env-absent','pythonw-exit-0-and-7','repeat-native-transport-in-one-shell','verified-cleanup-markers','pinned-script-sibling-import','private-traceback-preserved-before-stream-close')} | ConvertTo-Json | Set-Content -LiteralPath $Output
}finally{
 $env:RUNNER_TEMP=$savedTemp
 Remove-Item Env:DEVUNIT_SOURCE_KEY,Env:LEADYA_RESULT_KEY,Env:GITHUB_TOKEN -ErrorAction SilentlyContinue
 if([IO.Path]::GetFullPath($root).StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()),[StringComparison]::OrdinalIgnoreCase)){Remove-Item -LiteralPath $root -Recurse -Force}
}
