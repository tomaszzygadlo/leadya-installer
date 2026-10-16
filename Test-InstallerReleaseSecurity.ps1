$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSHOME 'Modules/Microsoft.PowerShell.Utility/Microsoft.PowerShell.Utility.psd1') -ErrorAction Stop
. (Join-Path $PSScriptRoot 'InstallerReleaseSecurity.ps1')

$script:passed = 0
function Assert-Refused {
    param([string]$Name, [scriptblock]$Action, [string]$Reason)
    try { & $Action | Out-Null }
    catch {
        if ($_.Exception.Message -notlike "*$Reason*") { throw "$Name failed for the wrong reason: $_" }
        $script:passed++
        return
    }
    throw "$Name was incorrectly accepted"
}

$now = [DateTimeOffset]::UtcNow
function New-CleanStatus {
    [pscustomobject]@{
        AntivirusEnabled = $true; RealTimeProtectionEnabled = $true
        AntivirusSignatureVersion = '1.2.3.4'; AntivirusSignatureLastUpdated = $now.UtcDateTime
        AMEngineVersion = '1.2.3.4'
    }
}
function New-CleanPreferences {
    [pscustomobject]@{
        ExclusionPath = @(); ExclusionProcess = @(); ExclusionExtension = @()
        ThreatIDDefaultAction_Ids = @(); DisableArchiveScanning = $false
    }
}

foreach ($entry in @(
    @('CN=Microsoft Windows, O=Microsoft Corporation, C=US', $true),
    @('CN="O=Microsoft Corporation, x", O=Other, C=US', $false),
    @('CN=Microsoft Windows, O=Microsoft Corporation Spoof, C=US', $false),
    @('CN=Microsoft Windows, C=US', $false)
)) {
    $subject = New-Object Security.Cryptography.X509Certificates.X500DistinguishedName($entry[0])
    if ((Test-MicrosoftCertificateOrganization ([pscustomobject]@{ SubjectName=$subject })) -ne $entry[1]) {
        throw 'Certificate organization must be read from the actual O attribute'
    }
    $script:passed++
}

Assert-InstallerScanPolicy -Status (New-CleanStatus) -Preferences (New-CleanPreferences) -Now $now
$script:passed++
Assert-Refused 'missing antivirus status' { Assert-InstallerScanPolicy -Status $null -Preferences (New-CleanPreferences) -Now $now } 'status'
$status = New-CleanStatus; $status.PSObject.Properties.Remove('AntivirusSignatureVersion')
Assert-Refused 'incomplete antivirus status' { Assert-InstallerScanPolicy -Status $status -Preferences (New-CleanPreferences) -Now $now } 'incomplete'
$preferences = New-CleanPreferences; $preferences.PSObject.Properties.Remove('ExclusionPath')
Assert-Refused 'incomplete antivirus policy' { Assert-InstallerScanPolicy -Status (New-CleanStatus) -Preferences $preferences -Now $now } 'incomplete'
$status = New-CleanStatus; $status.AntivirusEnabled = $false
Assert-Refused 'disabled antivirus' { Assert-InstallerScanPolicy -Status $status -Preferences (New-CleanPreferences) -Now $now } 'enabled'
$status = New-CleanStatus; $status.RealTimeProtectionEnabled = $false
Assert-Refused 'disabled real-time protection' { Assert-InstallerScanPolicy -Status $status -Preferences (New-CleanPreferences) -Now $now } 'enabled'
$status = New-CleanStatus; $status.AntivirusSignatureLastUpdated = $now.AddHours(-25).UtcDateTime
Assert-Refused 'stale signatures' { Assert-InstallerScanPolicy -Status $status -Preferences (New-CleanPreferences) -Now $now } 'fresh'
$status = New-CleanStatus; $status.AntivirusSignatureLastUpdated = $now.AddHours(1).UtcDateTime
Assert-Refused 'future signature timestamp' { Assert-InstallerScanPolicy -Status $status -Preferences (New-CleanPreferences) -Now $now } 'fresh'
$status = New-CleanStatus; $status.AntivirusSignatureVersion = ''
Assert-Refused 'missing signature version' { Assert-InstallerScanPolicy -Status $status -Preferences (New-CleanPreferences) -Now $now } 'version'
foreach ($field in @('ExclusionPath', 'ExclusionProcess', 'ExclusionExtension', 'ThreatIDDefaultAction_Ids')) {
    $preferences = New-CleanPreferences; $preferences.$field = @('test-override')
    Assert-Refused $field { Assert-InstallerScanPolicy -Status (New-CleanStatus) -Preferences $preferences -Now $now } 'exception'
}
$preferences = New-CleanPreferences; $preferences.DisableArchiveScanning = $true
Assert-Refused 'disabled archive scanning' { Assert-InstallerScanPolicy -Status (New-CleanStatus) -Preferences $preferences -Now $now } 'archive'
$preferences = New-CleanPreferences; $preferences.ExclusionPath = $null
Assert-InstallerScanPolicy -Status (New-CleanStatus) -Preferences $preferences -Now $now
$script:passed++

$thumbprint = 'A' * 40
$certificate = [pscustomobject]@{ Thumbprint = $thumbprint; Subject = 'CN=TEST Publisher' }
$signature = [pscustomobject]@{ Status = 'Valid'; SignerCertificate = $certificate; TimeStamperCertificate = $certificate }
Assert-InstallerPublisher -Signature $signature -CertificateThumbprint $thumbprint
$script:passed++
Assert-Refused 'unsigned package' { Assert-InstallerPublisher -Signature ([pscustomobject]@{ Status='NotSigned' }) -CertificateThumbprint $thumbprint } 'signature'
Assert-Refused 'wrong publisher' { Assert-InstallerPublisher -Signature $signature -CertificateThumbprint ('B' * 40) } 'publisher'
Assert-Refused 'missing publisher pin' { Assert-InstallerPublisher -Signature $signature -CertificateThumbprint '' } 'thumbprint'
$untimestamped = [pscustomobject]@{ Status = 'Valid'; SignerCertificate = $certificate; TimeStamperCertificate = $null }
Assert-Refused 'missing timestamp' { Assert-InstallerPublisher -Signature $untimestamped -CertificateThumbprint $thumbprint } 'timestamp'

# Synthetic process-boundary tests. These do not claim a real signed file or AV result.
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('leadya-release-test-' + [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($fixtureRoot) | Out-Null
$script:package = Join-Path $fixtureRoot 'inert package.exe'
$script:scanMode = 'clean'
$script:killed = $false
$script:disposed = $false
$script:scanArguments = ''
$script:tamperDenied = $false
$script:registryChecks = 0
$script:directoryHandles = New-Object 'Collections.Generic.List[IDisposable]'
$savedProgramFiles = $env:ProgramFiles
$env:ProgramFiles = $fixtureRoot
$scannerFixtureDirectory = Join-Path $fixtureRoot 'Windows Defender'
[IO.Directory]::CreateDirectory($scannerFixtureDirectory) | Out-Null
$scannerFixture = Join-Path $scannerFixtureDirectory 'MpCmdRun.exe'
[IO.File]::WriteAllText($scannerFixture, 'INERT SCANNER FIXTURE; NEVER EXECUTED')
function Open-InstallerDirectoryHandle {
    param([string]$Path)
    if ($script:scanMode -eq 'parent-open-failure' -and $script:directoryHandles.Count -eq 1) {
        throw 'Synthetic parent custody failure'
    }
    Initialize-InstallerCustodyNative
    $handle = [LeadYa.InstallerCustody.NativeMethods]::OpenDirectory($Path)
    $script:directoryHandles.Add($handle)
    return $handle
}
function Assert-DirectoryCustodyReleased {
    if ($script:directoryHandles.Count -eq 0 -or @($script:directoryHandles | Where-Object { -not $_.IsClosed }).Count -ne 0) {
        throw 'Directory custody was absent or leaked a native handle'
    }
    $script:directoryHandles.Clear()
    $script:passed++
}
function Get-MpComputerStatus { New-CleanStatus }
function Get-MpPreference { New-CleanPreferences }
function Get-AuthenticodeSignature {
    param($LiteralPath)
    if (@($script:directoryHandles | Where-Object { -not $_.IsClosed }).Count -eq 0) {
        throw 'Directory custody missing before signature'
    }
    if ($LiteralPath.EndsWith('MpCmdRun.exe')) {
        $subject = New-Object Security.Cryptography.X509Certificates.X500DistinguishedName('CN=Microsoft Windows, O=Microsoft Corporation, C=US')
        return [pscustomobject]@{ Status='Valid'; SignerCertificate=[pscustomobject]@{ SubjectName=$subject } }
    }
    if ($script:scanMode -eq 'signature-tamper') {
        try { [IO.File]::AppendAllText($script:package, 'changed'); throw 'Signature/hash race was allowed' }
        catch [IO.IOException] { $script:tamperDenied = $true }
    }
    return $signature
}
function Test-Path {
    param($LiteralPath, $PathType = 'Any')
    if ($LiteralPath -like '*Windows Defender\Threats\ThreatIDDefaultAction') {
        $script:registryChecks++
        return $script:scanMode -eq 'late-allow' -and $script:registryChecks -gt 1
    }
    Microsoft.PowerShell.Management\Test-Path -LiteralPath $LiteralPath -PathType $PathType
}
function Get-ItemProperty { param($LiteralPath) [pscustomobject]@{ '2147731849'=6 } }
function Start-Process {
    param($FilePath, $ArgumentList, $WindowStyle, [switch]$PassThru, $RedirectStandardOutput, $RedirectStandardError)
    if ($WindowStyle -ne 'Hidden' -or $FilePath -notlike '*Windows Defender\MpCmdRun.exe') { throw 'Unexpected scanner process' }
    $script:scanArguments = $ArgumentList
    $process = [pscustomobject]@{ Handle=1; ExitCode = $(if ($script:scanMode -eq 'detect') { 2 } else { 0 }) }
    $process | Add-Member ScriptMethod WaitForExit {
        param($milliseconds)
        if ($null -eq $milliseconds) { return }
        if (@($script:directoryHandles | Where-Object { -not $_.IsClosed }).Count -eq 0) {
            throw 'Directory custody missing during scanner read'
        }
        if ($script:scanMode -eq 'tamper') {
            try { [IO.File]::AppendAllText($script:package, 'changed'); throw 'Scan-time write was allowed' }
            catch [IO.IOException] { $script:tamperDenied = $true }
        }
        return $script:scanMode -ne 'timeout'
    }
    $process | Add-Member ScriptMethod Kill { $script:killed = $true }
    $process | Add-Member ScriptMethod Dispose { $script:disposed = $true }
    return $process
}
try {
    [IO.File]::WriteAllText($script:package, 'MZ INERT UNIT TEST FIXTURE ONLY')
    $evidence = Get-InstallerReleaseSecurityEvidence -Path $script:package -CertificateThumbprint $thumbprint
    $expected = (Microsoft.PowerShell.Utility\Get-FileHash -Algorithm SHA256 -LiteralPath $script:package).Hash.ToLowerInvariant()
    if ($evidence.artifact_sha256 -ne $expected -or $evidence.defender.exit_code -ne 0 -or -not $script:disposed) {
        throw 'Synthetic scan did not bind the final hash and terminal process'
    }
    $script:passed++
    Assert-DirectoryCustodyReleased
    $savedSignature = $signature
    $signature = [pscustomobject]@{ Status='NotSigned'; SignerCertificate=$null; TimeStamperCertificate=$null }
    $assessment = Get-InstallerReleaseSecurityEvidence -Path $script:package -AssessmentOnly
    if ($assessment.publication_ready -ne $false -or $assessment.authenticode.status -ne 'NotSigned' -or
        $null -ne $assessment.authenticode.certificate_thumbprint) { throw 'Unsigned assessment was misrepresented as a release' }
    $script:passed++
    Assert-Refused 'unsigned remains refused for publication' { Get-InstallerReleaseSecurityEvidence -Path $script:package -CertificateThumbprint $thumbprint } 'signature'
    $signature = $savedSignature
    if ($script:scanArguments -ne ('-Scan -ScanType 3 -File "' + $script:package + '" -DisableRemediation')) {
        throw 'Scanner path quoting or no-remediation mode changed'
    }
    $script:passed++
    $script:scanMode = 'detect'
    Assert-Refused 'detection or scanner error' { Get-InstallerReleaseSecurityEvidence -Path $script:package -CertificateThumbprint $thumbprint } 'publication refused'
    $script:scanMode = 'tamper'
    Get-InstallerReleaseSecurityEvidence -Path $script:package -CertificateThumbprint $thumbprint | Out-Null
    if (-not $script:tamperDenied) { throw 'Scanner did not hold immutable package bytes' }
    $script:passed++
    $script:scanMode = 'signature-tamper'; $script:tamperDenied = $false
    Get-InstallerReleaseSecurityEvidence -Path $script:package -CertificateThumbprint $thumbprint | Out-Null
    if (-not $script:tamperDenied) { throw 'Signature/hash replacement was not blocked' }
    $script:passed++
    $script:scanMode = 'late-allow'; $script:registryChecks = 0
    Assert-Refused 'allow added during scan' { Get-InstallerReleaseSecurityEvidence -Path $script:package -CertificateThumbprint $thumbprint } 'local threat exception'
    $script:scanMode = 'timeout'
    Assert-Refused 'scanner timeout' { Get-InstallerReleaseSecurityEvidence -Path $script:package -CertificateThumbprint $thumbprint -TimeoutSeconds 1 } 'timed out'
    if (-not $script:killed) { throw 'Timed-out owned scanner was not stopped' }
    $script:passed++
    Assert-DirectoryCustodyReleased
    $script:scanMode = 'parent-open-failure'
    Assert-Refused 'partial parent acquisition' { Get-InstallerReleaseSecurityEvidence -Path $script:package -CertificateThumbprint $thumbprint } 'parent custody failure'
    Assert-DirectoryCustodyReleased
    $script:scanMode = 'clean'
    Assert-Refused 'network release path' { Open-InstallerParentCustody '\\not-contacted.invalid\share\package.exe' } 'local fixed'
    Assert-Refused 'alternate data stream' { Open-InstallerParentCustody ($script:package + ':other.exe') } 'local fixed'
    $signParents = $null; $signHandle = $null; $writer = $null; $signedRead = $null
    try {
        $signParents = Open-InstallerParentCustody $script:package
        $signHandle = [LeadYa.InstallerCustody.NativeMethods]::OpenSigningFile($script:package)
        # A signer may require an exclusive content-write handle. The identity pin uses no read/write access.
        $writer = [IO.File]::Open($script:package, [IO.FileMode]::Open, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $writer.Position = $writer.Length
        $writer.WriteByte(0)
        $writer.Dispose(); $writer = $null
        $script:passed++
        $signedRead = Open-InstallerReadCustody $script:package
        if ($signedRead.Stream.Length -eq 0) { throw 'Post-sign read custody failed' }
        $script:passed++
    } finally {
        Close-InstallerReadCustody $signedRead
        if ($null -ne $writer) { $writer.Dispose() }
        if ($null -ne $signHandle) { $signHandle.Dispose() }
        Close-InstallerParentCustody $signParents
    }
    Assert-DirectoryCustodyReleased
}
finally {
    $env:ProgramFiles = $savedProgramFiles
    Remove-Item -LiteralPath $script:package -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $scannerFixture -Force -ErrorAction SilentlyContinue
    [IO.Directory]::Delete($scannerFixtureDirectory)
    Remove-Item -LiteralPath $fixtureRoot -ErrorAction Stop
}

Write-Output "$script:passed installer release policy tests passed"
