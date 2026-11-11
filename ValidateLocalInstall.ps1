param(
    [Parameter(Mandatory = $true)][string]$InstallDirectory,
    [ValidateSet('Runtime', 'Destination', 'Prepare', 'Installed', 'Installable', 'Publish', 'Package', 'PackagePrepare', 'PackageTemp', 'PackageSeed', 'Seed', 'Uninstall', 'CodeCleanup', 'Mirror', 'Links', 'Unlink', 'Jre', 'JrePrepare', 'JreCreate', 'JreProbe', 'JreVerify', 'Adopt', 'AdoptGuard', 'Identity')][string]$Mode = 'Destination',
    [string]$PublicOrigin,
    [string]$ProgramJar,
    [string]$JavaExecutable,
    [string]$RuntimeDirectory,
    [string]$SeedDirectory,
    [string]$StagedJar,
    [bool]$EncodedOutput = $false,
    [string]$InputPath,
    [string]$IdentityRoot
)

# Validate LOCAL custody; Prepare initializes only a new per-user runtime. Never repair ancestors.
function Get-LocalJvmFailureCode([string]$Diagnostic) {
    # Keep in sync with the standalone launcher; neither caller logs the captured text.
    if ($Diagnostic -match '(?i)insufficient memory for the Java Runtime Environment|Could not reserve enough space|Native memory allocation .* failed|OutOfMemoryError|paging file is too small|os::commit_memory.*(1455|error=8)') { return 'LOCAL_JAVA_MEMORY' }
    return 'LOCAL_JAVA_FAILED'
}

$ErrorActionPreference = 'Stop'
$env:PSModulePath = Join-Path $PSHOME 'Modules'
function Write-LocalValidationResult([string]$Value) {
    if ($EncodedOutput) {
        [Console]::Out.Write('LYV1:' + [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Value)) + ':END')
    } else { Write-Output $Value }
}
try {
    $elevated = ([Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    # Everything here belongs to one ordinary user; an elevated token could be another account.
    if ($elevated) { throw 'LOCAL_ELEVATED_RUNTIME' }
    $root = [IO.Path]::GetFullPath($InstallDirectory).TrimEnd('\')
    if ($root -notmatch '^[A-Za-z]:\\' -or $root.Length -le 3) { throw 'LOCAL_PATH' }
    $originUri = [Uri]$PublicOrigin
    if (-not $originUri.IsAbsoluteUri -or ($originUri.Scheme -ne 'https' -and -not ($originUri.Scheme -eq 'http' -and $originUri.IsLoopback)) -or
        $originUri.UserInfo -or $originUri.Query -or $originUri.Fragment -or $originUri.AbsolutePath -ne '/' -or $PublicOrigin.Contains("`n") -or $PublicOrigin.Contains("`r")) { throw 'LOCAL_ORIGIN' }
    function ConvertTo-IdentityRoot([string]$Path) {
        $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
        if ($full -notmatch '^[A-Za-z]:\\' -or $full.Length -le 3) { throw 'LOCAL_PATH' }
        return $full
    }
    function Get-InstallationId([string]$Identity) {
        $digest = [Security.Cryptography.SHA256]::Create()
        try { return ([BitConverter]::ToString($digest.ComputeHash([Text.Encoding]::UTF8.GetBytes($Identity.ToUpperInvariant() + "`n" + $PublicOrigin)))).Replace('-', '').ToLowerInvariant() }
        finally { $digest.Dispose() }
    }
    function Get-RuntimeCandidates([string]$InstallationId) {
        return @(
            (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) ('LeadYa\installations\' + $InstallationId)),
            (Join-Path ([Environment]::GetFolderPath('UserProfile')) ('.leadya-client\installations\' + $InstallationId))
        )
    }
    # A computer adopted from the old machine-wide installer keeps the identity of its original program folder.
    $id = Get-InstallationId $(if ($IdentityRoot) { ConvertTo-IdentityRoot $IdentityRoot } else { $root })
    $candidates = Get-RuntimeCandidates $id
    $operator = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $privateOwners = @($operator, 'S-1-5-18', 'S-1-5-32-544')
    $ancestorOwners = $privateOwners + 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464'
    $trustedOwners = $ancestorOwners
    # Only the detection of an old machine-wide installation still looks at Program Files.
    $programFiles = if ($env:ProgramW6432) { $env:ProgramW6432 } else { [Environment]::GetFolderPath('ProgramFiles') }
    $perUserRoot = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'LeadYa'
    $packageParent = Join-Path $perUserRoot 'packages'
    $package = Join-Path $packageParent $id
    $jreArchiveSha256 = 'fe4656bd78fb09812dc38c49da777f79cc33e7ee435a254be82f9e7f40d9d117'
    $readonly = [long]([Security.AccessControl.FileSystemRights]::ReadAndExecute) -bor
        [long]([Security.AccessControl.FileSystemRights]::Synchronize) -bor
        [long]([Security.AccessControl.FileSystemRights]::AppendData)
    # Windows grants an AppContainer package or capability SID (S-1-15-2-*, S-1-15-3-*) only together with
    # the same access for the process's ordinary user and group SIDs. Such an entry never adds a writer to
    # shared ancestors beyond the ordinary entries checked here; private homes still refuse it.

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
            if (-not $Private -and $sid -notin $ancestorOwners -and $sid -notmatch '^S-1-15-[23]-' -and
                (([long]$rule.FileSystemRights -band (-bnot $readonly)) -ne 0)) { throw 'LOCAL_ANCESTOR_WRITABLE' }
        }
    }

    function Assert-RuntimeAncestors([string]$RuntimePath) {
        for ($parent = [IO.Directory]::GetParent($RuntimePath); $null -ne $parent; $parent = $parent.Parent) {
            if (Test-Path -LiteralPath $parent.FullName) { Assert-Custody $parent.FullName $false }
        }
    }
    function Resolve-LocalRuntime([string[]]$Candidates) {
        # Recovery is permanent, including after logout. Never rediscover the retained token.
        $recovered = @($Candidates | Where-Object {
            [IO.File]::Exists((Join-Path $_ 'leadya-profile-recovered.txt')) -or
            [IO.File]::Exists((Join-Path $_ 'leadya-profile-recovery-pending.txt'))
        })
        if ($recovered.Count -gt 1) { throw 'LOCAL_RECOVERY_BINDING_CONFLICT' }
        if ($recovered.Count -eq 1) {
            $selected = $recovered[0]
            Assert-RuntimeAncestors $selected
            Assert-Custody $selected $true
            Assert-LocalMarker $selected
            foreach ($name in @('leadya-profile-recovered.txt', 'leadya-profile-recovery-pending.txt')) {
                $receipt = Join-Path $selected $name
                if (-not [IO.File]::Exists($receipt)) { continue }
                Assert-Custody $receipt $true
                if ((Get-Item -LiteralPath $receipt).Length -gt 4096) { throw 'LOCAL_RECOVERY_BINDING_INVALID' }
                $lines = [IO.File]::ReadAllLines($receipt)
                if ($lines.Count -ne 3 -or $lines[0] -cne 'LOCAL_RECOVERY_V1' -or
                    $lines[1] -notin $Candidates -or $lines[1] -ieq $selected -or $lines[2] -notmatch '^[a-f0-9]{64}$') { throw 'LOCAL_RECOVERY_BINDING_INVALID' }
            }
            return $selected
        }
        $populated = @($Candidates | Where-Object { [IO.File]::Exists((Join-Path $_ 'bot_files\bot.properties')) })
        # A bound home stays selected when another candidate later qualifies, so reinstalls keep their home.
        $bound = @($Candidates | Where-Object { $_ -notin $populated -and [IO.File]::Exists((Join-Path $_ 'leadya-local-install.txt')) })
        # A profile whose marker names it goes first. Data without a valid marker can never be prepared
        # (LOCAL_UNBOUND_RUNTIME, LOCAL_MARKER_MISMATCH), so choosing it would block every start, e.g. after an
        # upgrade whose profile lives in the second location while the first holds data with a marker of another place.
        $valid = @($Candidates | Where-Object {
            if (-not [IO.File]::Exists((Join-Path $_ 'leadya-local-install.txt'))) { return $false }
            try { Assert-LocalMarker $_; return $true }
            catch {
                # Only a fixed refusal makes a marker invalid. A passing read or ACL error (a scanner holding the file)
                # leaves it unknown: the folder keeps its place as if valid, so the profile in use never moves, a held
                # marker of the unused location never stops it, and the real error surfaces only when this folder is used.
                return -not ([string]$_.Exception.Message -cmatch '^LOCAL_[A-Z_]{1,40}$')
            }
        })
        $ordered = @($valid | Where-Object { $_ -in $populated }) + @($valid | Where-Object { $_ -notin $populated }) +
            @($populated | Where-Object { $_ -notin $valid }) + @($bound | Where-Object { $_ -notin $valid }) +
            @($Candidates | Where-Object { $_ -notin $populated -and $_ -notin $bound })
        $refusal = $null
        foreach ($candidate in $ordered) {
            try {
                Assert-RuntimeAncestors $candidate
                if ([IO.Directory]::Exists($candidate)) { Assert-Custody $candidate $true }
                return $candidate
            } catch {
                if ($null -eq $refusal) { $refusal = [string]$_.Exception.Message }
                continue
            }
        }
        # Keep the first concrete refusal for support; it is a fixed code, never a path or ACL content.
        if ($refusal -cmatch '^LOCAL_([A-Z_]{1,40})$') { throw ('LOCAL_NO_PRIVATE_PROFILE_' + $Matches[1]) }
        throw 'LOCAL_NO_PRIVATE_PROFILE'
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
            if ($rule.IdentityReference.Value -notin $trustedOwners -and $rule.IdentityReference.Value -notmatch '^S-1-15-[23]-' -and
                (([long]$rule.FileSystemRights -band (-bnot $allowed)) -ne 0)) {
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
        # Set owner and DACL at creation, so the file never exists with broader inherited access.
        $security = New-Object Security.AccessControl.FileSecurity
        $security.SetOwner([Security.Principal.SecurityIdentifier]::new($operator))
        $security.SetAccessRuleProtection($true, $false)
        foreach ($sid in $privateOwners) {
            $security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($sid), 'FullControl', 'Allow'))
        }
        return [IO.FileStream]::new($Path, [IO.FileMode]::CreateNew, [Security.AccessControl.FileSystemRights]::Write,
            [IO.FileShare]::None, 4096, [IO.FileOptions]::None, $security)
    }
    function New-ProtectedDirectory([string]$Path) {
        if (Test-Path -LiteralPath $Path) { Assert-PackagePath $Path; return }
        $acl = New-Object Security.AccessControl.DirectorySecurity
        $acl.SetOwner([Security.Principal.SecurityIdentifier]::new($operator))
        $acl.SetAccessRuleProtection($true, $false)
        foreach ($sid in $privateOwners) {
            $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($sid), 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow'))
        }
        [IO.Directory]::CreateDirectory($Path, $acl) | Out-Null
        Assert-PackagePath $Path
    }
    function Read-PackageBinding {
        # The caller points $package and $packageParent at the installation being bound.
        if ([IO.Path]::GetDirectoryName($package) -ine $packageParent -or [IO.Path]::GetFileName($package) -notmatch '^[0-9a-f]{64}$') { throw 'LOCAL_PACKAGE_BINDING' }
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
        $identity = $codeRoot
        $identityFile = Join-Path $package 'leadya-identity-root.txt'
        if ([IO.File]::Exists($identityFile)) {
            Assert-PackagePath $identityFile
            if ((Get-Item -LiteralPath $identityFile -Force).Length -gt 65536) { throw 'LOCAL_PACKAGE_BINDING' }
            $identity = ConvertTo-IdentityRoot ([IO.File]::ReadAllText($identityFile).TrimEnd("`r", "`n"))
        }
        if ((Get-InstallationId $identity) -cne [IO.Path]::GetFileName($package)) { throw 'LOCAL_PACKAGE_BINDING' }
        return $codeRoot
    }
    if ($Mode -eq 'PackageTemp') {
        Assert-PackageAncestors
        Assert-PackagePath $package
        $temporary = Join-Path $package ('.leadya-download-' + [Guid]::NewGuid().ToString('N') + '.tmp')
        $stream = New-PackageFileStream $temporary
        $stream.Dispose()
        Assert-PackagePath $temporary
        Write-LocalValidationResult $temporary
        exit 0
    }
    if ($Mode -eq 'Uninstall') {
        $package = $root
        Write-LocalValidationResult (Read-PackageBinding)
        exit 0
    }
    if ($Mode -eq 'CodeCleanup') {
        # An untrusted custom folder can have been replaced since installation. Preserve that copy.
        for ($path = $root; $null -ne $path; $path = [IO.Path]::GetDirectoryName($path)) {
            if (Test-Path -LiteralPath $path) { Assert-PackagePath $path $true }
        }
        Write-LocalValidationResult 'LOCAL_VALID'
        exit 0
    }
    if ($Mode -in @('Package', 'PackagePrepare')) {
        Assert-PackageAncestors
        if ($Mode -eq 'PackagePrepare') {
            foreach ($directory in @($packageParent, $package)) { New-ProtectedDirectory $directory }
            foreach ($relative in @('LaunchLocalLeadYa.ps1', 'ValidateLocalInstall.ps1', 'LocalProfileRecovery.ps1', 'UninstallLocalLeadYa.ps1', 'LaunchLocalLeadYa.vbs', 'leadya-nova-icon.ico', 'LeadyaCheckingProgram.bat', 'Uninstall.exe', 'leadya-code-home.txt', 'leadya-local-origin.txt')) {
                $file = Join-Path $package $relative
                if (Test-Path -LiteralPath $file) { Assert-PackagePath $file }
                else { $stream = New-PackageFileStream $file; $stream.Dispose(); Assert-PackagePath $file }
            }
        }
        if (Test-Path -LiteralPath $package) { Assert-PackagePath $package }
        Write-LocalValidationResult $package
        exit 0
    }
    if ($Mode -in @('Mirror', 'Links', 'Unlink') -and -not $SeedDirectory) { throw 'LOCAL_PACKAGE_REQUIRED' }
    if ($SeedDirectory) {
        if ([IO.Path]::GetFullPath($SeedDirectory).TrimEnd('\') -ine $package) { throw 'LOCAL_PACKAGE_BINDING' }
        # A package that is not there is a lasting defect with its own code, never a passing read error a retry clears.
        if (-not [IO.Directory]::Exists($package)) { throw 'LOCAL_PACKAGE_MISSING' }
        Assert-PackageAncestors
        Assert-PackagePath $package
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
                $output = [IO.File]::Open($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
                try { $sourceHandle.CopyTo($output); $output.Flush($true) } finally { $output.Dispose() }
            } finally { $sourceHandle.Dispose() }
            if ([IO.File]::Exists($Destination)) { [IO.File]::Replace($temporary, $Destination, [NullString]::Value) }
            else { [IO.File]::Move($temporary, $Destination) }
        } finally { if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
    }
    function Assert-SharedJre([string]$Preparation = '') {
        $sharedJavaParent = Join-Path $perUserRoot 'Java'
        $sharedJre = Join-Path $sharedJavaParent 'jdk-17.0.21+9-jre'
        Assert-ProtectedAncestors $sharedJre
        if ($Preparation -in @('JrePrepare', 'JreCreate')) { New-ProtectedDirectory $sharedJavaParent }
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
        $info.Arguments = '-Xms16m -Xmx128m -XX:-UsePerfData ' + $Arguments
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
        $probe = New-Object Diagnostics.Process
        $probe.StartInfo = New-LocalJavaStartInfo $JavaExecutable $Arguments $package
        try {
            if (-not $probe.Start()) { throw 'LOCAL_JAVA_FAILED' }
            # Drain both pipes concurrently: a verbose JVM failure must not become a false timeout.
            $output = $probe.StandardOutput.ReadToEndAsync()
            $errorOutput = $probe.StandardError.ReadToEndAsync()
            if (-not $probe.WaitForExit($Timeout)) { $probe.Kill(); $probe.WaitForExit(); throw 'LOCAL_JAVA_TIMEOUT' }
            $diagnostic = $output.GetAwaiter().GetResult() + "`n" + $errorOutput.GetAwaiter().GetResult()
            if ($probe.ExitCode -ne 0) {
                throw (Get-LocalJvmFailureCode $diagnostic)
            }
        } catch [ComponentModel.Win32Exception] {
            if ($_.Exception.NativeErrorCode -in @(8, 14, 1455)) { throw 'LOCAL_JAVA_MEMORY' }
            throw 'LOCAL_JAVA_FAILED'
        } finally { $probe.Dispose() }
    }
    if ($Mode -eq 'JreVerify') {
        # The installer holds this archive open without write sharing, so the measured bytes are the bytes it unpacks.
        if ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($InputPath)) -ine $package) { throw 'LOCAL_JRE_ARCHIVE' }
        $archiveStream = [IO.File]::Open($InputPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        try {
            $hasher = [Security.Cryptography.SHA256]::Create()
            try { $measured = ([BitConverter]::ToString($hasher.ComputeHash($archiveStream))).Replace('-', '').ToLowerInvariant() }
            finally { $hasher.Dispose() }
        } finally { $archiveStream.Dispose() }
        if ($measured -cne $jreArchiveSha256) { throw 'LOCAL_JRE_ARCHIVE' }
        Write-LocalValidationResult 'LOCAL_VALID'
        exit 0
    }
    if ($Mode -in @('Jre', 'JrePrepare', 'JreCreate', 'JreProbe')) {
        Assert-SharedJre $Mode
        if ($Mode -eq 'JreProbe') { Invoke-JavaProbe '-version' 15000 }
        if ($Mode -eq 'JreCreate') {
            # A sibling stage folder lets the installer publish the runtime with one rename.
            $stage = Join-Path (Join-Path $perUserRoot 'Java') ('.leadya-jre-stage-' + [Guid]::NewGuid().ToString('N'))
            New-ProtectedDirectory $stage
            Write-LocalValidationResult $stage
            exit 0
        }
        Write-LocalValidationResult 'LOCAL_VALID'
        exit 0
    }
    if ($Mode -eq 'Mirror') {
        if ($ProgramJar -notmatch '^CheckingProgram-[A-Za-z0-9.]+\.jar$') { throw 'LOCAL_JAR_NAME' }
        for ($path = $root; $null -ne $path; $path = [IO.Path]::GetDirectoryName($path)) {
            if ((Test-Path -LiteralPath $path) -and ((Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'LOCAL_REPARSE' }
        }
        [IO.Directory]::CreateDirectory($root) | Out-Null
        foreach ($relative in @($ProgramJar, 'LeadyaCheckingProgram.bat', 'LaunchLocalLeadYa.ps1', 'ValidateLocalInstall.ps1', 'LocalProfileRecovery.ps1', 'UninstallLocalLeadYa.ps1', 'LaunchLocalLeadYa.vbs', 'leadya-nova-icon.ico', 'leadya-code-home.txt', 'leadya-identity-root.txt', 'leadya-local-origin.txt', 'checking_program_version.txt')) {
            $source = Join-Path $package $relative
            if ([IO.File]::Exists($source)) { Publish-AtomicFile $source (Join-Path $root $relative) }
        }
        Write-LocalValidationResult 'LOCAL_VALID'
        exit 0
    }
    if ($Mode -in @('Links', 'Unlink')) {
        try {
            $programs = [Environment]::GetFolderPath('Programs')
            Assert-ProtectedAncestors $programs
            $menu = Join-Path $programs 'LeadYa'
            if ($Mode -eq 'Links') { New-ProtectedDirectory $menu }
            $destinations = @((Join-Path $menu 'Leadya.lnk'), (Join-Path $menu 'UninstallLeadya.lnk'))
            $desktop = [Environment]::GetFolderPath('DesktopDirectory')
            try { Assert-ProtectedAncestors $desktop; $destinations += Join-Path $desktop 'Leadya.lnk' } catch { }
            $shell = New-Object -ComObject WScript.Shell
            foreach ($destination in $destinations) {
                $parent = [IO.Path]::GetDirectoryName($destination)
                if (-not [IO.Directory]::Exists($parent)) { continue }
                Assert-ProtectedAncestors $parent
                $target = Join-Path $package $(if ([IO.Path]::GetFileName($destination) -eq 'UninstallLeadya.lnk') { 'Uninstall.exe' } else { 'LeadyaCheckingProgram.bat' })
                if ($Mode -eq 'Unlink') {
                    if ([IO.File]::Exists($destination)) {
                        $existing = $shell.CreateShortcut($destination)
                        $wrapperArguments = '//B //Nologo "' + (Join-Path $package 'LaunchLocalLeadYa.vbs') + '"'
                        if ($existing.TargetPath -ieq $target -or
                            ($existing.TargetPath -ieq (Join-Path $env:SystemRoot 'System32\wscript.exe') -and $existing.Arguments -ceq $wrapperArguments)) {
                            [IO.File]::Delete($destination)
                        }
                    }
                    continue
                }
                $temporary = Join-Path $package ('.leadya-link-' + [Guid]::NewGuid().ToString('N') + '.lnk')
                try {
                    $stream = New-PackageFileStream $temporary; $stream.Dispose()
                    $link = $shell.CreateShortcut($temporary)
                    $link.TargetPath = $target; $link.WorkingDirectory = $package; $link.WindowStyle = 1
                    if ([IO.Path]::GetFileName($destination) -ne 'UninstallLeadya.lnk') {
                        $link.TargetPath = Join-Path $env:SystemRoot 'System32\wscript.exe'
                        $link.Arguments = '//B //Nologo "' + (Join-Path $package 'LaunchLocalLeadYa.vbs') + '"'
                        $link.IconLocation = (Join-Path $package 'leadya-nova-icon.ico') + ',0'
                    }
                    $link.Save()
                    Publish-AtomicFile $temporary $destination
                } finally { if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
            }
        } catch {
            # These shortcuts are optional. Never repair an ACL or write past a failed check.
            # The launcher refreshes the personal shortcuts at every start.
            if ($Mode -eq 'Unlink') { throw }
            Write-LocalValidationResult 'LOCAL_LINKS_DEFERRED'
            exit 0
        }
        Write-LocalValidationResult 'LOCAL_VALID'
        exit 0
    }
    function Assert-LocalMarker([string]$RuntimePath) {
        $markerPath = Join-Path $RuntimePath 'leadya-local-install.txt'
        Assert-Custody $markerPath $true
        if ((Get-Item -LiteralPath $markerPath).Length -gt 65536) { throw 'LOCAL_MARKER_INVALID' }
        $marker = [IO.File]::ReadAllLines($markerPath)
        if ($marker.Count -ne 3 -or $marker[0] -cne 'LOCAL' -or $marker[1] -ine $RuntimePath -or $marker[2] -cne $PublicOrigin) { throw 'LOCAL_MARKER_MISMATCH' }
    }
    if ($Mode -eq 'Adopt') {
        # A computer installed by the old machine-wide installer keeps its profile through that program's identity.
        # The registry names the package; this user's own marker proves the profile is theirs.
        $packageParent = Join-Path $programFiles 'LeadYaInstallerPackages'
        $package = [IO.Path]::GetFullPath($InputPath).TrimEnd('\')
        # Only a package folder of the old installer for this address, with a profile of this user, can be adopted.
        # Anything else means there is nothing to protect, and the installer starts afresh without reading the package:
        # the released installer listed itself before its last check, so a failed first run left a package without
        # its version file and without a profile. Lasting defects of the package or profile also start afresh and leave
        # the old profile untouched; only an unexpected error, which a retry can clear, ends as LOCAL_VALIDATION_FAILED.
        if ([IO.Path]::GetDirectoryName($package) -ine $packageParent -or [IO.Path]::GetFileName($package) -notmatch '^[0-9a-f]{64}$' -or
            -not [IO.Directory]::Exists($package)) { throw 'LOCAL_ADOPT_NO_INSTALLATION' }
        $originFile = Join-Path $package 'leadya-local-origin.txt'
        if ([IO.File]::Exists($originFile) -and (Get-Item -LiteralPath $originFile -Force).Length -le 65536 -and
            [IO.File]::ReadAllText($originFile).TrimEnd("`r", "`n") -cne $PublicOrigin) { throw 'LOCAL_ADOPT_NO_INSTALLATION' }
        $profiles = @(Get-RuntimeCandidates ([IO.Path]::GetFileName($package)) | Where-Object { [IO.File]::Exists((Join-Path $_ 'leadya-local-install.txt')) })
        if ($profiles.Count -eq 0) { throw 'LOCAL_ADOPT_NO_INSTALLATION' }
        foreach ($relative in @('leadya-code-home.txt', 'leadya-local-origin.txt', 'checking_program_version.txt')) {
            if (-not [IO.File]::Exists((Join-Path $package $relative))) { throw 'LOCAL_ADOPT_PACKAGE_UNUSABLE' }
        }
        try { $legacyCode = Read-PackageBinding }
        catch {
            if ([string]$_.Exception.Message -cmatch '^LOCAL_[A-Z_]{1,40}$') { throw 'LOCAL_ADOPT_PACKAGE_UNUSABLE' }
            throw
        }
        # The same choice as every later start of the launcher, so the installation, its guard and the launcher agree.
        # A fixed refusal is a lasting defect the launcher would refuse as well; anything else may pass on a retry.
        try {
            $verified = Resolve-LocalRuntime (Get-RuntimeCandidates ([IO.Path]::GetFileName($package)))
            if (-not [IO.File]::Exists((Join-Path $verified 'leadya-local-install.txt'))) { throw 'LOCAL_ADOPT_PROFILE_UNUSABLE' }
            Assert-LocalMarker $verified
        } catch {
            if ([string]$_.Exception.Message -cmatch '^LOCAL_[A-Z_]{1,40}$') { throw 'LOCAL_ADOPT_PROFILE_UNUSABLE' }
            throw
        }
        # The commit guards exactly this folder; '|' cannot occur in a Windows path.
        Write-LocalValidationResult ($legacyCode + '|' + $verified)
        exit 0
    }
    if ($Mode -eq 'Identity') {
        # A saved identity keeps its link while any profile location of it still holds the marker, also one the
        # runtime resolution refuses at the moment; that refusal is then reported there with its own code.
        if (-not $IdentityRoot) { throw 'LOCAL_PATH' }
        if (@($candidates | Where-Object { [IO.File]::Exists((Join-Path $_ 'leadya-local-install.txt')) }).Count -eq 0) { throw 'LOCAL_IDENTITY_PROFILE_GONE' }
        Write-LocalValidationResult 'LOCAL_VALID'
        exit 0
    }
    if ($Mode -eq 'Runtime') {
        if ($InputPath) {
            # The profile Adopt verified in this run binds the runtime of this installation, checked like its guard.
            $adopted = [IO.Path]::GetFullPath($InputPath).TrimEnd('\')
            if ($adopted -notin $candidates) { throw 'LOCAL_RUNTIME_BINDING' }
            Assert-RuntimeAncestors $adopted
            Assert-Custody $adopted $true
            Assert-LocalMarker $adopted
            Write-LocalValidationResult $adopted
            exit 0
        }
        $binding = Join-Path $root 'leadya-runtime-home.txt'
        if ([IO.File]::Exists($binding) -and (Get-Item -LiteralPath $binding).Length -le 4096) {
            $previous = [IO.File]::ReadAllText($binding).TrimEnd("`r", "`n")
            if ($previous -in $candidates) { $candidates = @($previous) + @($candidates | Where-Object { $_ -ine $previous }) }
        }
        Write-LocalValidationResult (Resolve-LocalRuntime $candidates)
        exit 0
    }
    if ($Mode -in @('Installed', 'Installable', 'Publish', 'Prepare', 'Seed') -and -not $SeedDirectory) { throw 'LOCAL_PACKAGE_REQUIRED' }
    if ($RuntimeDirectory -notin $candidates) { throw 'LOCAL_RUNTIME_BINDING' }
    $runtime = $RuntimeDirectory
    if ($Mode -eq 'AdoptGuard') {
        # The old uninstaller refuses to delete a profile that holds a hard-linked file, before deleting anything.
        # Its ticked-by-default option would otherwise remove the profile this installation now uses.
        # The profile Adopt verified in this run is named by the input; it is one of this identity's two locations.
        $guarded = $runtime
        if ($InputPath) {
            $guarded = [IO.Path]::GetFullPath($InputPath).TrimEnd('\')
            if ($guarded -notin $candidates) { throw 'LOCAL_RUNTIME_BINDING' }
        }
        # This installation prepared the profile before its commit, so a missing marker means the profile is gone.
        if (-not [IO.File]::Exists((Join-Path $guarded 'leadya-local-install.txt'))) { throw 'LOCAL_ADOPT_PROFILE_GONE' }
        Assert-RuntimeAncestors $guarded
        Assert-Custody $guarded $true
        Assert-LocalMarker $guarded
        $guard = Join-Path $guarded 'leadya-adoption-guard-1.txt'
        $twin = Join-Path $guarded 'leadya-adoption-guard-2.txt'
        if (-not ([IO.File]::Exists($guard) -and [IO.File]::Exists($twin) -and (Get-Item -LiteralPath $guard -Force).LinkType -ceq 'HardLink')) {
            foreach ($stale in @($guard, $twin)) { if ([IO.File]::Exists($stale)) { [IO.File]::Delete($stale) } }
            [IO.File]::WriteAllText($guard, "LeadYa keeps this profile while the old uninstaller is still listed.`r`n")
            Add-Type -Namespace LeadYa -Name AdoptionGuard -MemberDefinition '[System.Runtime.InteropServices.DllImport("kernel32.dll", CharSet=System.Runtime.InteropServices.CharSet.Unicode, SetLastError=true)] public static extern bool CreateHardLink(string link, string existing, System.IntPtr security);'
            if (-not [LeadYa.AdoptionGuard]::CreateHardLink($twin, $guard, [IntPtr]::Zero)) { throw 'LOCAL_ADOPT_GUARD' }
        }
        Write-LocalValidationResult 'LOCAL_VALID'
        exit 0
    }
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
        Write-LocalValidationResult 'LOCAL_VALID'
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
        if ($Mode -eq 'Seed') { Write-LocalValidationResult 'LOCAL_VALID'; exit 0 }
        $pendingRecovery = [IO.File]::Exists((Join-Path $runtime 'leadya-profile-recovery-pending.txt'))
        if ($pendingRecovery -or (-not [IO.File]::Exists((Join-Path $runtime 'bot_files\bot.properties')) -and
            -not [IO.File]::Exists((Join-Path $runtime 'leadya-profile-recovered.txt')))) {
            foreach ($previous in $candidates | Where-Object { $_ -ine $runtime }) {
                if (-not [IO.File]::Exists((Join-Path $previous 'bot_files\bot.properties'))) {
                    if ($pendingRecovery) { throw 'LOCAL_RECOVERY_SOURCE_UNAVAILABLE' }
                    if ([IO.File]::Exists((Join-Path $previous 'bot.properties.backup'))) { throw 'LOCAL_RETAINED_BACKUP_REQUIRES_RECOVERY' }
                    continue
                }
                $helper = Join-Path $package 'LocalProfileRecovery.ps1'
                Assert-PackagePath $helper
                . $helper
                $retained = [LeadYa.RetainedProfile]::Open($previous, $PublicOrigin)
                $staged = Join-Path $runtime ('.leadya-retained-' + [Guid]::NewGuid().ToString('N') + '.tmp')
                try {
                    [LeadYa.RetainedProfile]::WritePrivateSnapshot($staged, $retained.Configuration)
                    Invoke-JavaProbe ('-cp "' + $seed + '" pl.softwizard.sellbot.checking.program.LocalInstallVerifier "' + $runtime + '" "' + $PublicOrigin + '" --recover-config "' + $previous + '" "' + $staged + '"') 45000
                } finally {
                    try { if ([IO.File]::Exists($staged)) { [IO.File]::Delete($staged) } }
                    finally { $retained.Dispose() }
                }
            }
        }
        $Mode = 'Installed'
    }

    # Code may live in a user-selected location. Its ancestors must be ordinary directories.
    for ($codePath = $root; $null -ne $codePath; $codePath = [IO.Path]::GetDirectoryName($codePath)) {
        if (Test-Path -LiteralPath $codePath) {
            $item = Get-Item -LiteralPath $codePath -Force
            if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'LOCAL_REPARSE' }
        }
    }
    if ($Mode -eq 'Destination') {
        # ACLs misread filtered administrator tokens, so only a real write shows whether this user can install here.
        $writableParent = $root
        while (-not [IO.Directory]::Exists($writableParent)) {
            $writableParent = [IO.Path]::GetDirectoryName($writableParent)
            if ([string]::IsNullOrEmpty($writableParent)) { throw 'LOCAL_ADMIN_REQUIRED' }
        }
        $writeProbe = Join-Path $writableParent ('.leadya-write-test-' + [Guid]::NewGuid().ToString('N'))
        try {
            if ($writableParent -ieq $root) {
                ([IO.File]::Open($writeProbe, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)).Dispose()
                [IO.File]::Delete($writeProbe)
            } else {
                [IO.Directory]::CreateDirectory($writeProbe) | Out-Null
                [IO.Directory]::Delete($writeProbe)
            }
        } catch { throw 'LOCAL_ADMIN_REQUIRED' }
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
            foreach ($relative in @('leadya-code-home.txt', 'leadya-local-origin.txt')) {
                $path = Join-Path $payloadRoot $relative
                if (-not [IO.File]::Exists($path)) { throw 'LOCAL_PACKAGE_BINDING' }
                Assert-PackagePath $path
            }
            if ([IO.File]::ReadAllText((Join-Path $payloadRoot 'leadya-code-home.txt')).TrimEnd("`r", "`n") -ine $root -or
                [IO.File]::ReadAllText((Join-Path $payloadRoot 'leadya-local-origin.txt')).TrimEnd("`r", "`n") -cne $PublicOrigin) { throw 'LOCAL_PACKAGE_BINDING' }
        }
        foreach ($relative in @($ProgramJar, 'LeadyaCheckingProgram.bat', 'LaunchLocalLeadYa.ps1', 'Uninstall.exe')) {
            $path = Join-Path $payloadRoot $relative
            if (-not [IO.File]::Exists($path)) { throw 'LOCAL_PAYLOAD_MISSING' }
            $item = Get-Item -LiteralPath $path -Force
            if ($item.PSIsContainer -or $item.Length -eq 0 -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'LOCAL_PAYLOAD_MISSING' }
            if ($SeedDirectory) { Assert-PackagePath $path }
        }
        $runtimeJar = Join-Path $runtime $ProgramJar
        if ($Mode -eq 'Installed') {
            Assert-Custody $runtimeJar $true
            if ((Get-Item -LiteralPath $runtimeJar -Force).PSIsContainer) { throw 'LOCAL_RUNTIME_PAYLOAD' }
        }
        # Validation executes only the package copy, held against replacement until exit.
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
            if ($Mode -eq 'Installable') { Assert-SharedJre }
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
    Write-LocalValidationResult 'LOCAL_VALID'
    exit 0
} catch {
    # Never print configuration, credentials or arbitrary exception content.
    $code = [string]$_.Exception.Message
    if ($code -notmatch '^LOCAL_[A-Z_]+$') { $code = 'LOCAL_VALIDATION_FAILED' }
    Write-LocalValidationResult $code
    exit 12
}
