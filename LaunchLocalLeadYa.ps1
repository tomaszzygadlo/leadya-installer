param([switch]$NoDialog, [string]$JavaExecutable, [string]$RequestedVersion)

function ConvertTo-LocalLaunchCode($Value) {
    $code = ([string]($Value -join "`n")).Trim()
    if ($code -cmatch '^LOCAL_[A-Z_]{1,70}$') { return $code }
    return 'LOCAL_VALIDATION_FAILED'
}

function Get-LocalJvmFailureCode([string]$Diagnostic) {
    # Keep in sync with the standalone validator; neither caller logs the captured text.
    if ($Diagnostic -match '(?i)insufficient memory for the Java Runtime Environment|Could not reserve enough space|Native memory allocation .* failed|OutOfMemoryError|paging file is too small|os::commit_memory.*(1455|error=8)') { return 'LOCAL_JAVA_MEMORY' }
    return 'LOCAL_JAVA_FAILED'
}

function Enter-LocalLaunchGate([string]$Name) {
    $mutex = [Threading.Mutex]::new($false, $Name)
    try {
        $owned = $false
        try { $owned = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $owned = $true }
        if ($owned) { return $mutex }
    } catch { $mutex.Dispose(); throw }
    $mutex.Dispose()
    return $null
}

function Invoke-LocalLaunchBootstrap([Diagnostics.ProcessStartInfo]$StartInfo) {
    $child = New-Object Diagnostics.Process
    $child.StartInfo = $StartInfo
    $child.StartInfo.RedirectStandardOutput = $true
    $child.StartInfo.RedirectStandardError = $true
    $started = $false
    $streams = @()
    try {
        $started = $child.Start()
        if (-not $started) { throw 'LOCAL_JAVA_FAILED' }
        foreach ($reader in @($child.StandardOutput, $child.StandardError)) {
            $buffer = New-Object char[] 4096
            $streams += [pscustomobject]@{ Reader=$reader; Buffer=$buffer; Read=$reader.ReadAsync($buffer, 0, $buffer.Length); Text=[Text.StringBuilder]::new(); Done=$false }
        }
        $watch = [Diagnostics.Stopwatch]::StartNew()
        do {
            foreach ($stream in $streams) {
                if (-not $stream.Done -and $stream.Read.IsCompleted) {
                    $count = $stream.Read.GetAwaiter().GetResult()
                    if ($count -eq 0) { $stream.Done = $true }
                    else {
                        $keep = [Math]::Min($count, [Math]::Max(0, 16384 - $stream.Text.Length))
                        if ($keep) { [void]$stream.Text.Append($stream.Buffer, 0, $keep) }
                        $stream.Read = $stream.Reader.ReadAsync($stream.Buffer, 0, $stream.Buffer.Length)
                    }
                }
            }
            $exited = $child.WaitForExit(50)
            if ($exited -and @($streams | Where-Object { -not $_.Done }).Count -eq 0) { break }
        } while ($watch.ElapsedMilliseconds -lt 3000)
        if ($exited -and $child.ExitCode -notin @(0, 5)) {
            return [pscustomobject]@{ ExitCode=$child.ExitCode; Code=(Get-LocalJvmFailureCode (($streams | ForEach-Object { $_.Text.ToString() }) -join "`n")); State='FAILED' }
        }
        return [pscustomobject]@{ ExitCode=0; Code='LOCAL_VALID'; State=$(if ($exited -and $child.ExitCode -eq 5) { 'ALREADY_RUNNING' } else { 'START_REQUESTED' }) }
    } catch {
        # Diagnostics must never launch a duplicate while the original process is still alive.
        if ($started -and -not $child.HasExited) { return [pscustomobject]@{ ExitCode=0; Code='LOCAL_VALID'; State='START_REQUESTED' } }
        throw
    } finally {
        # javaw previously had no console streams. Only the early JVM diagnostics are consumed;
        # a live application continues with its existing file logging after this bounded window.
        foreach ($stream in $streams) { try { $stream.Reader.BaseStream.Dispose() } catch { } }
        $child.Dispose()
    }
}

function Write-LocalLaunchEvent([string]$Event, $Code) {
    if (-not $script:startupLog -or $Event -cnotmatch '^[A-Z_]{1,50}$') { return }
    try {
        if (Test-Path -LiteralPath $script:startupLog) {
            $item = Get-Item -LiteralPath $script:startupLog -Force
            if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $item.Length -gt 1MB) { return }
        }
        [IO.File]::AppendAllText($script:startupLog, ([DateTime]::UtcNow.ToString('o') + ' ' + $Event + ' ' + (ConvertTo-LocalLaunchCode $Code) + "`n"))
    } catch { Write-Warning 'LeadYa startup log is unavailable' }
}

function Get-LocalLaunchOwner {
    try {
        $session = (Get-Process -Id $PID -ErrorAction Stop).SessionId
        $owner = Get-Process -Name explorer -ErrorAction Stop | Where-Object SessionId -EQ $session | Select-Object -First 1
        if ($owner -and $owner.Path -and $owner.StartTime) {
            return [pscustomobject]@{ Id=$owner.Id; Created=$owner.StartTime; Path=$owner.Path; Session=$session }
        }
    } catch { }
    return $null
}

function Test-LocalLaunchOwner($Owner) {
    if (-not $Owner) { return $false }
    try {
        $current = Get-Process -Id $Owner.Id -ErrorAction Stop
        return ($current.StartTime -eq $Owner.Created -and $current.Path -ieq $Owner.Path -and $current.SessionId -eq $Owner.Session)
    } catch { return $false }
}

function Show-LocalLaunchMemoryNotice {
    if ($script:memoryNoticeShown) { return }
    $script:memoryNoticeShown = $true
    if ($NoDialog) { return }
    try {
        Add-Type -AssemblyName System.Windows.Forms
        $script:memoryNotice = New-Object Windows.Forms.NotifyIcon
        $script:memoryNotice.Icon = [Drawing.SystemIcons]::Information
        $script:memoryNotice.Text = 'LeadYa'
        $script:memoryNotice.BalloonTipTitle = 'LeadYa'
        $script:memoryNotice.BalloonTipText = if ([Globalization.CultureInfo]::CurrentUICulture.TwoLetterISOLanguageName -eq 'pl') {
            'Mało pamięci RAM. Uruchomienie LeadYa może się opóźnić. Program ponowi próbę automatycznie.'
        } else { 'Memory is low. LeadYa may take longer to start. It will retry automatically.' }
        $script:memoryNotice.Visible = $true
        $script:memoryNotice.ShowBalloonTip(8000)
    } catch { Write-Warning 'LeadYa memory notification is unavailable' }
}

function Wait-LocalLaunchMemory([int]$Milliseconds) {
    $deadline = [DateTime]::UtcNow.AddMilliseconds($Milliseconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        if ($script:memoryNotice) { [Windows.Forms.Application]::DoEvents() }
        Start-Sleep -Milliseconds 100
    }
}

function Invoke-LocalLaunchPreparation([scriptblock]$Attempt, [scriptblock]$SessionAlive,
    [ValidateSet('PREPARE', 'BOOTSTRAP')][string]$Phase = 'PREPARE') {
    $notified = $false
    while ($true) {
        try { $result = & $Attempt } catch {
            $nativeError = $_.Exception
            while ($nativeError.InnerException) { $nativeError = $nativeError.InnerException }
            if ($nativeError -is [ComponentModel.Win32Exception] -and $nativeError.NativeErrorCode -in @(8, 14, 1455)) {
                $result = [pscustomobject]@{ ExitCode=12; Code='LOCAL_JAVA_MEMORY' }
            } else { throw }
        }
        $code = ConvertTo-LocalLaunchCode $result.Code
        if ($result.ExitCode -eq 0 -and $code -ceq 'LOCAL_VALID') {
            Write-LocalLaunchEvent ($Phase + '_READY') $code
            return $result
        }
        Write-LocalLaunchEvent ($Phase + '_FAILED') $code
        if ($code -cne 'LOCAL_JAVA_MEMORY') { throw $code }
        # Keep one pending request within the exact live interactive shell; no scheduler or orphan watcher.
        if (-not (& $SessionAlive)) { throw 'LOCAL_LAUNCH_SESSION_ENDED' }
        if (-not $notified) { Show-LocalLaunchMemoryNotice; $notified = $true }
        Wait-LocalLaunchMemory 3000
        if (-not (& $SessionAlive)) { throw 'LOCAL_LAUNCH_SESSION_ENDED' }
    }
}

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
$launchMessage = 'LeadYa could not start. Diagnostic code:'
$stage = 'START'
$launchMutex = $null
$script:startupLog = $null
$script:memoryNotice = $null
$script:memoryNoticeShown = $false
try {
    if ($RequestedVersion -and $RequestedVersion -notmatch '^\d+\.\d+\.\d+\.\d+$') { throw 'LOCAL_REQUESTED_VERSION' }
    if (([Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        $launchMessage = 'LeadYa is installed. Open LeadYa from the Start menu without Run as administrator.'
        throw 'LOCAL_ELEVATED_RUNTIME'
    }
    $binding = Join-Path $PSScriptRoot 'leadya-code-home.txt'
    $codeRoot = if ([IO.File]::Exists($binding)) { [IO.File]::ReadAllText($binding).TrimEnd("`r", "`n") } else { $PSScriptRoot }
    $origin = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'leadya-local-origin.txt')).Trim()
    $validator = Join-Path $PSScriptRoot 'ValidateLocalInstall.ps1'
    $native = Join-Path $PSHOME 'powershell.exe'
    $stage = 'PACKAGE'
    $packageOutput = & $native -NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File $validator -InstallDirectory $codeRoot -Mode Package -PublicOrigin $origin
    if ($LASTEXITCODE -ne 0) { throw (ConvertTo-LocalLaunchCode $packageOutput) }
    $package = ([string]($packageOutput -join "`n")).TrimEnd("`r", "`n")
    $validator = Join-Path $package 'ValidateLocalInstall.ps1'
    $version = [IO.File]::ReadAllText((Join-Path $package 'checking_program_version.txt')).Trim()
    if ($version -notmatch '^[A-Za-z0-9.]+$') { throw 'LOCAL_PROGRAM_VERSION' }
    $programFiles = if ($env:ProgramW6432) { $env:ProgramW6432 } else { $env:ProgramFiles }
    # java.exe + CreateNoWindow keeps startup windowless and makes JVM errors observable;
    # javaw.exe can hold a modal JVM error dialog instead of returning its failure.
    $java = Join-Path $programFiles 'Java\jdk-17.0.9+9-jre\bin\java.exe'
    if ($JavaExecutable) { $java = [IO.Path]::GetFullPath($JavaExecutable) }
    if (-not [IO.File]::Exists($java)) { throw 'LOCAL_JAVA_MISSING' }
    $stage = 'PROFILE'
    $resolved = & $native -NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File $validator -InstallDirectory $codeRoot -Mode Runtime -PublicOrigin $origin -SeedDirectory $package
    if ($LASTEXITCODE -ne 0) { throw (ConvertTo-LocalLaunchCode $resolved) }
    $runtime = ([string]($resolved -join "`n")).TrimEnd("`r", "`n")
    if (-not [IO.Path]::IsPathRooted($runtime) -or $runtime.Contains('"') -or $runtime.Contains("`r") -or $runtime.Contains("`n")) { throw 'LOCAL_RUNTIME_BINDING' }
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $launchMutex = Enter-LocalLaunchGate ('Local\LeadYa.Start.' + $identity + '.' + [IO.Path]::GetFileName($package))
    if (-not $launchMutex) { exit 0 }
    $stage = 'PREPARE'
    if ([IO.File]::Exists((Join-Path $runtime 'leadya-local-install.txt'))) {
        $script:startupLog = Join-Path $runtime 'leadya-startup.log'
        Write-LocalLaunchEvent 'PREPARE_REQUESTED' 'LOCAL_VALID'
    }
    $launchOwner = Get-LocalLaunchOwner
    Invoke-LocalLaunchPreparation -SessionAlive { Test-LocalLaunchOwner $launchOwner } -Attempt {
        $ready = & $native -NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File $validator -InstallDirectory $codeRoot -Mode Prepare -PublicOrigin $origin -RuntimeDirectory $runtime -ProgramJar "CheckingProgram-$version.jar" -JavaExecutable (Join-Path (Split-Path $java) 'java.exe') -SeedDirectory $package
        $preparationExit = $LASTEXITCODE
        $preparationCode = ConvertTo-LocalLaunchCode $ready
        # These outcomes can only be emitted after Prepare has bound and checked the private home.
        if ($preparationCode -in @('LOCAL_VALID', 'LOCAL_JAVA_MEMORY', 'LOCAL_JAVA_FAILED', 'LOCAL_JAVA_TIMEOUT') -and
            [IO.File]::Exists((Join-Path $runtime 'leadya-local-install.txt'))) { $script:startupLog = Join-Path $runtime 'leadya-startup.log' }
        [pscustomobject]@{ ExitCode=$preparationExit; Code=$preparationCode }
    } | Out-Null
    $script:startupLog = Join-Path $runtime 'leadya-startup.log'
    # Only this verified ordinary token may write to a user-selected folder or personal shortcuts.
    & $native -NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File $validator -InstallDirectory $codeRoot -Mode Mirror -PublicOrigin $origin -ProgramJar "CheckingProgram-$version.jar" -SeedDirectory $package | Out-Null
    $stage = 'BOOTSTRAP'
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
    if (-not $selected) { throw 'LOCAL_BOOTSTRAP_MISSING' }
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
    $bootstrap = Invoke-LocalLaunchPreparation -Phase BOOTSTRAP -SessionAlive { Test-LocalLaunchOwner $launchOwner } -Attempt {
        Invoke-LocalLaunchBootstrap $start
    }
    Write-LocalLaunchEvent $bootstrap.State 'LOCAL_VALID'
    exit 0
} catch {
    $code = ConvertTo-LocalLaunchCode $_.Exception.Message
    Write-LocalLaunchEvent ($stage + '_FAILED') $code
    Write-Error ("LeadYa startup failed: " + $stage + ' ' + $code) -ErrorAction Continue
    if (-not $NoDialog -and $code -cne 'LOCAL_LAUNCH_SESSION_ENDED') {
        Add-Type -AssemblyName System.Windows.Forms
        [Windows.Forms.MessageBox]::Show(($launchMessage + "`n`n" + $stage + ': ' + $code), 'LeadYa') | Out-Null
    }
    exit 1
} finally {
    if ($script:memoryNotice) { $script:memoryNotice.Dispose() }
    if ($launchMutex) { $launchMutex.ReleaseMutex(); $launchMutex.Dispose() }
}
