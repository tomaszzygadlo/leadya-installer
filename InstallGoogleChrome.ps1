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

# Only answers whether Chrome is present. Installing Chrome is the person's own choice, on Google's page.
if (Test-GoogleChromeInstalled) { exit 0 }
exit 1
