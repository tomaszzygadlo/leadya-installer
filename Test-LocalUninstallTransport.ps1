param([string]$Compiler = 'makensis', [string]$PluginDirectory)
$ErrorActionPreference = 'Stop'
$source = [IO.Path]::GetFullPath($(if (Test-Path -LiteralPath (Join-Path $PSScriptRoot '../Leadya.nsi')) { Join-Path $PSScriptRoot '..' } else { $PSScriptRoot }))
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('leadya-uninstall-transport-' + [Guid]::NewGuid().ToString('N'))
$codeRoot = Join-Path $fixture 'program ! & ż'
$downloads = Join-Path $fixture 'Downloads'
$profiles = @()
if (-not $PluginDirectory) { $PluginDirectory = Join-Path $source 'plugins' }
function Quote-Nsis([string]$Value) { return $Value.Replace('$', '$$').Replace('"', '$\"') }
try {
    [IO.Directory]::CreateDirectory($downloads) | Out-Null
    $hash = [Security.Cryptography.SHA256]::Create()
    try { $id = ([BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($codeRoot.ToUpperInvariant() + "`nhttps://hotfix.turbot.pro")))).Replace('-', '').ToLowerInvariant() }
    finally { $hash.Dispose() }
    $profiles = @((Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) ('LeadYa/installations/' + $id)),
        (Join-Path ([Environment]::GetFolderPath('UserProfile')) ('.leadya-client/installations/' + $id)))
    foreach ($profile in $profiles) {
        if (Test-Path -LiteralPath $profile) { throw 'Fixture profile already exists' }
        [IO.Directory]::CreateDirectory((Join-Path $profile 'bot_files')) | Out-Null
        [IO.File]::WriteAllLines((Join-Path $profile 'leadya-local-install.txt'), @('LOCAL', $profile, 'https://hotfix.turbot.pro'))
        [IO.File]::WriteAllText((Join-Path $profile 'bot_files/bot.properties'), '[TEST]-disposable-profile')
    }
    [IO.File]::WriteAllText((Join-Path $downloads 'unrelated.txt'), '[TEST]-keep')
    # Redirect only the Known Folder boundary in an isolated helper copy. All native deletion,
    # ordinary-token guard, owner/deadline checks and fixed-file result exchange remain real.
    $helper = [IO.File]::ReadAllText((Join-Path $source 'UninstallLocalLeadYa.ps1'))
    $helper = $helper.Replace('[LeadYa.LocalUninstallFiles]::Downloads()', ("'" + $downloads.Replace("'", "''") + "'"))
    $aclEvidence = @'
$resultAcl = ([IO.FileInfo]::new($ResultFile)).GetAccessControl().GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])
$currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$writers = @($resultAcl | Where-Object { $_.AccessControlType -eq 'Allow' -and ([int]$_.FileSystemRights -band 2) } | ForEach-Object { $_.IdentityReference.Value })
if ($currentSid -notin $writers -or @($writers | Where-Object { $_ -notin @($currentSid, 'S-1-5-18', 'S-1-5-32-544') }).Count) { throw 'LOCAL_UNINSTALL_RESULT_WRITERS' }
$parentAcl = ([IO.DirectoryInfo]::new($PSScriptRoot)).GetAccessControl().GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])
if (@($parentAcl | Where-Object { $_.IdentityReference.Value -eq $currentSid -or $_.IdentityReference.Value -eq 'S-1-5-32-545' } | Where-Object { [int]$_.FileSystemRights -band 2 }).Count) { throw 'LOCAL_UNINSTALL_PARENT_WRITABLE' }
'@
    $helper = $helper.Replace("`$result = 'LOCAL_UNINSTALL_FAILED'", "`$result = 'LOCAL_UNINSTALL_FAILED'`n" + $aclEvidence)
    [IO.File]::WriteAllText((Join-Path $fixture 'UninstallLocalLeadYa.ps1'), $helper, [Text.UTF8Encoding]::new($false))
    $installer = [IO.File]::ReadAllText((Join-Path $source 'Leadya.nsi'))
    $callback = [regex]::Match($installer, '(?ms)^Function un\.CleanupLocalUser\r?\n.*?^FunctionEnd').Value
    if (-not $callback) { throw 'Actual user cleanup callback missing' }
    $nsi = @'
Unicode true
Name "LeadYa uninstall transport fixture"
RequestExecutionLevel admin
SilentInstall silent
SilentUnInstall silent
OutFile "fixture.exe"
!include nsDialogs.nsh
!addplugindir "@PLUGINS@"
!define public_origin "https://hotfix.turbot.pro"
Var uninstallOwnerPid
Var uninstallOwnerTime
Var uninstallOwnerExecutable
Var uninstallUserCommand
Var uninstallDeadlineTick
Var uninstallRemoveProfileState
Var uninstallRemoveInstallersState
@CALLBACK@
Function un.onInit
  InitPluginsDir
  CreateDirectory "$PLUGINSDIR\user-cleanup"
  File /oname=$PLUGINSDIR\user-cleanup\UninstallLocalLeadYa.ps1 "UninstallLocalLeadYa.ps1"
  StrCpy $INSTDIR "@CODE@"
  StrCpy $uninstallRemoveProfileState 1
  StrCpy $uninstallRemoveInstallersState 1
FunctionEnd
Section
  WriteUninstaller "$EXEDIR\Uninstall.exe"
  ExecWait '"$EXEDIR\Uninstall.exe" /S _?=$EXEDIR' $0
  SetErrorLevel $0
SectionEnd
Section "Uninstall"
  Call un.CleanupLocalUser
SectionEnd
'@
    $nsi = $nsi.Replace('@PLUGINS@', (Quote-Nsis $PluginDirectory)).Replace('@CODE@', (Quote-Nsis $codeRoot)).Replace('@CALLBACK@', $callback)
    [IO.File]::WriteAllText((Join-Path $fixture 'fixture.nsi'), $nsi, [Text.UTF8Encoding]::new($true))
    $build = Start-Process -FilePath $Compiler -ArgumentList ('/V2 "' + (Join-Path $fixture 'fixture.nsi') + '"') -WorkingDirectory $fixture -WindowStyle Hidden -PassThru
    if (-not $build.WaitForExit(15000) -or $build.ExitCode -ne 0) { throw 'Native fixture did not compile' }
    Copy-Item -LiteralPath (Join-Path $fixture 'fixture.exe') -Destination (Join-Path $downloads 'LeadyaInstaller (3).exe')
    $make = Start-Process -FilePath (Join-Path $fixture 'fixture.exe') -ArgumentList '/S' -Verb RunAs -WindowStyle Hidden -PassThru
    if (-not $make.WaitForExit(150000) -or $make.ExitCode -ne 0) { throw 'Elevated native uninstaller refused or timed out' }

    foreach ($profile in $profiles) { if (Test-Path -LiteralPath $profile) { throw 'Selected disposable profile remains' } }
    if ((Test-Path -LiteralPath (Join-Path $downloads 'LeadyaInstaller (3).exe')) -or
        [IO.File]::ReadAllText((Join-Path $downloads 'unrelated.txt')) -cne '[TEST]-keep') { throw 'Download cleanup result is incorrect' }
    Write-Output 'PASS: actual admin uninstaller callback, ordinary helper, both marked profiles and disposable installer removed, complete result returned'
} finally {
    foreach ($profile in $profiles) {
        if (Test-Path -LiteralPath $profile) {
            . (Join-Path $source 'UninstallLocalLeadYa.ps1') -FunctionsOnly
            [LeadYa.LocalUninstallFiles]::DeleteProfile($profile, 'https://hotfix.turbot.pro')
        }
    }
    $resolved = [IO.Path]::GetFullPath($fixture)
    if ([IO.Path]::GetDirectoryName($resolved) -ieq [IO.Path]::GetTempPath().TrimEnd('\') -and
        [IO.Path]::GetFileName($resolved) -match '^leadya-uninstall-transport-[a-f0-9]{32}$') {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
