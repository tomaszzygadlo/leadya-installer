param([switch]$NoDialog, [string]$JavaExecutable)

$ErrorActionPreference = 'Stop'
$env:PSModulePath = Join-Path $PSHOME 'Modules'
$launchMessage = 'LeadYa could not start. Run the installer again to repair this installation.'
try {
    if (([Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        $launchMessage = 'LeadYa is installed. Open LeadYa from the Start menu without Run as administrator.'
        throw 'Run LeadYa from a normal user shortcut; elevated application startup is refused'
    }
    $binding = Join-Path $PSScriptRoot 'leadya-code-home.txt'
    $codeRoot = if ([IO.File]::Exists($binding)) { [IO.File]::ReadAllText($binding).TrimEnd("`r", "`n") } else { $PSScriptRoot }
    $origin = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'leadya-local-origin.txt')).Trim()
    $validator = Join-Path $PSScriptRoot 'ValidateLocalInstall.ps1'
    $native = Join-Path $PSHOME 'powershell.exe'
    $packageOutput = & $native -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $validator -InstallDirectory $codeRoot -Mode Package -PublicOrigin $origin
    if ($LASTEXITCODE -ne 0) { throw 'Protected package is unavailable' }
    $package = ([string]($packageOutput -join "`n")).TrimEnd("`r", "`n")
    $validator = Join-Path $package 'ValidateLocalInstall.ps1'
    # Per-user entry points and autostart are written only after the actual token guard above.
    $shell = New-Object -ComObject WScript.Shell
    foreach ($link in @((Join-Path ([Environment]::GetFolderPath('DesktopDirectory')) 'Leadya.lnk'),
        (Join-Path ([Environment]::GetFolderPath('Startup')) 'Leadya.lnk'),
        (Join-Path ([Environment]::GetFolderPath('Programs')) 'Leadya\Leadya.lnk'))) {
        try {
            [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($link)) | Out-Null
            $shortcut = $shell.CreateShortcut($link)
            $shortcut.TargetPath = Join-Path $package 'LeadyaCheckingProgram.bat'
            $shortcut.WorkingDirectory = $package
            $shortcut.WindowStyle = 7
            $shortcut.Save()
        } catch { Write-Warning 'A personal LeadYa shortcut could not be refreshed' }
    }
    $version = [IO.File]::ReadAllText((Join-Path $package 'checking_program_version.txt')).Trim()
    if ($version -notmatch '^[A-Za-z0-9.]+$') { throw 'Invalid program version' }
    $programFiles = if ($env:ProgramW6432) { $env:ProgramW6432 } else { $env:ProgramFiles }
    $java = Join-Path $programFiles 'Java\jdk-17.0.9+9-jre\bin\javaw.exe'
    if (-not [IO.File]::Exists($java)) { $java = Join-Path $programFiles 'Java\jdk-17.0.9+9-jre\bin\java.exe' }
    if ($JavaExecutable) { $java = [IO.Path]::GetFullPath($JavaExecutable) }
    if (-not [IO.File]::Exists($java)) { throw 'Missing installed Java' }
    $resolved = & $native -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $validator -InstallDirectory $codeRoot -Mode Runtime -PublicOrigin $origin -SeedDirectory $package
    if ($LASTEXITCODE -ne 0) { throw 'Private profile is unavailable' }
    $runtime = ([string]($resolved -join "`n")).TrimEnd("`r", "`n")
    if (-not [IO.Path]::IsPathRooted($runtime) -or $runtime.Contains('"') -or $runtime.Contains("`r") -or $runtime.Contains("`n")) { throw 'Invalid runtime home' }
    $ready = & $native -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $validator -InstallDirectory $codeRoot -Mode Prepare -PublicOrigin $origin -RuntimeDirectory $runtime -ProgramJar "CheckingProgram-$version.jar" -JavaExecutable (Join-Path (Split-Path $java) 'java.exe') -SeedDirectory $package
    if ($LASTEXITCODE -ne 0) { throw 'Private runtime preparation failed' }
    # Only this verified ordinary token may write to a user-selected folder or personal shortcuts.
    & $native -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $validator -InstallDirectory $codeRoot -Mode Mirror -PublicOrigin $origin -ProgramJar "CheckingProgram-$version.jar" -SeedDirectory $package | Out-Null
    $jar = Join-Path $runtime "CheckingProgram-$version.jar"
    $env:LEADYA_HOME = $runtime
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = $java
    $start.WorkingDirectory = $runtime
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.Arguments = '"-Dleadya.local.home=' + $runtime + '" -jar "' + $jar + '" --exclusive-start'
    $child = [Diagnostics.Process]::Start($start)
    $child.Dispose()
    exit 0
} catch {
    Write-Error ("LeadYa startup failed: " + $_.Exception.Message + " " + $_.ScriptStackTrace) -ErrorAction Continue
    if (-not $NoDialog) {
        Add-Type -AssemblyName System.Windows.Forms
        [Windows.Forms.MessageBox]::Show($launchMessage, 'LeadYa') | Out-Null
    }
    exit 1
}
