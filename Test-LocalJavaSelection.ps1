$ErrorActionPreference = 'Stop'
$env:PSModulePath = Join-Path $PSHOME 'Modules'
$source = if (Test-Path -LiteralPath (Join-Path $PSScriptRoot '..\LaunchLocalLeadYa.ps1')) { Join-Path $PSScriptRoot '..' } else { $PSScriptRoot }
$parseErrors = $null
$tree = [Management.Automation.Language.Parser]::ParseFile((Join-Path $source 'LaunchLocalLeadYa.ps1'), [ref]$null, [ref]$parseErrors)
if ($parseErrors.Count) { throw 'Invalid production launcher syntax' }
$definition = $tree.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Select-LocalJava' }, $true)
if (-not $definition) { throw 'Missing production function: Select-LocalJava' }
$calls = @($tree.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Select-LocalJava' }, $true))
if ($calls.Count -ne 1) { throw 'The launcher must choose its Java through Select-LocalJava' }
Invoke-Expression $definition.Extent.Text
function New-FixtureJava([string]$JavaHome) {
    $bin = [IO.Path]::Combine($JavaHome, 'bin')
    [IO.Directory]::CreateDirectory($bin) | Out-Null
    $java = [IO.Path]::Combine($bin, 'java.exe')
    [IO.File]::WriteAllText($java, '[TEST]')
    return $java
}
$saved = @{ ProgramW6432 = $env:ProgramW6432; ProgramFiles = $env:ProgramFiles }
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('leadya-java-selection-' + [Guid]::NewGuid().ToString('N'))
try {
    $appData = [IO.Path]::Combine($fixture, 'appdata')
    $wide = [IO.Path]::Combine($fixture, 'programs64')
    $narrow = [IO.Path]::Combine($fixture, 'programs86')
    $env:ProgramW6432 = $wide
    $env:ProgramFiles = $narrow
    $perUser = New-FixtureJava ([IO.Path]::Combine($appData, 'LeadYa\Java\jdk-17.0.21+9-jre'))
    if ((Select-LocalJava $appData) -cne $perUser) { throw 'The per-user runtime comes first' }
    $refusal = [IO.Path]::Combine($appData, 'LeadYa\Java\jdk-17.0.21+9-jre.refused')
    [IO.File]::WriteAllText($refusal, '[TEST]')
    if ((Select-LocalJava $appData) -cne $perUser) { throw 'A refused runtime that is the only one is still used' }
    $narrowOld = New-FixtureJava ([IO.Path]::Combine($narrow, 'Java\jdk-17.0.9+9-jre'))
    if ((Select-LocalJava $appData) -cne $narrowOld) { throw 'A refused runtime gives way to any other Java' }
    $wideOld = New-FixtureJava ([IO.Path]::Combine($wide, 'Java\jdk-17.0.9+9-jre'))
    if ((Select-LocalJava $appData) -cne $wideOld) { throw 'The 64-bit program folder comes before the one a 32-bit process sees' }
    $wideNew = New-FixtureJava ([IO.Path]::Combine($wide, 'Java\jdk-17.0.21+9-jre'))
    if ((Select-LocalJava $appData) -cne $wideNew) { throw 'The current shared runtime comes before the previous one' }
    [IO.File]::Delete($refusal)
    if ((Select-LocalJava $appData) -cne $perUser) { throw 'A runtime whose refusal is gone is used again' }
    $env:ProgramW6432 = $null
    $env:ProgramFiles = $null
    if ($null -ne (Select-LocalJava '')) { throw 'Missing folders must leave no Java rather than stop the launcher' }
    Write-Output 'PASS: per-user first, refused per-user skipped and kept as the last resort, ProgramW6432 before ProgramFiles, current before previous, missing variables'
} finally {
    $env:ProgramW6432 = $saved.ProgramW6432
    $env:ProgramFiles = $saved.ProgramFiles
    $resolved = [IO.Path]::GetFullPath($fixture)
    if ([IO.Path]::GetDirectoryName($resolved) -ieq [IO.Path]::GetTempPath().TrimEnd('\') -and
        [IO.Path]::GetFileName($resolved) -match '^leadya-java-selection-[a-f0-9]{32}$' -and (Test-Path -LiteralPath $resolved)) {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
