param([Parameter(Mandatory)][string]$Script,
      [string[]]$ScriptArguments=@(),
      [Parameter(Mandatory)][string]$Log,
      [int]$Seconds=300,
      [string]$CleanupMarker)
$ErrorActionPreference='Stop'
$pythonw=(Get-Command pythonw.exe -ErrorAction Stop).Source
$request=Join-Path $env:RUNNER_TEMP ([Guid]::NewGuid().ToString('N')+'.private-python-request.json')
@{script=[IO.Path]::GetFullPath($Script);arguments=$ScriptArguments;log=[IO.Path]::GetFullPath($Log)} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $request -Encoding utf8
$transportLog=$Log+'.transport.log'
& (Join-Path $PSScriptRoot 'Invoke-PrivateUnitProcess.ps1') -Executable $pythonw -Arguments @((Join-Path $PSScriptRoot 'hidden_python_entry.py'),$request) -WorkingDirectory $PSScriptRoot -Log $transportLog -Seconds $Seconds -CleanupMarker $CleanupMarker
exit $LASTEXITCODE
