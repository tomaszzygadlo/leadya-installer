[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string[]]$Path,
    [string]$CertificateThumbprint = $env:LEADYA_CODE_SIGNING_CERT_THUMBPRINT,
    [ValidateSet('CurrentUser', 'LocalMachine')][string]$CertificateStore = 'CurrentUser',
    [string]$TimestampUrl = 'https://time.certum.pl'
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'InstallerReleaseSecurity.ps1')

foreach ($item in $Path) {
    $file = Get-Item -LiteralPath $item -ErrorAction Stop
    if ($file.PSIsContainer -or $file.Extension -notin @('.exe', '.msi', '.msix', '.msixbundle')) {
        throw 'Explicit Windows package paths are required'
    }
    # A post-build signature changes the hash. The producer must finalize its manifest afterwards.
    if ((Test-Path -LiteralPath ([IO.Path]::ChangeExtension($file.FullName, '.manifest.json'))) -or
        (Test-Path -LiteralPath ([IO.Path]::ChangeExtension($file.FullName, '.manifest')))) {
        throw 'Sign before producing the build manifest; use the publication build pipeline'
    }
    Set-InstallerReleaseSignature -Path $file.FullName -CertificateThumbprint $CertificateThumbprint -CertificateStore $CertificateStore -TimestampUrl $TimestampUrl
}
