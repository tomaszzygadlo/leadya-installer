$ErrorActionPreference = 'Stop'
$env:PSModulePath = Join-Path $PSHOME 'Modules'
$source = if (Test-Path -LiteralPath (Join-Path $PSScriptRoot '..\ValidateLocalInstall.ps1')) { Join-Path $PSScriptRoot '..' } else { $PSScriptRoot }
$parseErrors = $null
$tree = [Management.Automation.Language.Parser]::ParseFile((Join-Path $source 'ValidateLocalInstall.ps1'), [ref]$null, [ref]$parseErrors)
if ($parseErrors.Count) { throw 'Validator syntax is invalid' }
$resolver = $tree.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Resolve-LocalRuntime' }, $true)
if (-not $resolver) { throw 'Runtime resolver unavailable' }
Invoke-Expression $resolver.Extent.Text
# These fixtures represent two already-qualified candidates. Native custody is tested separately.
function Assert-RuntimeAncestors([string]$Path) {
    if ($script:refusedCode) { throw $script:refusedCode }
    if ($script:refused -and $Path -eq $script:refused) { throw 'Fixture custody refusal' }
}
function Assert-Custody([string]$Path, [bool]$Private) { }
function Assert-LocalMarker([string]$Path) {
    if ($script:badMarker -and $Path -eq $script:badMarker) { throw 'LOCAL_MARKER_MISMATCH' }
    # The real read of the marker, so that a real held handle fails as it would in the validator.
    $marker = Join-Path $Path 'leadya-local-install.txt'
    if ([IO.File]::Exists($marker)) { [void][IO.File]::ReadAllLines($marker) }
}
function Assert-Refused([scriptblock]$Action) {
    $failed = $false
    try { & $Action | Out-Null } catch { $failed = $true }
    if (-not $failed) { throw 'Ambiguous recovery binding was accepted' }
}
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('leadya-runtime-selection-' + [Guid]::NewGuid().ToString('N'))
try {
    $old = Join-Path $fixture 'old'
    $current = Join-Path $fixture 'current'
    $preferred = Join-Path $fixture 'preferred'
    $bound = Join-Path $fixture 'bound'
    [IO.Directory]::CreateDirectory($preferred) | Out-Null
    [IO.Directory]::CreateDirectory($bound) | Out-Null
    if ((Resolve-LocalRuntime @($preferred, $bound)) -cne $preferred) { throw 'Fresh selection order changed' }
    [IO.File]::WriteAllText((Join-Path $bound 'leadya-local-install.txt'), '[TEST] bound marker')
    if ((Resolve-LocalRuntime @($preferred, $bound)) -cne $bound) { throw 'Reinstall moved a bound home after another candidate qualified' }
    $script:refusedCode = 'LOCAL_ANCESTOR_WRITABLE'
    $refusal = $null
    try { Resolve-LocalRuntime @($preferred, $bound) | Out-Null } catch { $refusal = [string]$_.Exception.Message }
    if ($refusal -cne 'LOCAL_NO_PRIVATE_PROFILE_ANCESTOR_WRITABLE') { throw "Support code lost the refusal: $refusal" }
    $script:refusedCode = 'not a code C:\Users\private'
    $refusal = $null
    try { Resolve-LocalRuntime @($preferred, $bound) | Out-Null } catch { $refusal = [string]$_.Exception.Message }
    if ($refusal -cne 'LOCAL_NO_PRIVATE_PROFILE') { throw "Unfiltered refusal text reached the support code: $refusal" }
    $script:refusedCode = $null
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
    # Data with a marker of another place can never be prepared, so a valid profile in the other location goes first.
    $first = Join-Path $fixture 'first'
    $second = Join-Path $fixture 'second'
    [IO.Directory]::CreateDirectory((Join-Path $first 'bot_files')) | Out-Null
    [IO.File]::WriteAllText((Join-Path $first 'bot_files\bot.properties'), '[TEST] data')
    [IO.File]::WriteAllText((Join-Path $first 'leadya-local-install.txt'), '[TEST] marker of another place')
    [IO.Directory]::CreateDirectory($second) | Out-Null
    [IO.File]::WriteAllText((Join-Path $second 'leadya-local-install.txt'), '[TEST] valid marker')
    $script:badMarker = $first
    if ((Resolve-LocalRuntime @($first, $second)) -cne $second) { throw 'A populated folder with a broken marker went before a valid profile' }
    [IO.Directory]::CreateDirectory((Join-Path $second 'bot_files')) | Out-Null
    [IO.File]::WriteAllText((Join-Path $second 'bot_files\bot.properties'), '[TEST] data')
    if ((Resolve-LocalRuntime @($first, $second)) -cne $second) { throw 'A valid populated profile lost to a broken one' }
    $script:badMarker = $null
    if ((Resolve-LocalRuntime @($first, $second)) -cne $first) { throw 'Two valid populated profiles must keep their order' }
    # A passing read error is no broken marker: the profile in use must not move to a spare location with a marker.
    $used = Join-Path $fixture 'used'
    $spare = Join-Path $fixture 'spare'
    [IO.Directory]::CreateDirectory((Join-Path $used 'bot_files')) | Out-Null
    [IO.File]::WriteAllText((Join-Path $used 'bot_files\bot.properties'), '[TEST] data')
    [IO.File]::WriteAllText((Join-Path $used 'leadya-local-install.txt'), '[TEST] valid marker')
    [IO.Directory]::CreateDirectory($spare) | Out-Null
    [IO.File]::WriteAllText((Join-Path $spare 'leadya-local-install.txt'), '[TEST] valid marker')
    if ((Resolve-LocalRuntime @($used, $spare)) -cne $used) { throw 'The profile in use must be chosen' }
    # A held marker is unknown, not broken: the profile in use stays chosen and the read error surfaces only at its use.
    $held = [IO.File]::Open((Join-Path $used 'leadya-local-install.txt'), [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
    try {
        $chosen = Resolve-LocalRuntime @($used, $spare)
        if ($chosen -cne $used) { throw "A held marker moved the profile in use: $chosen" }
        $surfaced = $false
        try { Assert-LocalMarker $chosen } catch { $surfaced = -not ([string]$_.Exception.Message -cmatch '^LOCAL_[A-Z_]{1,40}$') }
        if (-not $surfaced) { throw 'The read error must surface when the chosen profile is used' }
    } finally { $held.Dispose() }
    if ((Resolve-LocalRuntime @($used, $spare)) -cne $used) { throw 'Once the handle is gone the profile in use is chosen again' }
    # A held marker on the unused location must not stop the profile in use.
    $held = [IO.File]::Open((Join-Path $spare 'leadya-local-install.txt'), [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
    try {
        $chosen = Resolve-LocalRuntime @($used, $spare)
        if ($chosen -cne $used) { throw "A held spare marker changed the choice: $chosen" }
        Assert-LocalMarker $chosen
        if ((Resolve-LocalRuntime @($spare, $used)) -cne $used) { throw 'A held marker without data went before the profile in use' }
    } finally { $held.Dispose() }
    Write-Output 'PASS: retained login, bound home kept on reinstall, support refusal code, permanent binding after logout/reinstall, pending, conflict, custody refusal, valid marker before broken data, held marker keeps the profile in use, held spare marker'
} finally {
    $resolved = [IO.Path]::GetFullPath($fixture)
    if ([IO.Path]::GetDirectoryName($resolved) -ieq [IO.Path]::GetTempPath().TrimEnd('\') -and
        [IO.Path]::GetFileName($resolved) -match '^leadya-runtime-selection-[a-f0-9]{32}$') {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
