param([switch]$NoDialog, [string]$JavaExecutable, [string]$RequestedVersion)

function ConvertTo-LocalLaunchCode($Value) {
    $code = ([string]($Value -join "`n")).Trim()
    if ($code -cmatch '^LOCAL_[A-Z_]{1,70}$') { return $code }
    return 'LOCAL_VALIDATION_FAILED'
}

function Select-LocalJava([string]$LocalAppData) {
    # The per-user runtime comes first. After a client died at once on it, its refusal lets any other Java go first;
    # alone it is still better than none. ProgramW6432 names the 64-bit program folder even in a 32-bit process.
    # LocalJavaProvisionerTest binds both names to WindowsJavaLocations of the client.
    $current = 'jdk-17.0.21+9-jre'
    $previous = 'jdk-17.0.9+9-jre'
    $perUser = if ($LocalAppData) { [IO.Path]::Combine($LocalAppData, 'LeadYa\Java', $current) } else { $null }
    $homes = New-Object Collections.Generic.List[string]
    if ($perUser -and -not [IO.File]::Exists($perUser + '.refused')) { $homes.Add($perUser) }
    foreach ($variable in @('ProgramW6432', 'ProgramFiles')) {
        $programs = [Environment]::GetEnvironmentVariable($variable)
        if (-not $programs) { continue }
        foreach ($name in @($current, $previous)) {
            $candidate = [IO.Path]::Combine($programs, 'Java', $name)
            if ($homes -notcontains $candidate) { $homes.Add($candidate) }
        }
    }
    if ($perUser) { $homes.Add($perUser) }
    foreach ($jreHome in $homes) {
        $java = [IO.Path]::Combine($jreHome, 'bin\java.exe')
        if ([IO.File]::Exists($java)) { return $java }
    }
    return $null
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

function Invoke-LocalLaunchBootstrap([Diagnostics.ProcessStartInfo]$StartInfo, [switch]$NativePreparation,
    [ValidateRange(1, 60000)][int]$PreparationTimeoutMilliseconds = 30000) {
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
                        $capacity = if ($NativePreparation) { 65536 } else { 16384 }
                        $keep = [Math]::Min($count, [Math]::Max(0, $capacity - $stream.Text.Length))
                        if ($keep) { [void]$stream.Text.Append($stream.Buffer, 0, $keep) }
                        $stream.Read = $stream.Reader.ReadAsync($stream.Buffer, 0, $stream.Buffer.Length)
                    }
                }
            }
            $exited = $child.WaitForExit(50)
            if ($exited -and @($streams | Where-Object { -not $_.Done }).Count -eq 0) { break }
        } while ($watch.ElapsedMilliseconds -lt $(if ($NativePreparation) { $PreparationTimeoutMilliseconds } else { 3000 }))
        if ($NativePreparation) {
            # Preparation must finish and return its protocol stdout before any application starts.
            if (-not $exited -or @($streams | Where-Object { -not $_.Done }).Count -gt 0) {
                return [pscustomobject]@{ ExitCode=12; Code='LOCAL_JAVA_TIMEOUT'; Output='' }
            }
            if ($child.ExitCode -ne 0) {
                return [pscustomobject]@{ ExitCode=$child.ExitCode; Code=(Get-LocalJvmFailureCode (($streams | ForEach-Object { $_.Text.ToString() }) -join "`n")); Output='' }
            }
            return [pscustomobject]@{ ExitCode=0; Code='LOCAL_VALID'; Output=$streams[0].Text.ToString() }
        }
        if ($exited -and $child.ExitCode -notin @(0, 5)) {
            return [pscustomobject]@{ ExitCode=$child.ExitCode; Code=(Get-LocalJvmFailureCode (($streams | ForEach-Object { $_.Text.ToString() }) -join "`n")); State='FAILED' }
        }
        return [pscustomobject]@{ ExitCode=0; Code='LOCAL_VALID'; State=$(if ($exited -and $child.ExitCode -eq 5) { 'ALREADY_RUNNING' } else { 'START_REQUESTED' }) }
    } catch {
        # Diagnostics must never launch a duplicate while the original process is still alive.
        if (-not $NativePreparation -and $started -and -not $child.HasExited) { return [pscustomobject]@{ ExitCode=0; Code='LOCAL_VALID'; State='START_REQUESTED' } }
        throw
    } finally {
        # javaw previously had no console streams. Only the early JVM diagnostics are consumed;
        # a live application continues with its existing file logging after this bounded window.
        try {
            if ($NativePreparation -and $started -and -not $child.HasExited) { $child.Kill(); $child.WaitForExit() }
        } finally {
            foreach ($stream in $streams) { try { $stream.Reader.BaseStream.Dispose() } catch { } }
            $child.Dispose()
        }
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

function Start-LocalLaunchNotice([string]$Package) {
    if ($NoDialog) { return $null }
    try {
        # The window runs on its own STA thread, so blocking validation and Java startup never freeze it.
        $notice = [hashtable]::Synchronized(@{ Close=$false; Closed=$false; Window=[IntPtr]::Zero })
        $runspace = [runspacefactory]::CreateRunspace()
        $runspace.ApartmentState = 'STA'
        $runspace.ThreadOptions = 'ReuseThread'
        $runspace.Open()
        $shell = [powershell]::Create()
        $shell.Runspace = $runspace
        [void]$shell.AddScript({
            param($Notice, [bool]$Polish, [string]$Icon)
            try {
                Add-Type -AssemblyName System.Windows.Forms, System.Drawing
                [Windows.Forms.Application]::EnableVisualStyles()
                $form = New-Object Windows.Forms.Form
                $form.Text = 'LeadYa'
                $form.FormBorderStyle = 'FixedDialog'
                $form.MaximizeBox = $false
                $form.MinimizeBox = $false
                $form.StartPosition = 'CenterScreen'
                $form.TopMost = $true
                $form.AutoSize = $true
                $form.AutoSizeMode = 'GrowAndShrink'
                $form.Padding = New-Object Windows.Forms.Padding(12)
                if ([IO.File]::Exists($Icon)) { try { $form.Icon = New-Object Drawing.Icon($Icon) } catch { } }
                $layout = New-Object Windows.Forms.TableLayoutPanel
                $layout.AutoSize = $true
                $layout.ColumnCount = 1
                $title = New-Object Windows.Forms.Label
                $title.AutoSize = $true
                $title.Font = New-Object Drawing.Font('Segoe UI', 13, [Drawing.FontStyle]::Bold)
                $title.Text = if ($Polish) { 'LeadYa się uruchamia…' } else { 'LeadYa is starting…' }
                $detail = New-Object Windows.Forms.Label
                $detail.AutoSize = $true
                $detail.MaximumSize = New-Object Drawing.Size(360, 0)
                $detail.Margin = New-Object Windows.Forms.Padding(3, 8, 3, 12)
                $detail.Font = New-Object Drawing.Font('Segoe UI', 10)
                $detail.Text = if ($Polish) { 'Za chwilę pojawi się okno programu. Nie musisz klikać ponownie.' } else { 'The program window will appear shortly. You do not need to click again.' }
                $progress = New-Object Windows.Forms.ProgressBar
                $progress.Style = 'Marquee'
                $progress.MarqueeAnimationSpeed = 30
                $progress.Size = New-Object Drawing.Size(360, 14)
                $layout.Controls.AddRange(@($title, $detail, $progress))
                $form.Controls.Add($layout)
                $timer = New-Object Windows.Forms.Timer
                $timer.Interval = 150
                $timer.add_Tick({ if ($Notice.Close) { $form.Close() } })
                $form.add_Shown({ $Notice.Window = $form.Handle; $timer.Start() })
                $form.add_FormClosed({ $timer.Stop(); $Notice.Closed = $true })
                if (-not $Notice.Close) { [Windows.Forms.Application]::Run($form) }
            } finally { $Notice.Closed = $true }
        }).AddArgument($notice).AddArgument(([Globalization.CultureInfo]::CurrentUICulture.TwoLetterISOLanguageName -eq 'pl')).AddArgument((Join-Path $Package 'leadya-nova-icon.ico'))
        $notice.Shell = $shell
        $notice.Runspace = $runspace
        $notice.Handle = $shell.BeginInvoke()
        return $notice
    } catch {
        Write-Warning 'LeadYa startup notice is unavailable'
        return $null
    }
}

function Stop-LocalLaunchNotice($Notice) {
    # Returns $false while the notice window may still be open.
    if (-not $Notice) { return $true }
    if ($Notice.Stopped) { return [bool]$Notice.Released }
    $Notice.Stopped = $true
    $Notice.Close = $true
    try {
        if ($Notice.Handle.AsyncWaitHandle.WaitOne(3000)) {
            try { [void]$Notice.Shell.EndInvoke($Notice.Handle) } catch { }
            $Notice.Shell.Dispose()
            $Notice.Runspace.Dispose()
            $Notice.Released = $true
        }
    } catch { Write-Warning 'LeadYa startup notice could not be closed' }
    return [bool]$Notice.Released
}

function Wait-LocalClientWindow($Notice, [string]$JavaDirectory, [DateTime]$Since, [int]$Milliseconds, [string]$RuntimeDirectory) {
    # Only a window of a bundled-Java process started after this click counts; older LeadYa windows do not.
    $deadline = [DateTime]::UtcNow.AddMilliseconds($Milliseconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        if ($Notice.Closed) { return 'CLOSED' }
        foreach ($process in @(Get-Process -Name java, javaw, LeadYa, 'LeadYa Checking Program' -ErrorAction SilentlyContinue)) {
            try {
                if ($process.MainWindowHandle -ne [IntPtr]::Zero -and $process.StartTime -ge $Since -and
                    ([IO.Path]::GetDirectoryName($process.Path) -ieq $JavaDirectory -or
                     ($RuntimeDirectory -and $process.ProcessName -in @('LeadYa', 'LeadYa Checking Program') -and
                      $process.Path.StartsWith((Join-Path $RuntimeDirectory '.leadya-native') + '\', [StringComparison]::OrdinalIgnoreCase)))) { return 'SHOWN' }
            } catch { } finally { $process.Dispose() }
        }
        Start-Sleep -Milliseconds 250
    }
    return 'TIMEOUT'
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

function Invoke-LocalProfileStep([scriptblock]$Attempt, [ValidateSet('PROFILE', 'PREPARE')][string]$Phase,
    [scriptblock]$Pause = { Start-Sleep -Milliseconds 1000 }, [int]$Attempts = 3) {
    # A scanner or backup can hold a profile file for a moment; the validator then answers LOCAL_VALIDATION_FAILED.
    # Only that answer is tried again, about a second apart; any other answer, also a fixed refusal, is final at once.
    for ($try = 1; ; $try++) {
        $result = & $Attempt
        if ($result.ExitCode -eq 0 -or $try -ge $Attempts -or (ConvertTo-LocalLaunchCode $result.Output) -cne 'LOCAL_VALIDATION_FAILED') { return $result }
        Write-LocalLaunchEvent ($Phase + '_RETRY') 'LOCAL_VALIDATION_FAILED'
        & $Pause
    }
}

function Get-LocalLaunchFailureMessage([string]$Stage, [string]$Code, [string]$Language) {
    # Plain words for the person in Polish or English; the fixed code on its own line is only for technical support.
    # Only a failure that passes by itself (a file held for a moment, too little free memory) asks to try again soon;
    # any other one does not pass by waiting, so it asks to install LeadYa again or to contact support.
    $kind = 'reinstall'
    if ($Code -cin @('LOCAL_VALIDATION_FAILED', 'LOCAL_JAVA_MEMORY')) { $kind = 'retry' }
    if ($Code -ceq 'LOCAL_ELEVATED_RUNTIME') { $kind = 'elevated' }
    $supportLine = $Stage + ': ' + $Code
    if ($Language -ceq 'pl') {
        $text = 'Nie udało się uruchomić LeadYa. Zainstaluj LeadYa ponownie. Jeśli to nie pomoże, skontaktuj się z pomocą techniczną.'
        if ($kind -ceq 'retry') { $text = 'Nie udało się uruchomić LeadYa. Spróbuj ponownie za chwilę.' }
        if ($kind -ceq 'elevated') { $text = 'LeadYa jest już zainstalowana. Otwórz LeadYa z menu Start w zwykły sposób, nie jako administrator.' }
        return $text + "`n`nKod dla pomocy technicznej:`n" + $supportLine
    }
    $text = 'LeadYa could not start. Install LeadYa again. If that does not help, contact technical support.'
    if ($kind -ceq 'retry') { $text = 'LeadYa could not start. Please try again in a moment.' }
    if ($kind -ceq 'elevated') { $text = 'LeadYa is already installed. Open LeadYa from the Start menu in the usual way, not as administrator.' }
    return $text + "`n`nCode for technical support:`n" + $supportLine
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
$stage = 'START'
$launchMutex = $null
$launchNotice = $null
$launchStarted = [DateTime]::Now
$script:launchExitCode = 0
$script:startupLog = $null
$script:memoryNotice = $null
$script:memoryNoticeShown = $false
try {
    if ($RequestedVersion -and $RequestedVersion -notmatch '^\d+\.\d+\.\d+\.\d+$') { throw 'LOCAL_REQUESTED_VERSION' }
    if (([Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'LOCAL_ELEVATED_RUNTIME'
    }
    $launchNotice = Start-LocalLaunchNotice $PSScriptRoot
    $binding = Join-Path $PSScriptRoot 'leadya-code-home.txt'
    $codeRoot = if ([IO.File]::Exists($binding)) { [IO.File]::ReadAllText($binding).TrimEnd("`r", "`n") } else { $PSScriptRoot }
    $origin = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'leadya-local-origin.txt')).Trim()
    # A computer moved from the old machine-wide install keeps the identity of its original program folder.
    $identityBinding = Join-Path $PSScriptRoot 'leadya-identity-root.txt'
    $identityArguments = @(if ([IO.File]::Exists($identityBinding)) { '-IdentityRoot'; [IO.File]::ReadAllText($identityBinding).TrimEnd("`r", "`n") })
    $validator = Join-Path $PSScriptRoot 'ValidateLocalInstall.ps1'
    $native = Join-Path $PSHOME 'powershell.exe'
    $stage = 'PACKAGE'
    $packageOutput = & $native -NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File $validator -InstallDirectory $codeRoot -Mode Package -PublicOrigin $origin @identityArguments
    if ($LASTEXITCODE -ne 0) { throw (ConvertTo-LocalLaunchCode $packageOutput) }
    $package = ([string]($packageOutput -join "`n")).TrimEnd("`r", "`n")
    $validator = Join-Path $package 'ValidateLocalInstall.ps1'
    $version = [IO.File]::ReadAllText((Join-Path $package 'checking_program_version.txt')).Trim()
    if ($version -notmatch '^[A-Za-z0-9.]+$') { throw 'LOCAL_PROGRAM_VERSION' }
    # java.exe + CreateNoWindow keeps startup windowless and makes JVM errors observable;
    # javaw.exe can hold a modal JVM error dialog instead of returning its failure.
    $java = Select-LocalJava ([Environment]::GetFolderPath('LocalApplicationData'))
    if ($JavaExecutable) { $java = [IO.Path]::GetFullPath($JavaExecutable) }
    if (-not $java -or -not [IO.File]::Exists($java)) { throw 'LOCAL_JAVA_MISSING' }
    $stage = 'PROFILE'
    $resolved = Invoke-LocalProfileStep -Phase PROFILE -Attempt {
        $output = & $native -NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File $validator -InstallDirectory $codeRoot -Mode Runtime -PublicOrigin $origin -SeedDirectory $package @identityArguments
        [pscustomobject]@{ ExitCode=$LASTEXITCODE; Output=$output }
    }
    if ($resolved.ExitCode -ne 0) { throw (ConvertTo-LocalLaunchCode $resolved.Output) }
    $runtime = ([string]($resolved.Output -join "`n")).TrimEnd("`r", "`n")
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
        $ready = Invoke-LocalProfileStep -Phase PREPARE -Attempt {
            $output = & $native -NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File $validator -InstallDirectory $codeRoot -Mode Prepare -PublicOrigin $origin -RuntimeDirectory $runtime -ProgramJar "CheckingProgram-$version.jar" -JavaExecutable (Join-Path (Split-Path $java) 'java.exe') -SeedDirectory $package @identityArguments
            [pscustomobject]@{ ExitCode=$LASTEXITCODE; Output=$output }
        }
        $preparationExit = $ready.ExitCode
        $preparationCode = ConvertTo-LocalLaunchCode $ready.Output
        # These outcomes can only be emitted after Prepare has bound and checked the private home.
        if ($preparationCode -in @('LOCAL_VALID', 'LOCAL_JAVA_MEMORY', 'LOCAL_JAVA_FAILED', 'LOCAL_JAVA_TIMEOUT') -and
            [IO.File]::Exists((Join-Path $runtime 'leadya-local-install.txt'))) { $script:startupLog = Join-Path $runtime 'leadya-startup.log' }
        [pscustomobject]@{ ExitCode=$preparationExit; Code=$preparationCode }
    } | Out-Null
    $script:startupLog = Join-Path $runtime 'leadya-startup.log'
    # Refresh the copy in the chosen program folder from the verified package.
    & $native -NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File $validator -InstallDirectory $codeRoot -Mode Mirror -PublicOrigin $origin -ProgramJar "CheckingProgram-$version.jar" -SeedDirectory $package @identityArguments | Out-Null
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
    $prepareJava = Join-Path (Split-Path $java) 'java.exe'
    $nativeStart = New-Object Diagnostics.ProcessStartInfo
    $nativeStart.FileName = $prepareJava
    $nativeStart.WorkingDirectory = $runtime
    $nativeStart.UseShellExecute = $false
    $nativeStart.CreateNoWindow = $true
    $nativeStart.Arguments = '-Xms16m -Xmx64m -XX:-UsePerfData "-Dleadya.local.home=' + $runtime + '" -cp "' + $jar + '" pl.softwizard.sellbot.base.runtime.NativeLauncherSupport prepare-checking-base64 "' + $jar + '" "' + $runtime + '"'
    $preparedNative = Invoke-LocalLaunchPreparation -SessionAlive { Test-LocalLaunchOwner $launchOwner } -Attempt {
        Invoke-LocalLaunchBootstrap $nativeStart -NativePreparation
    }
    $branded = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($preparedNative.Output.Trim()))
    if (-not [IO.Path]::IsPathRooted($branded) -or -not [IO.File]::Exists($branded) -or
        -not $branded.StartsWith((Join-Path $runtime '.leadya-native') + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'LOCAL_NATIVE_LAUNCHER' }
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = $branded
    $start.WorkingDirectory = $runtime
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.EnvironmentVariables['PATH'] = (Join-Path (Split-Path $branded) 'app') + ';' + $env:PATH
    $start.Arguments = '--exclusive-start'
    $bootstrap = Invoke-LocalLaunchPreparation -Phase BOOTSTRAP -SessionAlive { Test-LocalLaunchOwner $launchOwner } -Attempt {
        Invoke-LocalLaunchBootstrap $start
    }
    Write-LocalLaunchEvent $bootstrap.State 'LOCAL_VALID'
    # A client update relaunches this launcher; the gate must not be held only to wait for the window.
    $launchMutex.ReleaseMutex()
    $launchMutex.Dispose()
    $launchMutex = $null
    if ($launchNotice -and $bootstrap.State -ceq 'START_REQUESTED') {
        try {
            $window = Wait-LocalClientWindow $launchNotice (Split-Path $java) $launchStarted 120000 $runtime
            Write-LocalLaunchEvent ('WINDOW_' + $window) $(if ($window -ceq 'TIMEOUT') { 'LOCAL_WINDOW_TIMEOUT' } else { 'LOCAL_VALID' })
        } catch { Write-Warning 'LeadYa window wait is unavailable' }
    }
    exit 0
} catch {
    $script:launchExitCode = 1
    $code = ConvertTo-LocalLaunchCode $_.Exception.Message
    Write-LocalLaunchEvent ($stage + '_FAILED') $code
    Write-Error ("LeadYa startup failed: " + $stage + ' ' + $code) -ErrorAction Continue
    [void](Stop-LocalLaunchNotice $launchNotice)
    if (-not $NoDialog -and $code -cne 'LOCAL_LAUNCH_SESSION_ENDED') {
        $language = 'en'
        try { $language = (Get-UICulture).TwoLetterISOLanguageName } catch { }
        $message = Get-LocalLaunchFailureMessage $stage $code $language
        Add-Type -AssemblyName System.Windows.Forms
        [Windows.Forms.MessageBox]::Show($message, 'LeadYa') | Out-Null
    }
    exit 1
} finally {
    $noticeReleased = Stop-LocalLaunchNotice $launchNotice
    if ($script:memoryNotice) { $script:memoryNotice.Dispose() }
    if ($launchMutex) { $launchMutex.ReleaseMutex(); $launchMutex.Dispose() }
    # PowerShell's own shutdown waits forever for an open window; after all cleanup, never leave a hung launcher.
    if (-not $noticeReleased) { [Environment]::Exit([int]$script:launchExitCode) }
}
