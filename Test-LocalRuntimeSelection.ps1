$ErrorActionPreference = 'Stop'
$source = if (Test-Path -LiteralPath (Join-Path $PSScriptRoot '..\ValidateLocalInstall.ps1')) { Join-Path $PSScriptRoot '..' } else { $PSScriptRoot }
$parseErrors = $null
$tree = [Management.Automation.Language.Parser]::ParseFile((Join-Path $source 'ValidateLocalInstall.ps1'), [ref]$null, [ref]$parseErrors)
if ($parseErrors.Count) { throw 'Validator syntax is invalid' }
$resolver = $tree.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Resolve-LocalRuntime' }, $true)
if (-not $resolver) { throw 'Runtime resolver unavailable' }
Invoke-Expression $resolver.Extent.Text
# These fixtures represent two already-qualified candidates. Native custody is tested separately.
function Assert-RuntimeAncestors([string]$Path) { if ($script:refused -and $Path -eq $script:refused) { throw 'Fixture custody refusal' } }
function Assert-Custody([string]$Path, [bool]$Private) { }
function Assert-LocalMarker([string]$Path) { }
function Assert-Refused([scriptblock]$Action) {
    $failed = $false
    try { & $Action | Out-Null } catch { $failed = $true }
    if (-not $failed) { throw 'Ambiguous recovery binding was accepted' }
}
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('leadya-runtime-selection-' + [Guid]::NewGuid().ToString('N'))
try {
    $old = Join-Path $fixture 'old'
    $current = Join-Path $fixture 'current'
    [IO.Directory]::CreateDirectory((Join-Path $old 'bot_files')) | Out-Null
    [IO.Directory]::CreateDirectory($current) | Out-Null
    [IO.File]::WriteAllText((Join-Path $old 'bot_files\bot.properties'), '[TEST] retained token')
    if ((Resolve-LocalRuntime @($old, $current)) -cne $old) { throw 'Existing login lost' }
    $receipt = "LOCAL_RECOVERY_V1`n$old`n" + ('a' * 64) + "`n"
    [IO.File]::WriteAllText((Join-Path $current 'leadya-profile-recovered.txt'), $receipt)
    if ((Resolve-LocalRuntime @($old, $current)) -cne $current) { throw 'Logout resurrected old login after ancestors became qualified again' }
    $script:refused = $current
    Assert-Refused { Resolve-LocalRuntime @($old, $current) }
    $script:refused = $null
    [IO.File]::WriteAllText((Join-Path $old 'leadya-profile-recovered.txt'), "LOCAL_RECOVERY_V1`n$current`n" + ('b' * 64) + "`n")
    Assert-Refused { Resolve-LocalRuntime @($old, $current) }
    [IO.File]::Delete((Join-Path $old 'leadya-profile-recovered.txt'))
    [IO.File]::Move((Join-Path $current 'leadya-profile-recovered.txt'), (Join-Path $current 'leadya-profile-recovery-pending.txt'))
    if ((Resolve-LocalRuntime @($old, $current)) -cne $current) { throw 'Interrupted recovery binding lost' }
    [IO.File]::WriteAllText((Join-Path $current 'leadya-profile-recovery-pending.txt'), 'broken')
    Assert-Refused { Resolve-LocalRuntime @($old, $current) }
    Write-Output 'PASS: retained login, permanent binding after logout/reinstall, pending, conflict, custody refusal'
} finally {
    $resolved = [IO.Path]::GetFullPath($fixture)
    if ([IO.Path]::GetDirectoryName($resolved) -ieq [IO.Path]::GetTempPath().TrimEnd('\') -and
        [IO.Path]::GetFileName($resolved) -match '^leadya-runtime-selection-[a-f0-9]{32}$') {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
