param([string]$NsisCompiler = 'makensis')
$ErrorActionPreference = 'Stop'
$source = if (Test-Path -LiteralPath (Join-Path $PSScriptRoot '../Leadya.nsi')) { Join-Path $PSScriptRoot '..' } else { $PSScriptRoot }
. (Join-Path $source 'UninstallLocalLeadYa.ps1') -FunctionsOnly
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('leadya-uninstall-test-' + [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($fixture) | Out-Null
function New-TestProfile([string]$Name) {
    $root = Join-Path $fixture $Name
    [IO.Directory]::CreateDirectory((Join-Path $root 'bot_files/browser')) | Out-Null
    [IO.File]::WriteAllLines((Join-Path $root 'leadya-local-install.txt'), @('LOCAL', $root, 'https://hotfix.turbot.pro'))
    [IO.File]::WriteAllText((Join-Path $root 'bot_files/bot.properties'), '[TEST]-private')
    [IO.File]::WriteAllText((Join-Path $root 'bot_files/browser/Cookies'), '[TEST]-cookies')
    [IO.File]::WriteAllText((Join-Path $root 'CheckingProgram-1.2.3.4.jar'), '[TEST]-old')
    return $root
}
try {
    $profile = New-TestProfile 'remove'
    [LeadYa.LocalUninstallFiles]::DeleteProfile($profile, 'https://hotfix.turbot.pro')
    if (Test-Path -LiteralPath $profile) { throw 'Profile contents remain' }
    $profile = New-TestProfile 'unicode-marker'
    [IO.File]::WriteAllLines((Join-Path $profile 'leadya-local-install.txt'), @('LOCAL', $profile, 'https://hotfix.turbot.pro'), [Text.Encoding]::Unicode)
    [LeadYa.LocalUninstallFiles]::DeleteProfile($profile, 'https://hotfix.turbot.pro')
    if (Test-Path -LiteralPath $profile) { throw 'UTF16 installer marker was not supported' }
    $profile = New-TestProfile 'resume-partial'
    $script:deletions = 0
    $interrupt = [Action[string]] {
        param($path)
        $script:deletions++
        if ($script:deletions -eq 2) { throw [IO.IOException]::new('LOCAL_UNINSTALL_DEADLINE') }
    }
    try { [LeadYa.LocalUninstallFiles]::DeleteProfiles(@($profile), 'https://hotfix.turbot.pro', $interrupt); throw 'Injected interruption ignored' }
    catch { if ($_.Exception.ToString() -notmatch 'LOCAL_UNINSTALL_DEADLINE') { throw } }
    if (-not (Test-Path -LiteralPath (Join-Path $profile 'leadya-local-install.txt'))) { throw 'Partial deletion lost ownership marker' }
    [LeadYa.LocalUninstallFiles]::DeleteProfile($profile, 'https://hotfix.turbot.pro')
    if (Test-Path -LiteralPath $profile) { throw 'Interrupted deletion could not resume' }
    $profile = New-TestProfile 'resume-final-root'
    $interrupt = [Action[string]] { param($path); if ([IO.Path]::GetFileName($path) -ceq 'resume-final-root') { throw [IO.IOException]::new('LOCAL_UNINSTALL_IN_USE') } }
    try { [LeadYa.LocalUninstallFiles]::DeleteProfiles(@($profile), 'https://hotfix.turbot.pro', $interrupt); throw 'Injected final interruption ignored' }
    catch { if ($_.Exception.ToString() -notmatch 'LOCAL_UNINSTALL_IN_USE') { throw } }
    if (-not (Test-Path -LiteralPath $profile) -or @(Get-ChildItem -LiteralPath $profile -Force).Count) { throw 'Final interruption did not leave only an empty root' }
    [LeadYa.LocalUninstallFiles]::DeleteProfile($profile, 'https://hotfix.turbot.pro')
    if (Test-Path -LiteralPath $profile) { throw 'Empty final root could not resume' }
    $profile = New-TestProfile 'unmarked-nonempty'
    [IO.File]::Delete((Join-Path $profile 'leadya-local-install.txt'))
    try { [LeadYa.LocalUninstallFiles]::DeleteProfile($profile, 'https://hotfix.turbot.pro'); throw 'Unmarked nonempty profile accepted' }
    catch { if ($_.Exception.ToString() -notmatch 'LOCAL_UNINSTALL_MARKER') { throw } }
    if (-not (Test-Path -LiteralPath (Join-Path $profile 'bot_files/bot.properties'))) { throw 'Unmarked nonempty profile changed' }
    Write-Output 'PASS: interruption retains marker; retries finish partial and empty-root removal; unmarked nonempty profile refused'
    $profile = New-TestProfile 'locked'
    $locked = [IO.File]::Open((Join-Path $profile 'bot_files/browser/Cookies'), 'Open', 'ReadWrite', 'None')
    try {
        try { [LeadYa.LocalUninstallFiles]::DeleteProfile($profile, 'https://hotfix.turbot.pro'); throw 'Active profile accepted' }
        catch { if ($_.Exception.ToString() -notmatch 'LOCAL_UNINSTALL_IN_USE') { throw } }
        if (-not (Test-Path -LiteralPath (Join-Path $profile 'CheckingProgram-1.2.3.4.jar'))) { throw 'Partial deletion before lock refusal' }
    } finally { $locked.Dispose() }
    $profile = New-TestProfile 'foreign'
    try { [LeadYa.LocalUninstallFiles]::DeleteProfile($profile, 'https://other.example'); throw 'Foreign marker accepted' }
    catch { if ($_.Exception.ToString() -notmatch 'LOCAL_UNINSTALL_MARKER') { throw } }
    if (-not (Test-Path -LiteralPath (Join-Path $profile 'bot_files/bot.properties'))) { throw 'Foreign profile changed' }
    $outside = New-TestProfile 'outside'
    $profile = New-TestProfile 'junction'
    New-Item -ItemType Junction -Path (Join-Path $profile 'redirect') -Target $outside | Out-Null
    try { [LeadYa.LocalUninstallFiles]::DeleteProfile($profile, 'https://hotfix.turbot.pro'); throw 'Junction accepted' }
    catch { if ($_.Exception.ToString() -notmatch 'LOCAL_UNINSTALL_REPARSE') { throw } }
    if (-not (Test-Path -LiteralPath (Join-Path $outside 'bot_files/bot.properties'))) { throw 'Junction target changed' }
    [IO.Directory]::Delete((Join-Path $profile 'redirect'))
    Write-Output 'PASS: complete marked profile; no mutation on open file, foreign marker or junction'
    $installerSource = Join-Path $fixture 'installer.exe'
    $script = 'Unicode true' + "`n" + 'Name "LeadYa disposable classification fixture"' + "`n" + 'RequestExecutionLevel user' + "`n" + 'OutFile "installer.exe"' + "`nSection`nSectionEnd`n"
    [IO.File]::WriteAllText((Join-Path $fixture 'installer.nsi'), $script)
    $build = Start-Process -FilePath $NsisCompiler -ArgumentList ('/V2 "' + (Join-Path $fixture 'installer.nsi') + '"') -WorkingDirectory $fixture -WindowStyle Hidden -PassThru
    if (-not $build.WaitForExit(15000) -or $build.ExitCode -ne 0) { throw 'Native classifier fixture did not compile' }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    foreach ($profileChoice in @($false, $true)) {
        foreach ($installerChoice in @($false, $true)) {
            $name = 'choice-' + $profileChoice + '-' + $installerChoice
            $profile = New-TestProfile $name
            $downloads = Join-Path $fixture ($name + '-downloads')
            [IO.Directory]::CreateDirectory($downloads) | Out-Null
            Copy-Item -LiteralPath $installerSource -Destination (Join-Path $downloads 'LeadyaInstaller (2).exe')
            Copy-Item -LiteralPath $installerSource -Destination (Join-Path $downloads 'unrelated.exe')
            [IO.File]::WriteAllText((Join-Path $downloads 'LeadyaInstaller (9).exe'), '[TEST]-not-an-installer')
            $zip = [IO.Compression.ZipFile]::Open((Join-Path $downloads 'LeadyaVpsInstaller-HOTFIX_TURBOT_PRO (1).zip'), 'Create')
            try { [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $installerSource, 'LeadyaVpsInstaller-HOTFIX_TURBOT_PRO.exe') | Out-Null }
            finally { $zip.Dispose() }
            $count = Invoke-LocalUserCleanup @($profile) 'https://hotfix.turbot.pro' $downloads $profileChoice $installerChoice
            if ((Test-Path -LiteralPath $profile) -eq $profileChoice) { throw 'Profile checkbox was ignored' }
            foreach ($file in @('LeadyaInstaller (2).exe', 'LeadyaVpsInstaller-HOTFIX_TURBOT_PRO (1).zip')) {
                if ((Test-Path -LiteralPath (Join-Path $downloads $file)) -eq $installerChoice) { throw 'Downloaded installer checkbox was ignored' }
            }
            if ($count -ne $(if ($installerChoice) { 2 } else { 0 })) { throw 'Incorrect installer removal count' }
            if (-not (Test-Path -LiteralPath (Join-Path $downloads 'unrelated.exe')) -or
                -not (Test-Path -LiteralPath (Join-Path $downloads 'LeadyaInstaller (9).exe'))) { throw 'Unrelated download removed' }
        }
    }
    Write-Output 'PASS: four independent profile/installer choices, real NSIS EXE and ZIP, unrelated downloads preserved'
    $first = New-TestProfile 'first'
    $second = New-TestProfile 'second'
    $locked = [IO.File]::Open((Join-Path $second 'bot_files/browser/Cookies'), 'Open', 'ReadWrite', 'None')
    try {
        try { [LeadYa.LocalUninstallFiles]::DeleteProfiles(@($first, $second), 'https://hotfix.turbot.pro'); throw 'Second locked profile accepted' }
        catch { if ($_.Exception.ToString() -notmatch 'LOCAL_UNINSTALL_IN_USE') { throw } }
        if (-not (Test-Path -LiteralPath (Join-Path $first 'bot_files/bot.properties'))) { throw 'First profile changed before second was validated' }
    } finally { $locked.Dispose() }
    [IO.File]::WriteAllLines((Join-Path $second 'leadya-local-install.txt'), @('LOCAL', $second, 'https://other.example'))
    try { [LeadYa.LocalUninstallFiles]::DeleteProfiles(@($first, $second), 'https://hotfix.turbot.pro'); throw 'Second foreign profile accepted' }
    catch { if ($_.Exception.ToString() -notmatch 'LOCAL_UNINSTALL_MARKER') { throw } }
    if (-not (Test-Path -LiteralPath (Join-Path $first 'bot_files/bot.properties'))) { throw 'First profile changed before second marker check' }
    $self = [Diagnostics.Process]::GetCurrentProcess()
    try {
        try {
            [LeadYa.LocalUninstallFiles]::ConfigureOwner($PID, $self.StartTime.ToFileTimeUtc(), $self.MainModule.FileName, [LeadYa.LocalUninstallFiles]::DeadlineIn(0))
            throw 'Expired uninstall worker accepted'
        } catch { if ($_.Exception.ToString() -notmatch 'LOCAL_UNINSTALL_DEADLINE') { throw } }
        try { [LeadYa.LocalUninstallFiles]::DeleteProfile($first, 'https://hotfix.turbot.pro'); throw 'Expired worker deleted data' }
        catch { if ($_.Exception.ToString() -notmatch 'LOCAL_UNINSTALL_DEADLINE') { throw } }
        if (-not (Test-Path -LiteralPath (Join-Path $first 'bot_files/bot.properties'))) { throw 'Expired worker mutated the profile' }
    } finally { [LeadYa.LocalUninstallFiles]::ClearOwner(); $self.Dispose() }
    $child = Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList '-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -Command "Start-Sleep -Seconds 2"' -WindowStyle Hidden -PassThru
    try {
        [LeadYa.LocalUninstallFiles]::ConfigureOwner($child.Id, $child.StartTime.ToFileTimeUtc(), $child.MainModule.FileName, [LeadYa.LocalUninstallFiles]::DeadlineIn(20))
        if (-not $child.WaitForExit(10000)) { throw 'Disposable owner did not exit' }
        try { [LeadYa.LocalUninstallFiles]::DeleteProfile($first, 'https://hotfix.turbot.pro'); throw 'Closed owner accepted' }
        catch { if ($_.Exception.ToString() -notmatch 'LOCAL_UNINSTALL_OWNER') { throw } }
        if (-not (Test-Path -LiteralPath (Join-Path $first 'bot_files/bot.properties'))) { throw 'Closed owner worker mutated profile' }
    } finally { [LeadYa.LocalUninstallFiles]::ClearOwner(); $child.Dispose() }
    Write-Output 'PASS: both profiles preflighted before mutation; expired worker performs no deletion'
} finally {
    $resolved = [IO.Path]::GetFullPath($fixture)
    if ([IO.Path]::GetDirectoryName($resolved) -ieq [IO.Path]::GetTempPath().TrimEnd('\') -and
        [IO.Path]::GetFileName($resolved) -match '^leadya-uninstall-test-[a-f0-9]{32}$') {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
