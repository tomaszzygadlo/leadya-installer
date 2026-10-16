param(
    [Parameter(Mandatory = $true)][string]$InstallDirectory,
    [ValidateSet('Runtime', 'Destination', 'Prepare', 'Installed', 'Installable', 'Publish', 'Package', 'PackagePrepare', 'PackageTemp', 'PackageSeed', 'Seed', 'Uninstall', 'CodeCleanup', 'Mirror', 'Links', 'Unlink', 'Jre', 'JrePrepare', 'JreCreate', 'JreProbe')][string]$Mode = 'Destination',
    [string]$PublicOrigin,
    [string]$ProgramJar,
    [string]$JavaExecutable,
    [string]$RuntimeDirectory,
    [string]$SeedDirectory,
    [string]$StagedJar
)

# Validate LOCAL custody; Prepare initializes only a new per-user runtime. Never repair ancestors.
$ErrorActionPreference = 'Stop'
$env:PSModulePath = Join-Path $PSHOME 'Modules'
try {
    $elevated = ([Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if ($elevated -and $Mode -in @('Prepare', 'Seed')) { throw 'LOCAL_ELEVATED_RUNTIME' }
    $root = [IO.Path]::GetFullPath($InstallDirectory).TrimEnd('\')
    if ($root -notmatch '^[A-Za-z]:\\' -or $root.Length -le 3) { throw 'LOCAL_PATH' }
    $originUri = [Uri]$PublicOrigin
    if (-not $originUri.IsAbsoluteUri -or ($originUri.Scheme -ne 'https' -and -not ($originUri.Scheme -eq 'http' -and $originUri.IsLoopback)) -or
        $originUri.UserInfo -or $originUri.Query -or $originUri.Fragment -or $originUri.AbsolutePath -ne '/' -or $PublicOrigin.Contains("`n") -or $PublicOrigin.Contains("`r")) { throw 'LOCAL_ORIGIN' }
    $digest = [Security.Cryptography.SHA256]::Create()
    try { $id = ([BitConverter]::ToString($digest.ComputeHash([Text.Encoding]::UTF8.GetBytes($root.ToUpperInvariant() + "`n" + $PublicOrigin)))).Replace('-', '').ToLowerInvariant() }
    finally { $digest.Dispose() }
    $candidates = @(
        (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) ('LeadYa\installations\' + $id)),
        (Join-Path ([Environment]::GetFolderPath('UserProfile')) ('.leadya-client\installations\' + $id))
    )
    $operator = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $privateOwners = @($operator, 'S-1-5-18', 'S-1-5-32-544')
    $ancestorOwners = $privateOwners + 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464'
    $trustedOwners = @('S-1-5-18', 'S-1-5-32-544', 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464')
    $programFiles = if ($env:ProgramW6432) { $env:ProgramW6432 } else { [Environment]::GetFolderPath('ProgramFiles') }
    $packageParent = Join-Path $programFiles 'LeadYaInstallerPackages'
    $package = Join-Path $packageParent $id
    $readonly = [long]([Security.AccessControl.FileSystemRights]::ReadAndExecute) -bor
        [long]([Security.AccessControl.FileSystemRights]::Synchronize) -bor
        [long]([Security.AccessControl.FileSystemRights]::AppendData)

    function Assert-Custody([string]$Path, [bool]$Private) {
        $item = Get-Item -LiteralPath $Path -Force
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'LOCAL_REPARSE' }
        $acl = Get-Acl -LiteralPath $Path
        $owners = if ($Private) { $privateOwners } else { $ancestorOwners }
        if ($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -notin $owners) { throw 'LOCAL_OWNER' }
        $rules = $acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])
        if ($rules.Count -eq 0) { throw 'LOCAL_EMPTY_ACL' }
        foreach ($rule in $rules) {
            if ($rule.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly) { continue }
            if ($rule.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow) { throw 'LOCAL_DENY_ACL' }
            $sid = $rule.IdentityReference.Value
            if ($Private -and $sid -notin $privateOwners) { throw 'LOCAL_PRIVATE_ACL' }
            if (-not $Private -and $sid -notin $ancestorOwners -and
                (([long]$rule.FileSystemRights -band (-bnot $readonly)) -ne 0)) { throw 'LOCAL_ANCESTOR_WRITABLE' }
        }
    }

    function Assert-RuntimeAncestors([string]$RuntimePath) {
        for ($parent = [IO.Directory]::GetParent($RuntimePath); $null -ne $parent; $parent = $parent.Parent) {
            if (Test-Path -LiteralPath $parent.FullName) { Assert-Custody $parent.FullName $false }
        }
    }
    function Assert-PackagePath([string]$Path, [bool]$Ancestor = $false) {
        $item = Get-Item -LiteralPath $Path -Force
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'LOCAL_REPARSE' }
        $acl = Get-Acl -LiteralPath $Path
        if ($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -notin $trustedOwners) { throw 'LOCAL_PACKAGE_OWNER' }
        $allowed = [long]([Security.AccessControl.FileSystemRights]::ReadAndExecute) -bor [long]([Security.AccessControl.FileSystemRights]::Synchronize)
        if ($Ancestor) { $allowed = $allowed -bor [long]([Security.AccessControl.FileSystemRights]::AppendData) }
        foreach ($rule in $acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
            if ($rule.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly) { continue }
            if ($rule.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow) { throw 'LOCAL_PACKAGE_ACL' }
            if ($rule.IdentityReference.Value -notin $trustedOwners -and (([long]$rule.FileSystemRights -band (-bnot $allowed)) -ne 0)) {
                throw 'LOCAL_PACKAGE_WRITABLE'
            }
        }
    }
    function Assert-PackageAncestors {
        for ($parent = [IO.Directory]::GetParent($package); $null -ne $parent; $parent = $parent.Parent) {
            if (Test-Path -LiteralPath $parent.FullName) { Assert-PackagePath $parent.FullName ($parent.FullName -ine $packageParent) }
        }
    }
    function New-PackageFileStream([string]$Path) {
        # Set owner and DACL at creation: a filtered token of the installing user never owns the stage.
        $security = New-Object Security.AccessControl.FileSecurity
        $security.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))
        $security.SetAccessRuleProtection($true, $false)
        foreach ($sid in @('S-1-5-18', 'S-1-5-32-544', 'S-1-5-32-545')) {
            $rights = if ($sid -eq 'S-1-5-32-545') { 'ReadAndExecute' } else { 'FullControl' }
            $security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($sid), $rights, 'Allow'))
        }
        return [IO.FileStream]::new($Path, [IO.FileMode]::CreateNew, [Security.AccessControl.FileSystemRights]::Write,
            [IO.FileShare]::None, 4096, [IO.FileOptions]::None, $security)
    }
    if ($Mode -eq 'PackageTemp') {
        Assert-PackageAncestors
        Assert-PackagePath $package
        $temporary = Join-Path $package ('.leadya-download-' + [Guid]::NewGuid().ToString('N') + '.tmp')
        $stream = New-PackageFileStream $temporary
        $stream.Dispose()
        Assert-PackagePath $temporary
        Write-Output $temporary
        exit 0
    }
    if ($Mode -eq 'Uninstall') {
        if ([IO.Path]::GetDirectoryName($root) -ine $packageParent -or [IO.Path]::GetFileName($root) -notmatch '^[0-9a-f]{64}$') { throw 'LOCAL_PACKAGE_BINDING' }
        $package = $root
        Assert-PackageAncestors
        Assert-PackagePath $package
        foreach ($relative in @('leadya-code-home.txt', 'leadya-local-origin.txt', 'checking_program_version.txt')) {
            $file = Join-Path $package $relative
            Assert-PackagePath $file
            $item = Get-Item -LiteralPath $file -Force
            if ($item.PSIsContainer -or $item.Length -gt 65536) { throw 'LOCAL_PACKAGE_BINDING' }
        }
        $codeRoot = [IO.File]::ReadAllText((Join-Path $package 'leadya-code-home.txt')).TrimEnd("`r", "`n")
        $codeRoot = [IO.Path]::GetFullPath($codeRoot).TrimEnd('\')
        $recordedOrigin = [IO.File]::ReadAllText((Join-Path $package 'leadya-local-origin.txt')).TrimEnd("`r", "`n")
        $recordedVersion = [IO.File]::ReadAllText((Join-Path $package 'checking_program_version.txt')).TrimEnd("`r", "`n")
        if ($codeRoot -notmatch '^[A-Za-z]:\\' -or $codeRoot.Length -le 3 -or $recordedOrigin -cne $PublicOrigin -or
            $recordedVersion -notmatch '^[A-Za-z0-9.]+$') { throw 'LOCAL_PACKAGE_BINDING' }
        $hasher = [Security.Cryptography.SHA256]::Create()
        try { $expected = ([BitConverter]::ToString($hasher.ComputeHash([Text.Encoding]::UTF8.GetBytes($codeRoot.ToUpperInvariant() + "`n" + $PublicOrigin)))).Replace('-', '').ToLowerInvariant() }
        finally { $hasher.Dispose() }
        if ($expected -cne [IO.Path]::GetFileName($package)) { throw 'LOCAL_PACKAGE_BINDING' }
        Write-Output $codeRoot
        exit 0
    }
    if ($Mode -eq 'CodeCleanup') {
        # An untrusted custom folder can have been replaced since installation. Preserve that copy.
        for ($path = $root; $null -ne $path; $path = [IO.Path]::GetDirectoryName($path)) {
            if (Test-Path -LiteralPath $path) { Assert-PackagePath $path $true }
        }
        Write-Output 'LOCAL_VALID'
        exit 0
    }
    if ($Mode -in @('Package', 'PackagePrepare')) {
        Assert-PackageAncestors
        if ($Mode -eq 'PackagePrepare') {
            foreach ($directory in @($packageParent, $package)) {
                if (Test-Path -LiteralPath $directory) { Assert-PackagePath $directory; continue }
                $acl = New-Object Security.AccessControl.DirectorySecurity
                $acl.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))
                $acl.SetAccessRuleProtection($true, $false)
                foreach ($sid in @('S-1-5-18', 'S-1-5-32-544', 'S-1-5-32-545')) {
                    $rights = if ($sid -eq 'S-1-5-32-545') { 'ReadAndExecute' } else { 'FullControl' }
                    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
                        [Security.Principal.SecurityIdentifier]::new($sid), $rights, 'ContainerInherit,ObjectInherit', 'None', 'Allow'))
                }
                [IO.Directory]::CreateDirectory($directory, $acl) | Out-Null
                Assert-PackagePath $directory
            }
            foreach ($relative in @('LaunchLocalLeadYa.ps1', 'ValidateLocalInstall.ps1', 'LeadyaCheckingProgram.bat', 'Uninstall.exe', 'leadya-code-home.txt', 'leadya-local-origin.txt')) {
                $file = Join-Path $package $relative
                if (Test-Path -LiteralPath $file) { Assert-PackagePath $file }
                else { $stream = New-PackageFileStream $file; $stream.Dispose(); Assert-PackagePath $file }
            }
        }
        if (Test-Path -LiteralPath $package) { Assert-PackagePath $package }
        Write-Output $package
        exit 0
    }
    if ($Mode -in @('Mirror', 'Links', 'Unlink') -and -not $SeedDirectory) { throw 'LOCAL_PACKAGE_REQUIRED' }
    if ($SeedDirectory) {
        if ([IO.Path]::GetFullPath($SeedDirectory).TrimEnd('\') -ine $package) { throw 'LOCAL_PACKAGE_BINDING' }
        Assert-PackageAncestors
        Assert-PackagePath $package
    }
    function New-ProtectedDirectory([string]$Path) {
        if (Test-Path -LiteralPath $Path) { Assert-PackagePath $Path; return }
        $acl = New-Object Security.AccessControl.DirectorySecurity
        $acl.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))
        $acl.SetAccessRuleProtection($true, $false)
        foreach ($sid in @('S-1-5-18', 'S-1-5-32-544', 'S-1-5-32-545')) {
            $rights = if ($sid -eq 'S-1-5-32-545') { 'ReadAndExecute' } else { 'FullControl' }
            $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($sid), $rights, 'ContainerInherit,ObjectInherit', 'None', 'Allow'))
        }
        [IO.Directory]::CreateDirectory($Path, $acl) | Out-Null
        Assert-PackagePath $Path
    }
    function Assert-ProtectedAncestors([string]$Path) {
        for ($parent = $Path; $null -ne $parent; $parent = [IO.Path]::GetDirectoryName($parent)) {
            if (Test-Path -LiteralPath $parent) { Assert-PackagePath $parent $true }
        }
    }
    function Publish-AtomicFile([string]$Source, [string]$Destination) {
        Assert-PackagePath $Source
        $temporary = Join-Path ([IO.Path]::GetDirectoryName($Destination)) ('.leadya-copy-' + [Guid]::NewGuid().ToString('N') + '.tmp')
        try {
            $sourceHandle = [IO.File]::Open($Source, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
            try {
                $output = if ($elevated) { New-PackageFileStream $temporary } else {
                    [IO.File]::Open($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
                }
                try { $sourceHandle.CopyTo($output); $output.Flush($true) } finally { $output.Dispose() }
            } finally { $sourceHandle.Dispose() }
            if ([IO.File]::Exists($Destination)) { [IO.File]::Replace($temporary, $Destination, [NullString]::Value) }
            else { [IO.File]::Move($temporary, $Destination) }
        } finally { if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
    }
    function Assert-SharedJre([string]$Preparation = '') {
        $sharedJavaParent = Join-Path $programFiles 'Java'
        $sharedJre = Join-Path $sharedJavaParent 'jdk-17.0.9+9-jre'
        Assert-ProtectedAncestors $sharedJre
        if ($Preparation -in @('JrePrepare', 'JreCreate')) { New-ProtectedDirectory $sharedJavaParent }
        if ($Preparation -eq 'JreCreate') { New-ProtectedDirectory $sharedJre }
        Assert-ProtectedAncestors $sharedJre
        if ([IO.Directory]::Exists($sharedJre)) {
            # Inspect each directory before descending; never follow a reparse subtree.
            $pending = [Collections.Generic.Stack[string]]::new()
            $pending.Push($sharedJre)
            while ($pending.Count -gt 0) {
                $directory = $pending.Pop()
                Assert-PackagePath $directory
                foreach ($entry in Get-ChildItem -LiteralPath $directory -Force) {
                    Assert-PackagePath $entry.FullName
                    if ($entry.PSIsContainer) { $pending.Push($entry.FullName) }
                }
            }
        }
    }
    function New-LocalJavaStartInfo([string]$Executable, [string]$Arguments, [string]$WorkingDirectory) {
        $windows = [Environment]::GetFolderPath('Windows')
        if (-not $windows -or -not [IO.Directory]::Exists($WorkingDirectory)) { throw 'LOCAL_JAVA_ENVIRONMENT' }
        $system = Join-Path $windows 'System32'
        $info = New-Object Diagnostics.ProcessStartInfo
        $info.FileName = $Executable
        $info.Arguments = '-XX:-UsePerfData ' + $Arguments
        $info.UseShellExecute = $false
        $info.CreateNoWindow = $true
        $info.RedirectStandardOutput = $true
        $info.RedirectStandardError = $true
        $info.WorkingDirectory = $WorkingDirectory
        # Construct the child environment: JVM/CLR loader options and arbitrary PATH entries never enter it.
        # Known-folder APIs provide profile/Windows paths; do not copy values from the caller's environment.
        $info.EnvironmentVariables.Clear()
        $info.EnvironmentVariables['SystemRoot'] = $windows
        $info.EnvironmentVariables['WINDIR'] = $windows
        $info.EnvironmentVariables['SystemDrive'] = [IO.Path]::GetPathRoot($windows).TrimEnd('\')
        $info.EnvironmentVariables['ComSpec'] = Join-Path $system 'cmd.exe'
        $info.EnvironmentVariables['PATH'] = ([IO.Path]::GetDirectoryName($Executable)) + ';' + $system + ';' + $windows
        $info.EnvironmentVariables['USERPROFILE'] = [Environment]::GetFolderPath('UserProfile')
        $info.EnvironmentVariables['LOCALAPPDATA'] = [Environment]::GetFolderPath('LocalApplicationData')
        $info.EnvironmentVariables['APPDATA'] = [Environment]::GetFolderPath('ApplicationData')
        $info.EnvironmentVariables['TEMP'] = $WorkingDirectory
        $info.EnvironmentVariables['TMP'] = $WorkingDirectory
        return $info
    }
    function Invoke-JavaProbe([string]$Arguments, [int]$Timeout) {
        if ($elevated) {
            $expectedJava = Join-Path $programFiles 'Java\jdk-17.0.9+9-jre\bin\java.exe'
            if ([IO.Path]::GetFullPath($JavaExecutable) -ine $expectedJava) { throw 'LOCAL_JAVA_BINDING' }
            Assert-SharedJre
            Assert-PackagePath $JavaExecutable
            Assert-PackageAncestors
            Assert-PackagePath $package
            $windows = [Environment]::GetFolderPath('Windows')
            Assert-ProtectedAncestors $windows
            Assert-ProtectedAncestors (Join-Path $windows 'System32')
        }
        $probe = New-Object Diagnostics.Process
        $probe.StartInfo = New-LocalJavaStartInfo $JavaExecutable $Arguments $package
        try {
            if (-not $probe.Start()) { throw 'LOCAL_JAVA_FAILED' }
            if (-not $probe.WaitForExit($Timeout)) { $probe.Kill(); $probe.WaitForExit(); throw 'LOCAL_JAVA_TIMEOUT' }
            if ($probe.ExitCode -ne 0) { throw 'LOCAL_JAVA_FAILED' }
        } finally { $probe.Dispose() }
    }
    if ($Mode -in @('Jre', 'JrePrepare', 'JreCreate', 'JreProbe')) {
        Assert-SharedJre $Mode
        if ($Mode -eq 'JreProbe') { Invoke-JavaProbe '-version' 15000 }
        Write-Output 'LOCAL_VALID'
        exit 0
    }
    if ($Mode -eq 'Mirror') {
        if ($ProgramJar -notmatch '^CheckingProgram-[A-Za-z0-9.]+\.jar$') { throw 'LOCAL_JAR_NAME' }
        if ($elevated) {
            try { Assert-ProtectedAncestors $root } catch { Write-Output 'LOCAL_MIRROR_DEFERRED'; exit 0 }
            New-ProtectedDirectory $root
            Assert-ProtectedAncestors $root
        } else {
            for ($path = $root; $null -ne $path; $path = [IO.Path]::GetDirectoryName($path)) {
                if ((Test-Path -LiteralPath $path) -and ((Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'LOCAL_REPARSE' }
            }
            [IO.Directory]::CreateDirectory($root) | Out-Null
        }
        foreach ($relative in @($ProgramJar, 'LeadyaCheckingProgram.bat', 'LaunchLocalLeadYa.ps1', 'ValidateLocalInstall.ps1', 'leadya-code-home.txt', 'leadya-local-origin.txt', 'checking_program_version.txt')) {
            $source = Join-Path $package $relative
            if ([IO.File]::Exists($source)) { Publish-AtomicFile $source (Join-Path $root $relative) }
        }
        Write-Output 'LOCAL_VALID'
        exit 0
    }
    if ($Mode -in @('Links', 'Unlink')) {
        if (-not $elevated) { throw 'LOCAL_ADMIN_REQUIRED' }
        $programs = [Environment]::GetFolderPath('CommonPrograms')
        Assert-ProtectedAncestors $programs
        $menu = Join-Path $programs 'LeadYa'
        if ($Mode -eq 'Links') { New-ProtectedDirectory $menu }
        $destinations = @((Join-Path $menu 'Leadya.lnk'), (Join-Path $menu 'UninstallLeadya.lnk'))
        $desktop = [Environment]::GetFolderPath('CommonDesktopDirectory')
        try { Assert-ProtectedAncestors $desktop; $destinations += Join-Path $desktop 'Leadya.lnk' } catch { }
        $shell = New-Object -ComObject WScript.Shell
        foreach ($destination in $destinations) {
            $parent = [IO.Path]::GetDirectoryName($destination)
            if (-not [IO.Directory]::Exists($parent)) { continue }
            Assert-ProtectedAncestors $parent
            $target = Join-Path $package $(if ([IO.Path]::GetFileName($destination) -eq 'UninstallLeadya.lnk') { 'Uninstall.exe' } else { 'LeadyaCheckingProgram.bat' })
            if ($Mode -eq 'Unlink') {
                if ([IO.File]::Exists($destination) -and $shell.CreateShortcut($destination).TargetPath -ieq $target) { [IO.File]::Delete($destination) }
                continue
            }
            $temporary = Join-Path $package ('.leadya-link-' + [Guid]::NewGuid().ToString('N') + '.lnk')
            try {
                $stream = New-PackageFileStream $temporary; $stream.Dispose()
                $link = $shell.CreateShortcut($temporary)
                $link.TargetPath = $target; $link.WorkingDirectory = $package; $link.WindowStyle = 7; $link.Save()
                Publish-AtomicFile $temporary $destination
            } finally { if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
        }
        Write-Output 'LOCAL_VALID'
        exit 0
    }
    function Assert-LocalMarker([string]$RuntimePath) {
        $markerPath = Join-Path $RuntimePath 'leadya-local-install.txt'
        Assert-Custody $markerPath $true
        if ((Get-Item -LiteralPath $markerPath).Length -gt 65536) { throw 'LOCAL_MARKER_INVALID' }
        $marker = [IO.File]::ReadAllLines($markerPath)
        if ($marker.Count -ne 3 -or $marker[0] -cne 'LOCAL' -or $marker[1] -ine $RuntimePath -or $marker[2] -cne $PublicOrigin) { throw 'LOCAL_MARKER_MISMATCH' }
    }
    if ($Mode -eq 'Runtime') {
        $binding = Join-Path $root 'leadya-runtime-home.txt'
        if ([IO.File]::Exists($binding) -and (Get-Item -LiteralPath $binding).Length -le 4096) {
            $previous = [IO.File]::ReadAllText($binding).TrimEnd("`r", "`n")
            if ($previous -in $candidates) { $candidates = @($previous) + @($candidates | Where-Object { $_ -ine $previous }) }
        }
        foreach ($candidate in $candidates) {
            try { Assert-RuntimeAncestors $candidate; Write-Output $candidate; exit 0 }
            catch { continue }
        }
        throw 'LOCAL_NO_PRIVATE_PROFILE'
    }
    if ($Mode -in @('Installed', 'Installable', 'Publish', 'Prepare', 'Seed') -and -not $SeedDirectory) { throw 'LOCAL_PACKAGE_REQUIRED' }
    if ($RuntimeDirectory -notin $candidates) { throw 'LOCAL_RUNTIME_BINDING' }
    $runtime = $RuntimeDirectory
    if ($Mode -eq 'PackageSeed') {
        Assert-PackageAncestors
        Assert-PackagePath $package
        if ($ProgramJar -notmatch '^CheckingProgram-[A-Za-z0-9.]+\.jar$' -or
            [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($StagedJar)) -ine $package) { throw 'LOCAL_JAR_NAME' }
        Assert-PackagePath $StagedJar
        $destination = Join-Path $package $ProgramJar
        if (Test-Path -LiteralPath $destination) { Assert-PackagePath $destination }
        $sourceStream = [IO.File]::Open($StagedJar, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        try {
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            $archive = [IO.Compression.ZipFile]::OpenRead($StagedJar)
            try {
                foreach ($entry in @('pl/softwizard/sellbot/checking/program/CheckingProgram.class', 'pl/softwizard/sellbot/checking/program/LocalInstallVerifier.class')) {
                    if ($null -eq $archive.GetEntry($entry)) { throw 'LOCAL_JAR_INVALID' }
                }
            } finally { $archive.Dispose() }
            $equal = [IO.File]::Exists($destination) -and (Get-FileHash -InputStream $sourceStream -Algorithm SHA256).Hash -eq (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash
            if (-not $equal) {
                $temporary = Join-Path $package ('.leadya-seed-' + [Guid]::NewGuid().ToString('N') + '.tmp')
                try {
                    $sourceStream.Position = 0
                    $targetStream = New-PackageFileStream $temporary
                    try { $sourceStream.CopyTo($targetStream); $targetStream.Flush($true) } finally { $targetStream.Dispose() }
                    if ([IO.File]::Exists($destination)) { [IO.File]::Replace($temporary, $destination, [NullString]::Value) }
                    else { [IO.File]::Move($temporary, $destination) }
                } finally { if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
            }
        } finally { $sourceStream.Dispose() }
        if ([IO.File]::Exists($StagedJar)) { [IO.File]::Delete($StagedJar) }
        Assert-PackagePath $destination
        Write-Output 'LOCAL_VALID'
        exit 0
    }
    $publishVersion = $Mode -eq 'Publish'
    if ($publishVersion) { $Mode = 'Installable' }
    if ($Mode -in @('Prepare', 'Seed')) {
        Assert-RuntimeAncestors $runtime
        if (-not (Test-Path -LiteralPath (Join-Path $runtime 'leadya-local-install.txt'))) {
            if (Test-Path -LiteralPath $runtime) {
                Assert-Custody $runtime $true
                if (@(Get-ChildItem -LiteralPath $runtime -Force).Count -ne 0) { throw 'LOCAL_UNBOUND_RUNTIME' }
            } else {
                [IO.Directory]::CreateDirectory($runtime) | Out-Null
                $acl = Get-Acl -LiteralPath $runtime
                if ($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -notin $privateOwners) { throw 'LOCAL_OWNER' }
                $acl.SetAccessRuleProtection($true, $false)
                foreach ($rule in @($acl.GetAccessRules($true, $false, [Security.Principal.SecurityIdentifier]))) { $acl.RemoveAccessRuleSpecific($rule) }
                foreach ($sid in $privateOwners) {
                    $rule = New-Object Security.AccessControl.FileSystemAccessRule(
                        ([Security.Principal.SecurityIdentifier]::new($sid)), 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
                    $acl.AddAccessRule($rule)
                }
                Set-Acl -LiteralPath $runtime -AclObject $acl
            }
            Assert-Custody $runtime $true
            $stream = [IO.File]::Open((Join-Path $runtime 'leadya-local-install.txt'), [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
            try {
                $body = [Text.Encoding]::UTF8.GetBytes("LOCAL`n$runtime`n$PublicOrigin`n")
                $stream.Write($body, 0, $body.Length)
            } finally { $stream.Dispose() }
        }
        Assert-Custody $runtime $true
        Assert-LocalMarker $runtime
        if (-not $SeedDirectory) { throw 'LOCAL_PACKAGE_REQUIRED' }
        $seed = Join-Path $SeedDirectory $ProgramJar
        Assert-PackagePath $seed
        if ($ProgramJar -notmatch '^CheckingProgram-[A-Za-z0-9.]+\.jar$' -or -not [IO.File]::Exists($seed)) { throw 'LOCAL_JAR_NAME' }
        $runtimeJar = Join-Path $runtime $ProgramJar
        if ($Mode -eq 'Seed' -or -not [IO.File]::Exists($runtimeJar)) {
            if (Test-Path -LiteralPath $runtimeJar) { Assert-Custody $runtimeJar $true }
            $temporary = Join-Path $runtime ('.leadya-runtime-seed-' + [Guid]::NewGuid().ToString('N') + '.tmp')
            try {
                $sourceStream = [IO.File]::Open($seed, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
                try {
                    $targetStream = [IO.File]::Open($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
                    try { $sourceStream.CopyTo($targetStream); $targetStream.Flush($true) } finally { $targetStream.Dispose() }
                } finally { $sourceStream.Dispose() }
                if ([IO.File]::Exists($runtimeJar)) { [IO.File]::Replace($temporary, $runtimeJar, [NullString]::Value) }
                else { [IO.File]::Move($temporary, $runtimeJar) }
            } finally { if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
        }
        [IO.Directory]::CreateDirectory((Join-Path $runtime 'bot_files')) | Out-Null
        if ($Mode -eq 'Seed') { Write-Output 'LOCAL_VALID'; exit 0 }
        $Mode = 'Installed'
    }

    # Code may live in a user-selected location. Its ancestors must be ordinary directories.
    for ($codePath = $root; $null -ne $codePath; $codePath = [IO.Path]::GetDirectoryName($codePath)) {
        if (Test-Path -LiteralPath $codePath) {
            $item = Get-Item -LiteralPath $codePath -Force
            if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'LOCAL_REPARSE' }
        }
    }
    # Only the per-user runtime home contains credentials, profiles and mutable lifecycle state.
    $bound = Test-Path -LiteralPath (Join-Path $runtime 'leadya-local-install.txt')
    if (Test-Path -LiteralPath $runtime) {
        if (-not (Get-Item -LiteralPath $runtime -Force).PSIsContainer) { throw 'LOCAL_NOT_DIRECTORY' }
        if ($bound -or $Mode -in @('Installed', 'Installable')) { Assert-Custody $runtime $true }
        elseif ((Get-Item -LiteralPath $runtime -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'LOCAL_REPARSE' }
    } elseif ($Mode -eq 'Installed') { throw 'LOCAL_HOME_MISSING' }
    Assert-RuntimeAncestors $runtime
    if ($Mode -in @('Installed', 'Installable')) {
        if (-not $bound -and $Mode -eq 'Installed') { throw 'LOCAL_MARKER_MISSING' }
        if (-not $bound -and [IO.Directory]::Exists($runtime) -and @(Get-ChildItem -LiteralPath $runtime -Force).Count -ne 0) { throw 'LOCAL_UNBOUND_RUNTIME' }
        foreach ($relative in @('leadya-local-install.txt', 'bot_files', '.leadya-agent-runtime', 'bot_files\bot.properties', 'bot.properties.backup')) {
            $path = Join-Path $runtime $relative
            if (Test-Path -LiteralPath $path) {
                Assert-Custody $path $true
                $directory = $relative -in @('bot_files', '.leadya-agent-runtime')
                if ((Get-Item -LiteralPath $path -Force).PSIsContainer -ne $directory) { throw 'LOCAL_PATH_TYPE' }
            }
        }
        if ($bound) { Assert-LocalMarker $runtime }
        if ($ProgramJar -notmatch '^CheckingProgram-[A-Za-z0-9.]+\.jar$') { throw 'LOCAL_JAR_NAME' }
        $payloadRoot = if ($SeedDirectory) { $SeedDirectory } else { $root }
        if ($SeedDirectory) {
            foreach ($relative in @('leadya-code-home.txt', 'leadya-local-origin.txt')) { Assert-PackagePath (Join-Path $payloadRoot $relative) }
            if ([IO.File]::ReadAllText((Join-Path $payloadRoot 'leadya-code-home.txt')).TrimEnd("`r", "`n") -ine $root -or
                [IO.File]::ReadAllText((Join-Path $payloadRoot 'leadya-local-origin.txt')).TrimEnd("`r", "`n") -cne $PublicOrigin) { throw 'LOCAL_PACKAGE_BINDING' }
        }
        foreach ($relative in @($ProgramJar, 'LeadyaCheckingProgram.bat', 'LaunchLocalLeadYa.ps1', 'Uninstall.exe')) {
            $path = Join-Path $payloadRoot $relative
            $item = Get-Item -LiteralPath $path -Force
            if ($item.PSIsContainer -or $item.Length -eq 0 -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'LOCAL_PAYLOAD_MISSING' }
            if ($SeedDirectory) { Assert-PackagePath $path }
        }
        $runtimeJar = Join-Path $runtime $ProgramJar
        if ($Mode -eq 'Installed') {
            Assert-Custody $runtimeJar $true
            if ((Get-Item -LiteralPath $runtimeJar -Force).PSIsContainer) { throw 'LOCAL_RUNTIME_PAYLOAD' }
        }
        # Elevated validation executes only the admin-owned package, held against replacement until exit.
        $executionJar = Join-Path $payloadRoot $ProgramJar
        $lockedJar = [IO.File]::Open($executionJar, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        try {
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            $archive = [IO.Compression.ZipFile]::OpenRead($executionJar)
            try {
                if ($null -eq $archive.GetEntry('pl/softwizard/sellbot/checking/program/CheckingProgram.class')) { throw 'LOCAL_JAR_INVALID' }
            } finally { $archive.Dispose() }
            if ($Mode -eq 'Installed' -and (Get-FileHash -InputStream $lockedJar -Algorithm SHA256).Hash -ne
                (Get-FileHash -LiteralPath $runtimeJar -Algorithm SHA256).Hash) { throw 'LOCAL_RUNTIME_PAYLOAD' }
            if (-not [IO.File]::Exists($JavaExecutable)) { throw 'LOCAL_JAVA_MISSING' }
            Invoke-JavaProbe '-version' 15000
            $policy = if ($Mode -eq 'Installable') { ' --allow-uninitialized' } else { '' }
            Invoke-JavaProbe ('-cp "' + $executionJar + '" pl.softwizard.sellbot.checking.program.LocalInstallVerifier "' + $runtime + '" "' + $PublicOrigin + '"' + $policy) 45000
        } finally { $lockedJar.Dispose() }
        if ($publishVersion) {
            $version = $ProgramJar.Substring('CheckingProgram-'.Length, $ProgramJar.Length - 'CheckingProgram-'.Length - '.jar'.Length)
            foreach ($publishRoot in @($payloadRoot)) {
              $temporary = Join-Path $publishRoot ('.leadya-version-' + [Guid]::NewGuid().ToString('N') + '.tmp')
              try {
                $stream = if ($publishRoot -ieq $package) { New-PackageFileStream $temporary } else {
                    [IO.File]::Open($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
                }
                try {
                    $body = [Text.Encoding]::ASCII.GetBytes($version + "`r`n")
                    $stream.Write($body, 0, $body.Length)
                    $stream.Flush($true)
                } finally { $stream.Dispose() }
                $versionFile = Join-Path $publishRoot 'checking_program_version.txt'
                if ([IO.File]::Exists($versionFile)) { [IO.File]::Replace($temporary, $versionFile, [NullString]::Value) }
                else { [IO.File]::Move($temporary, $versionFile) }
              } finally { if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
            }
        }
    }
    Write-Output 'LOCAL_VALID'
    exit 0
} catch {
    # Never print configuration, credentials or arbitrary exception content.
    $code = [string]$_.Exception.Message
    if ($code -notmatch '^LOCAL_[A-Z_]+$') { $code = 'LOCAL_VALIDATION_FAILED' }
    Write-Output $code
    exit 12
}
