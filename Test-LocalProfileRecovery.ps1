$ErrorActionPreference = 'Stop'
$env:PSModulePath = Join-Path $PSHOME 'Modules'
$source = if (Test-Path -LiteralPath (Join-Path $PSScriptRoot '..\LocalProfileRecovery.ps1')) { Join-Path $PSScriptRoot '..' } else { $PSScriptRoot }
. (Join-Path $source 'LocalProfileRecovery.ps1')
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('leadya-retained-test-' + [Guid]::NewGuid().ToString('N'))
$origin = 'https://hotfix.turbot.pro'
function Assert-Refused([scriptblock]$Action) {
    $refused = $false
    try { & $Action } catch { $refused = $true }
    if (-not $refused) { throw 'Retained profile was unexpectedly accepted' }
}
try {
    [IO.Directory]::CreateDirectory($fixture) | Out-Null
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $acl.SetOwner([Security.Principal.WindowsIdentity]::GetCurrent().User)
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($sid in @([Security.Principal.WindowsIdentity]::GetCurrent().User.Value, 'S-1-5-18', 'S-1-5-32-544')) {
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($sid), 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow'))
    }
    Set-Acl -LiteralPath $fixture -AclObject $acl
    [IO.Directory]::CreateDirectory((Join-Path $fixture 'bot_files')) | Out-Null
    [IO.Directory]::CreateDirectory((Join-Path $fixture '.leadya-agent-runtime')) | Out-Null
    foreach ($name in @('supervisor.lock', 'engine.lock')) { [IO.File]::WriteAllBytes((Join-Path $fixture ('.leadya-agent-runtime\' + $name)), [byte[]]@()) }
    [IO.File]::WriteAllText((Join-Path $fixture 'leadya-local-install.txt'), "LOCAL`n$fixture`n$origin`n")
    $config = Join-Path $fixture 'bot_files\bot.properties'
    [IO.File]::WriteAllText($config, 'synthetic-retained-data')
    $snapshot = [LeadYa.RetainedProfile]::Open($fixture, $origin)
    try {
        if ([Text.Encoding]::UTF8.GetString($snapshot.Configuration) -ne 'synthetic-retained-data') { throw 'Snapshot changed' }
        Assert-Refused { [IO.File]::WriteAllText($config, 'replace') }
        Assert-Refused { [IO.Directory]::Move($fixture, ($fixture + '-replaced')) }
    } finally { $snapshot.Dispose() }
    Assert-Refused { [LeadYa.RetainedProfile]::Open($fixture, 'https://testowy.leadya.pro') }
    [IO.File]::WriteAllText((Join-Path $fixture 'client-reset-required.txt'), 'reset')
    Assert-Refused { [LeadYa.RetainedProfile]::Open($fixture, $origin) }
    [IO.File]::Delete((Join-Path $fixture 'client-reset-required.txt'))
    $held = [IO.File]::Open((Join-Path $fixture '.leadya-agent-runtime\engine.lock'), 'Open', 'ReadWrite', 'ReadWrite')
    try { Assert-Refused { [LeadYa.RetainedProfile]::Open($fixture, $origin) } } finally { $held.Dispose() }
    $link = Join-Path $fixture 'hardlink.properties'
    New-Item -ItemType HardLink -Path $link -Target $config | Out-Null
    Assert-Refused { [LeadYa.RetainedProfile]::Open($fixture, $origin) }
    [IO.File]::Delete($link)
    $fileAcl = Get-Acl -LiteralPath $config
    $fileAcl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new('S-1-1-0'), 'Read', 'Allow'))
    Set-Acl -LiteralPath $config -AclObject $fileAcl
    Assert-Refused { [LeadYa.RetainedProfile]::Open($fixture, $origin) }
    $staged = Join-Path $fixture 'snapshot.tmp'
    $synthetic = [Text.Encoding]::UTF8.GetBytes('[TEST] synthetic retained profile')
    $inheritedHome = Join-Path $fixture 'inherited-home'
    [IO.Directory]::CreateDirectory($inheritedHome) | Out-Null
    $snapshotAcl = New-Object Security.AccessControl.DirectorySecurity
    $snapshotAcl.SetOwner([Security.Principal.WindowsIdentity]::GetCurrent().User)
    $snapshotAcl.SetAccessRuleProtection($true, $false)
    foreach ($sid in @([Security.Principal.WindowsIdentity]::GetCurrent().User.Value, 'S-1-5-18', 'S-1-5-32-544')) {
        $snapshotAcl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($sid), 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow'))
    }
    $snapshotAcl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new('S-1-1-0'), 'Read', 'ObjectInherit', 'InheritOnly', 'Allow'))
    Set-Acl -LiteralPath $inheritedHome -AclObject $snapshotAcl
    [LeadYa.RetainedProfile]::WritePrivateSnapshot($staged, $synthetic)
    if ([IO.File]::ReadAllBytes($staged).Length -ne $synthetic.Length) { throw 'Private snapshot was not written' }
    Assert-Refused { [LeadYa.RetainedProfile]::WritePrivateSnapshot($staged, $synthetic) }
    $staged = Join-Path $inheritedHome 'snapshot.tmp'
    Assert-Refused { [LeadYa.RetainedProfile]::WritePrivateSnapshot($staged, $synthetic) }
    if (-not [IO.File]::Exists($staged) -or (Get-Item -LiteralPath $staged).Length -ne 0) { throw 'Credential bytes reached an inherited foreign ACL' }
    Write-Output 'PASS: native retained-data pinning, no-clobber locks, origin, reset, active engine, hardlink, private ACL, snapshot inheritance refused before bytes'
} finally {
    # Only this test's randomly named fixture; never follow or remove unknown paths.
    $resolved = [IO.Path]::GetFullPath($fixture)
    if ([IO.Path]::GetDirectoryName($resolved) -ieq [IO.Path]::GetTempPath().TrimEnd('\') -and
        [IO.Path]::GetFileName($resolved) -match '^leadya-retained-test-[a-f0-9]{32}$') {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
