param([switch]$NoDialog, [string]$JavaExecutable, [string]$RequestedVersion)

function Update-PersonalLaunchLinks([string]$Package, [string[]]$Links, [string]$StartupLink) {
    try { $shell = New-Object -ComObject WScript.Shell } catch { return $false }
    $scriptHost = Join-Path $env:SystemRoot 'System32\wscript.exe'
    $launchArguments = '//B //Nologo "' + (Join-Path $Package 'LaunchLocalLeadYa.vbs') + '"'
    $startupSaved = $false
    foreach ($link in $Links) {
        try {
            [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($link)) | Out-Null
            $shortcut = $shell.CreateShortcut($link)
            $shortcut.TargetPath = $scriptHost
            $shortcut.Arguments = $launchArguments
            $shortcut.WorkingDirectory = $Package
            $shortcut.WindowStyle = 1
            $shortcut.IconLocation = (Join-Path $Package 'leadya-nova-icon.ico') + ',0'
            $shortcut.Save()
            $saved = $shell.CreateShortcut($link)
            if ($saved.TargetPath -ine $scriptHost -or $saved.Arguments -cne $launchArguments) { throw 'Shortcut verification failed' }
            if ($link -ieq $StartupLink) { $startupSaved = $true }
        } catch { Write-Warning 'A personal LeadYa shortcut could not be refreshed' }
    }
    return $startupSaved
}

$ErrorActionPreference = 'Stop'
$env:PSModulePath = Join-Path $PSHOME 'Modules'
$launchMessage = 'LeadYa could not start. Run the installer again to repair this installation.'
try {
    if ($RequestedVersion -and $RequestedVersion -notmatch '^\d+\.\d+\.\d+\.\d+$') { throw 'Invalid requested bootstrap version' }
    if (([Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        $launchMessage = 'LeadYa is installed. Open LeadYa from the Start menu without Run as administrator.'
        throw 'Run LeadYa from a normal user shortcut; elevated application startup is refused'
    }
    $binding = Join-Path $PSScriptRoot 'leadya-code-home.txt'
    $codeRoot = if ([IO.File]::Exists($binding)) { [IO.File]::ReadAllText($binding).TrimEnd("`r", "`n") } else { $PSScriptRoot }
    $origin = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'leadya-local-origin.txt')).Trim()
    $validator = Join-Path $PSScriptRoot 'ValidateLocalInstall.ps1'
    $native = Join-Path $PSHOME 'powershell.exe'
    $packageOutput = & $native -NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File $validator -InstallDirectory $codeRoot -Mode Package -PublicOrigin $origin
    if ($LASTEXITCODE -ne 0) { throw 'Protected package is unavailable' }
    $package = ([string]($packageOutput -join "`n")).TrimEnd("`r", "`n")
    $validator = Join-Path $package 'ValidateLocalInstall.ps1'
    $version = [IO.File]::ReadAllText((Join-Path $package 'checking_program_version.txt')).Trim()
    if ($version -notmatch '^[A-Za-z0-9.]+$') { throw 'Invalid program version' }
    $programFiles = if ($env:ProgramW6432) { $env:ProgramW6432 } else { $env:ProgramFiles }
    $java = Join-Path $programFiles 'Java\jdk-17.0.9+9-jre\bin\javaw.exe'
    if (-not [IO.File]::Exists($java)) { $java = Join-Path $programFiles 'Java\jdk-17.0.9+9-jre\bin\java.exe' }
    if ($JavaExecutable) { $java = [IO.Path]::GetFullPath($JavaExecutable) }
    if (-not [IO.File]::Exists($java)) { throw 'Missing installed Java' }
    $resolved = & $native -NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File $validator -InstallDirectory $codeRoot -Mode Runtime -PublicOrigin $origin -SeedDirectory $package
    if ($LASTEXITCODE -ne 0) { throw 'Private profile is unavailable' }
    $runtime = ([string]($resolved -join "`n")).TrimEnd("`r", "`n")
    if (-not [IO.Path]::IsPathRooted($runtime) -or $runtime.Contains('"') -or $runtime.Contains("`r") -or $runtime.Contains("`n")) { throw 'Invalid runtime home' }
    $ready = & $native -NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File $validator -InstallDirectory $codeRoot -Mode Prepare -PublicOrigin $origin -RuntimeDirectory $runtime -ProgramJar "CheckingProgram-$version.jar" -JavaExecutable (Join-Path (Split-Path $java) 'java.exe') -SeedDirectory $package
    if ($LASTEXITCODE -ne 0) { throw 'Private runtime preparation failed' }
    # Only this verified ordinary token may write to a user-selected folder or personal shortcuts.
    & $native -NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File $validator -InstallDirectory $codeRoot -Mode Mirror -PublicOrigin $origin -ProgramJar "CheckingProgram-$version.jar" -SeedDirectory $package | Out-Null
    $startupLog = Join-Path $runtime 'leadya-startup.log'
    $available = @()
    foreach ($file in Get-ChildItem -LiteralPath $runtime -Filter 'CheckingProgram-*.jar' -File) {
        if ($file.Name -match '^CheckingProgram-(\d+\.\d+\.\d+\.\d+)\.jar$') {
            $available += [pscustomobject]@{Version=[version]$Matches[1]; Path=$file.FullName}
        }
    }
    $cache = Join-Path $runtime 'bot_files\downloaded\checking_program'
    if ([IO.Directory]::Exists($cache)) {
        foreach ($directory in Get-ChildItem -LiteralPath $cache -Directory) {
            $cached = Join-Path $directory.FullName 'CheckingProgram.jar'
            if ($directory.Name -match '^\d+\.\d+\.\d+\.\d+$' -and [IO.File]::Exists($cached)) {
                $available += [pscustomobject]@{Version=[version]$directory.Name; Path=$cached}
            }
        }
    }
    if ($RequestedVersion) { $available = @($available | Where-Object { $_.Version -eq [version]$RequestedVersion }) }
    $selected = $available | Sort-Object Version -Descending | Select-Object -First 1
    if (-not $selected) { throw 'Installed bootstrap is unavailable' }
    $jar = $selected.Path
    $startupLink = Join-Path ([Environment]::GetFolderPath('Startup')) 'Leadya.lnk'
    $startupSaved = Update-PersonalLaunchLinks $package @((Join-Path ([Environment]::GetFolderPath('DesktopDirectory')) 'Leadya.lnk'),
        $startupLink,
        (Join-Path ([Environment]::GetFolderPath('Programs')) 'Leadya\Leadya.lnk')) $startupLink
    # Startup folder is the single autostart registration; retire our duplicate legacy Run value.
    if ($startupSaved) { Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'Leadya Checking Program' -ErrorAction SilentlyContinue }
    $env:LEADYA_HOME = $runtime
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = $java
    $start.WorkingDirectory = $runtime
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.Arguments = '"-Dleadya.local.home=' + $runtime + '" -jar "' + $jar + '" --exclusive-start'
    $child = [Diagnostics.Process]::Start($start)
    try {
        $exited = $child.WaitForExit(3000)
        if ($exited -and $child.ExitCode -notin @(0, 5)) { throw ('Bootstrap exited with code ' + $child.ExitCode) }
        $state = if ($exited -and $child.ExitCode -eq 5) { 'ALREADY_RUNNING' } else { 'START_REQUESTED' }
        try { [IO.File]::AppendAllText($startupLog, ([DateTime]::UtcNow.ToString('o') + ' ' + $state + ' ' + $selected.Version + "`n")) }
        catch { Write-Warning 'LeadYa startup log is unavailable' }
    } finally { $child.Dispose() }
    exit 0
} catch {
    if ($startupLog) { try { [IO.File]::AppendAllText($startupLog, ([DateTime]::UtcNow.ToString('o') + ' START_FAILED' + "`n")) } catch { } }
    Write-Error ("LeadYa startup failed: " + $_.Exception.Message + " " + $_.ScriptStackTrace) -ErrorAction Continue
    if (-not $NoDialog) {
        Add-Type -AssemblyName System.Windows.Forms
        [Windows.Forms.MessageBox]::Show(($launchMessage + "`n`n" + $_.Exception.Message), 'LeadYa') | Out-Null
    }
    exit 1
}
