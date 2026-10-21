[CmdletBinding()]
param([switch]$DetectOnly)
$ErrorActionPreference = 'Stop'

function Test-GoogleChromeInstalled {
    $paths = @(
        (Join-Path ([Environment]::GetFolderPath('ProgramFiles')) 'Google\Chrome\Application\chrome.exe'),
        (Join-Path ([Environment]::GetFolderPath('ProgramFilesX86')) 'Google\Chrome\Application\chrome.exe'),
        (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Google\Chrome\Application\chrome.exe')
    )
    foreach ($registryPath in @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe')) {
        if (Test-Path -LiteralPath $registryPath) {
            $paths += (Get-Item -LiteralPath $registryPath).GetValue('')
        }
    }
    foreach ($path in $paths) {
        if ($path -and (Test-Path -LiteralPath $path -PathType Leaf)) { return $true }
    }
    return $false
}

function New-TrustedChromeSetupDirectory {
    $programFiles = [Environment]::GetFolderPath('ProgramFiles')
    if (-not $programFiles -or -not [IO.Path]::IsPathRooted($programFiles)) {
        throw 'Nie można ustalić bezpiecznego katalogu instalacji Chrome.'
    }
    $parent = [IO.DirectoryInfo]::new($programFiles)
    for ($ancestor = $parent; $null -ne $ancestor; $ancestor = $ancestor.Parent) {
        if (-not $ancestor.Exists -or ($ancestor.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw 'Katalog instalacji Chrome nie może być przekierowaniem.'
        }
    }
    $trusted = @('S-1-5-18', 'S-1-5-32-544',
        'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464')
    $acl = $parent.GetAccessControl()
    if ($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -notin $trusted) {
        throw 'Katalog instalacji Chrome ma nieprawidłowego właściciela.'
    }
    $writes = [Security.AccessControl.FileSystemRights]'Write,Delete,DeleteSubdirectoriesAndFiles,ChangePermissions,TakeOwnership'
    foreach ($rule in $acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
        if ($rule.AccessControlType -eq 'Allow' -and
            -not ($rule.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly) -and
            ($rule.FileSystemRights -band $writes) -and $rule.IdentityReference.Value -notin $trusted) {
            throw 'Katalog instalacji Chrome pozwala na zapis innym użytkownikom.'
        }
    }
    $security = [Security.AccessControl.DirectorySecurity]::new()
    $security.SetAccessRuleProtection($true, $false)
    $security.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))
    foreach ($sid in @('S-1-5-18', 'S-1-5-32-544')) {
        $security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
            [Security.Principal.SecurityIdentifier]::new($sid), 'FullControl',
            'ContainerInherit,ObjectInherit', 'None', 'Allow'))
    }
    $stage = [IO.DirectoryInfo]::new((Join-Path $programFiles ('LeadYaChromeSetup-' + [guid]::NewGuid().ToString('N'))))
    if ($stage.Exists) { throw 'Katalog instalacji Chrome już istnieje.' }
    $stage.Create($security)
    return $stage.FullName
}

if (Test-GoogleChromeInstalled) { exit 0 }
if ($DetectOnly) { exit 1 }
# Resolve protected OS folders independently of the inherited environment.
$downloadDirectory = New-TrustedChromeSetupDirectory
$package = Join-Path $downloadDirectory 'GoogleChromeStandaloneEnterprise64.msi'
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $client = New-Object Net.WebClient
    try {
        $client.DownloadFile('https://dl.google.com/dl/chrome/install/googlechromestandaloneenterprise64.msi', $package)
    } finally { $client.Dispose() }
    $packageLock = [IO.File]::Open($package, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        $signature = Get-AuthenticodeSignature -LiteralPath $package
        if ($signature.Status -ne 'Valid' -or $null -eq $signature.SignerCertificate -or
            $signature.SignerCertificate.Subject -notmatch '(?:^|,\s*)O=Google (?:LLC|Inc\.)(?:,|$)') {
            throw 'Nie można potwierdzić podpisu instalatora Google Chrome.'
        }
        $installer = Start-Process -FilePath (Join-Path ([Environment]::SystemDirectory) 'msiexec.exe') -WindowStyle Hidden -ArgumentList @('/i', ('"' + $package + '"'), '/qn', '/norestart') -Wait -PassThru
        if ($installer.ExitCode -notin @(0, 3010) -or -not (Test-GoogleChromeInstalled)) {
            throw 'Nie udało się zainstalować Google Chrome. Spróbuj ponownie.'
        }
    } finally { $packageLock.Dispose() }
} finally {
    Remove-Item -LiteralPath $package -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $downloadDirectory -ErrorAction SilentlyContinue
}
