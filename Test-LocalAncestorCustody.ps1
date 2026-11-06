$ErrorActionPreference = 'Stop'
$env:PSModulePath = Join-Path $PSHOME 'Modules'
$source = if (Test-Path -LiteralPath (Join-Path $PSScriptRoot '..\ValidateLocalInstall.ps1')) { Join-Path $PSScriptRoot '..' } else { $PSScriptRoot }
$parseErrors = $null
$tree = [Management.Automation.Language.Parser]::ParseFile((Join-Path $source 'ValidateLocalInstall.ps1'), [ref]$null, [ref]$parseErrors)
if ($parseErrors.Count) { throw 'Validator syntax is invalid' }
foreach ($name in @('Assert-Custody', 'Assert-PackagePath')) {
    $function = $tree.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
    if (-not $function) { throw "$name unavailable" }
    Invoke-Expression $function.Extent.Text
}
# Real native ACLs on owned fixtures. The fixture owner stands in for the trusted custodians of the real policy.
$operator = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$privateOwners = @($operator, 'S-1-5-18', 'S-1-5-32-544')
$ancestorOwners = $privateOwners + 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464'
$trustedOwners = @($operator, 'S-1-5-18', 'S-1-5-32-544', 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464')
$readonly = [long]([Security.AccessControl.FileSystemRights]::ReadAndExecute) -bor
    [long]([Security.AccessControl.FileSystemRights]::Synchronize) -bor
    [long]([Security.AccessControl.FileSystemRights]::AppendData)
# A derived capability SID (unresolvable on most systems) and the well-known ALL APPLICATION PACKAGES SID.
$capability = 'S-1-15-3-1024-1502825166-1963708345-2616377461-2562897074-4192028372-3968301570-1997628692-1435953622'
$allPackages = 'S-1-15-2-1'
$users = 'S-1-5-32-545'

function New-FixtureDirectory([string]$Path) {
    # Start from an explicit custodian-only ACL: TEMP may inherit unrelated writers on developer machines.
    $directory = [IO.Directory]::CreateDirectory($Path)
    $acl = $directory.GetAccessControl([Security.AccessControl.AccessControlSections]::Access)
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($rule in @($acl.GetAccessRules($true, $false, [Security.Principal.SecurityIdentifier]))) { $acl.RemoveAccessRuleSpecific($rule) }
    foreach ($sid in $privateOwners) {
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($sid), 'FullControl', 'Allow'))
    }
    $directory.SetAccessControl($acl)
}
function Set-FixtureRule([string]$Path, [string]$Sid, [string]$Rights) {
    $directory = [IO.DirectoryInfo]::new($Path)
    $acl = $directory.GetAccessControl([Security.AccessControl.AccessControlSections]::Access)
    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($Sid), $Rights, 'Allow'))
    $directory.SetAccessControl($acl)
    $granted = @((Get-Acl -LiteralPath $Path).GetAccessRules($true, $false, [Security.Principal.SecurityIdentifier]) |
        Where-Object { $_.IdentityReference.Value -eq $Sid -and ([long]$_.FileSystemRights -band (-bnot $readonly)) -ne 0 })
    if ($granted.Count -eq 0) { throw "Fixture did not grant a writable rule to $Sid" }
}
function Assert-Code([string]$Expected, [scriptblock]$Action) {
    $code = $null
    try { & $Action | Out-Null } catch { $code = [string]$_.Exception.Message }
    if ($code -cne $Expected) { throw "Expected $Expected, got '$code'" }
}
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('leadya-ancestor-custody-' + [Guid]::NewGuid().ToString('N'))
try {
    $packaged = Join-Path $fixture 'packaged'
    $foreign = Join-Path $fixture 'foreign'
    $private = Join-Path $fixture 'private'
    [IO.Directory]::CreateDirectory($fixture) | Out-Null
    foreach ($path in @($packaged, $foreign, $private)) { New-FixtureDirectory $path }
    # Control: the custodian-only fixture itself qualifies, so each refusal below is caused by its added rule.
    Assert-Custody $foreign $false
    Assert-PackagePath $foreign
    Assert-Custody $private $true
    Set-FixtureRule $packaged $capability 'FullControl'
    Set-FixtureRule $packaged $allPackages 'Modify'
    Assert-Custody $packaged $false
    Assert-PackagePath $packaged
    Assert-PackagePath $packaged $true
    Set-FixtureRule $foreign $users 'Modify'
    Assert-Code 'LOCAL_ANCESTOR_WRITABLE' { Assert-Custody $foreign $false }
    Assert-Code 'LOCAL_PACKAGE_WRITABLE' { Assert-PackagePath $foreign }
    Set-FixtureRule $private $capability 'Modify'
    Assert-Code 'LOCAL_PRIVATE_ACL' { Assert-Custody $private $true }
    Write-Output 'PASS: AppContainer capability/package rules do not refuse shared ancestors; foreign writers and private-home entries stay refused'
} finally {
    $resolved = [IO.Path]::GetFullPath($fixture)
    if ([IO.Path]::GetDirectoryName($resolved) -ieq [IO.Path]::GetTempPath().TrimEnd('\') -and
        [IO.Path]::GetFileName($resolved) -match '^leadya-ancestor-custody-[a-f0-9]{32}$' -and (Test-Path -LiteralPath $resolved)) {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
