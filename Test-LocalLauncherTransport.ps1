$ErrorActionPreference = 'Stop'
$env:PSModulePath = Join-Path $PSHOME 'Modules'
$source = if (Test-Path -LiteralPath (Join-Path $PSScriptRoot '..\LaunchLocalLeadYa.vbs')) { Join-Path $PSScriptRoot '..' } else { $PSScriptRoot }
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('leadya-launch-transport-' + [Guid]::NewGuid().ToString('N') + ' ! & ż')
try {
    [IO.Directory]::CreateDirectory($fixture) | Out-Null
    Copy-Item -LiteralPath (Join-Path $source 'LaunchLocalLeadYa.vbs') -Destination $fixture
    [IO.File]::WriteAllText((Join-Path $fixture 'LaunchLocalLeadYa.ps1'), 'param([string]$RequestedVersion); [IO.File]::WriteAllText((Join-Path $PSScriptRoot "result.txt"), ("ok:"+$RequestedVersion))')
    foreach ($version in @('', '0.11.38.167')) {
        $arguments = '//B //Nologo "' + (Join-Path $fixture 'LaunchLocalLeadYa.vbs') + '"'
        if ($version) { $arguments += ' ' + $version }
        $process = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\wscript.exe') -ArgumentList $arguments -WindowStyle Hidden -PassThru -Wait
        if ($process.ExitCode -ne 0) { throw 'Windowless script transport failed' }
        $result = Join-Path $fixture 'result.txt'
        $deadline = [DateTime]::UtcNow.AddSeconds(12)
        while (-not [IO.File]::Exists($result) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 100 }
        if (-not [IO.File]::Exists($result) -or [IO.File]::ReadAllText($result) -cne ('ok:' + $version)) { throw 'Launcher lost its literal path or requested version' }
        [IO.File]::Delete($result)
    }
    $parseErrors = $null
    $tree = [Management.Automation.Language.Parser]::ParseFile((Join-Path $source 'LaunchLocalLeadYa.ps1'), [ref]$null, [ref]$parseErrors)
    if ($parseErrors.Count) { throw 'Launcher syntax is invalid' }
    $linksFunction = $tree.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Update-PersonalLaunchLinks' }, $true)
    Invoke-Expression $linksFunction.Extent.Text
    $desktop = Join-Path $fixture 'Desktop.lnk'
    $startup = Join-Path $fixture 'Startup.lnk'
    $menu = Join-Path $fixture 'Menu.lnk'
    $locked = [IO.File]::Open($desktop, 'CreateNew', 'ReadWrite', 'None')
    try {
        if (-not (Update-PersonalLaunchLinks $fixture @($desktop, $startup, $menu) $startup)) { throw 'Blocked desktop prevented autostart' }
        if (-not [IO.File]::Exists($menu)) { throw 'Blocked desktop prevented Start menu refresh' }
    } finally { $locked.Dispose() }
    $locked = [IO.File]::Open($startup, 'Open', 'ReadWrite', 'None')
    try {
        if (Update-PersonalLaunchLinks $fixture @($startup) $startup) { throw 'Blocked startup must preserve legacy registration' }
    } finally { $locked.Dispose() }
    Write-Output 'PASS: real WScript to hidden PowerShell, literal Unicode path, normal and versioned launch'
} finally {
    $resolved = [IO.Path]::GetFullPath($fixture)
    if ([IO.Path]::GetDirectoryName($resolved) -ieq [IO.Path]::GetTempPath().TrimEnd('\') -and
        [IO.Path]::GetFileName($resolved) -match '^leadya-launch-transport-[a-f0-9]{32} ! & ż$') {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
