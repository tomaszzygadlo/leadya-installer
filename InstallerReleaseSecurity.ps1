# Shared by Windows package producers. Never changes Defender settings or executes a package.
function Initialize-InstallerCustodyNative {
    if ('LeadYa.InstallerCustody.NativeMethods' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
namespace LeadYa.InstallerCustody {
    public static class NativeMethods {
        [StructLayout(LayoutKind.Sequential)]
        private struct FileInformation {
            public uint Attributes;
            public System.Runtime.InteropServices.ComTypes.FILETIME Creation, Access, Write;
            public uint Volume, SizeHigh, SizeLow, Links, IndexHigh, IndexLow;
        }
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, ExactSpelling=true, SetLastError=true)]
        private static extern SafeFileHandle CreateFileW(string path, uint access, uint share,
            IntPtr security, uint disposition, uint flags, IntPtr template);
        [DllImport("kernel32.dll", SetLastError=true)]
        private static extern bool GetFileInformationByHandle(SafeFileHandle file, out FileInformation info);
        private static SafeFileHandle Open(string path, bool directory, bool signing = false) {
            // OPEN_REPARSE_POINT inspects the actual leaf, never its redirected target.
            // Directory/read handles deny write and delete. The signing target permits in-place writes.
            SafeFileHandle file = CreateFileW(path, signing ? 0u : (directory ? 0x80u : 0x80000000u), signing ? 3u : 1u,
                IntPtr.Zero, 3, 0x00200000u | (directory ? 0x02000000u : 0u), IntPtr.Zero);
            try {
                if (file.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error());
                FileInformation info;
                if (!GetFileInformationByHandle(file, out info)) throw new Win32Exception(Marshal.GetLastWin32Error());
                if ((info.Attributes & 0x400) != 0 || ((info.Attributes & 0x10) != 0) != directory)
                    throw new InvalidOperationException("Ordinary non-reparse installer path required");
                return file;
            } catch { file.Dispose(); throw; }
        }
        public static SafeFileHandle OpenDirectory(string path) { return Open(path, true); }
        public static SafeFileHandle OpenFile(string path) { return Open(path, false); }
        // Signing may write in place, but cannot replace the pinned file with a link or another file.
        public static SafeFileHandle OpenSigningFile(string path) { return Open(path, false, true); }
    }
}
'@ -ErrorAction Stop
}

function Open-InstallerDirectoryHandle {
    param([string]$Path)
    Initialize-InstallerCustodyNative
    return [LeadYa.InstallerCustody.NativeMethods]::OpenDirectory($Path)
}

function Close-InstallerParentCustody {
    param($Handles)
    if ($null -ne $Handles) {
        for ($index = $Handles.Count - 1; $index -ge 0; $index--) { $Handles[$index].Dispose() }
    }
}

function Open-InstallerParentCustody {
    param([string]$Path)
    if ($Path -match '^[A-Za-z]:' -and $Path.Substring(2).Contains(':')) {
        throw 'Installer custody requires an ordinary path on a local fixed Windows drive'
    }
    $full = [IO.Path]::GetFullPath($Path)
    if ($full -notmatch '^[A-Za-z]:\\' -or $full.Substring(2).Contains(':') -or
        ([IO.DriveInfo]::new([IO.Path]::GetPathRoot($full))).DriveType -ne [IO.DriveType]::Fixed) {
        throw 'Installer custody requires an ordinary path on a local fixed Windows drive'
    }
    $parents = New-Object 'Collections.Generic.List[string]'
    for ($parent = [IO.Path]::GetDirectoryName($full); $null -ne $parent; $parent = [IO.Path]::GetDirectoryName($parent)) {
        $parents.Insert(0, $parent)
    }
    $handles = New-Object 'Collections.Generic.List[IDisposable]'
    try {
        # Root first: each already-held ancestor prevents replacement before the next open.
        foreach ($parent in $parents) { $handles.Add((Open-InstallerDirectoryHandle $parent)) }
        return ,$handles
    } catch { Close-InstallerParentCustody $handles; throw }
}

function Open-InstallerReadCustody {
    param([string]$Path)
    $full = [IO.Path]::GetFullPath($Path)
    $parents = Open-InstallerParentCustody $full
    $handle = $null
    try {
        Initialize-InstallerCustodyNative
        $handle = [LeadYa.InstallerCustody.NativeMethods]::OpenFile($full)
        $stream = [IO.FileStream]::new($handle, [IO.FileAccess]::Read)
        return [pscustomobject]@{ Path=$full; Parents=$parents; Stream=$stream }
    } catch {
        if ($null -ne $handle) { $handle.Dispose() }
        Close-InstallerParentCustody $parents
        throw
    }
}

function Close-InstallerReadCustody {
    param($Custody)
    if ($null -ne $Custody) {
        try { $Custody.Stream.Dispose() }
        finally { Close-InstallerParentCustody $Custody.Parents }
    }
}

function Assert-InstallerScanPolicy {
    param($Status, $Preferences, [DateTimeOffset]$Now = [DateTimeOffset]::UtcNow)
    if ($null -eq $Status -or $null -eq $Preferences) { throw 'Defender status or policy unavailable' }
    foreach ($field in @('AntivirusEnabled', 'RealTimeProtectionEnabled', 'AntivirusSignatureVersion', 'AntivirusSignatureLastUpdated', 'AMEngineVersion')) {
        if ($null -eq $Status.PSObject.Properties[$field]) { throw 'Defender status is incomplete' }
    }
    foreach ($field in @('ExclusionPath', 'ExclusionProcess', 'ExclusionExtension', 'ThreatIDDefaultAction_Ids', 'DisableArchiveScanning')) {
        if ($null -eq $Preferences.PSObject.Properties[$field]) { throw 'Defender policy is incomplete' }
    }
    if ($Status.AntivirusEnabled -ne $true -or $Status.RealTimeProtectionEnabled -ne $true) {
        throw 'Defender antivirus and real-time protection must be enabled'
    }
    if ([string]::IsNullOrWhiteSpace($Status.AntivirusSignatureVersion) -or
        [string]::IsNullOrWhiteSpace($Status.AMEngineVersion)) { throw 'Defender version unavailable' }
    $updated = [DateTimeOffset]([DateTime]$Status.AntivirusSignatureLastUpdated).ToUniversalTime()
    if ($updated -gt $Now.AddMinutes(5) -or $updated -lt $Now.AddHours(-24)) {
        throw 'Defender signatures must be fresh (within 24 hours)'
    }
    foreach ($field in @('ExclusionPath', 'ExclusionProcess', 'ExclusionExtension', 'ThreatIDDefaultAction_Ids')) {
        if (@($Preferences.$field | Where-Object { $null -ne $_ -and "$($_)".Trim().Length -gt 0 }).Count -gt 0) {
            throw 'Release scan refused: Defender exception or per-threat override; use a clean signing/scan host'
        }
    }
    if ($Preferences.DisableArchiveScanning -ne $false) { throw 'Defender archive scanning must be enabled' }
}

function Read-InstallerDerElement {
    param([byte[]]$Bytes, [ref]$Offset, [int]$Limit)
    if ($Offset.Value + 2 -gt $Limit) { throw 'Invalid certificate subject' }
    $tag = $Bytes[$Offset.Value]; $Offset.Value++
    $length = [int]$Bytes[$Offset.Value]; $Offset.Value++
    if ($length -band 128) {
        $count = $length -band 127
        if ($count -lt 1 -or $count -gt 4 -or $Offset.Value + $count -gt $Limit) { throw 'Invalid certificate subject' }
        $length = [long]0
        for ($i = 0; $i -lt $count; $i++) { $length = $length * 256 + $Bytes[$Offset.Value]; $Offset.Value++ }
    }
    $start = $Offset.Value
    if ($length -gt $Limit - $start) { throw 'Invalid certificate subject' }
    $Offset.Value = [int]($start + $length)
    [pscustomobject]@{ Tag=$tag; Start=$start; End=$Offset.Value }
}

function Test-MicrosoftCertificateOrganization {
    param($Certificate)
    # Parse the X.500 DER attributes, never a substring of a formatted CN.
    if ($null -eq $Certificate -or $null -eq $Certificate.SubjectName) { return $false }
    try {
        [byte[]]$bytes = $Certificate.SubjectName.RawData
        $offset = 0; $name = Read-InstallerDerElement $bytes ([ref]$offset) $bytes.Length
        if ($name.Tag -ne 48 -or $name.End -ne $bytes.Length) { return $false }
        $offset = $name.Start; $organizations = @()
        while ($offset -lt $name.End) {
            $rdn = Read-InstallerDerElement $bytes ([ref]$offset) $name.End
            if ($rdn.Tag -ne 49) { return $false }
            $attributeOffset = $rdn.Start
            while ($attributeOffset -lt $rdn.End) {
                $attribute = Read-InstallerDerElement $bytes ([ref]$attributeOffset) $rdn.End
                if ($attribute.Tag -ne 48) { return $false }
                $valueOffset = $attribute.Start
                $oid = Read-InstallerDerElement $bytes ([ref]$valueOffset) $attribute.End
                $value = Read-InstallerDerElement $bytes ([ref]$valueOffset) $attribute.End
                if ($oid.Tag -ne 6 -or $valueOffset -ne $attribute.End) { return $false }
                if ($oid.End - $oid.Start -eq 3 -and $bytes[$oid.Start] -eq 85 -and
                    $bytes[$oid.Start+1] -eq 4 -and $bytes[$oid.Start+2] -eq 10) {
                    $encoding = switch ($value.Tag) {
                        12 { New-Object Text.UTF8Encoding($false, $true) }
                        19 { [Text.Encoding]::ASCII }
                        20 { [Text.Encoding]::ASCII }
                        22 { [Text.Encoding]::ASCII }
                        30 { [Text.Encoding]::BigEndianUnicode }
                        default { return $false }
                    }
                    $organizations += $encoding.GetString($bytes, $value.Start, $value.End - $value.Start)
                }
            }
        }
        return $organizations.Count -eq 1 -and $organizations[0] -ceq 'Microsoft Corporation'
    } catch { return $false }
}

function Assert-InstallerLocalThreatPolicy {
    $overridePath = 'HKLM:\SOFTWARE\Microsoft\Windows Defender\Threats\ThreatIDDefaultAction'
    if (Test-Path -LiteralPath $overridePath -ErrorAction Stop) {
        $overrides = Get-ItemProperty -LiteralPath $overridePath -ErrorAction Stop
        if (@($overrides.PSObject.Properties | Where-Object { $_.Name -match '^\d+$' }).Count -gt 0) {
            throw 'Release scan refused: local threat exception; use a clean signing/scan host'
        }
    }
}

function Assert-InstallerPublisher {
    param($Signature, [string]$CertificateThumbprint)
    if ($CertificateThumbprint -notmatch '^[0-9A-Fa-f]{40}$') { throw 'Explicit publisher certificate thumbprint required' }
    if ($null -eq $Signature -or [string]$Signature.Status -ne 'Valid') { throw 'Valid Authenticode signature required' }
    if ($null -eq $Signature.SignerCertificate -or $Signature.SignerCertificate.Thumbprint -ne $CertificateThumbprint) {
        throw 'Installer publisher does not match the pinned certificate'
    }
    if ($null -eq $Signature.TimeStamperCertificate) { throw 'Trusted Authenticode timestamp required' }
}

function Set-InstallerReleaseSignature {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$CertificateThumbprint = $env:LEADYA_CODE_SIGNING_CERT_THUMBPRINT,
        [ValidateSet('CurrentUser', 'LocalMachine')][string]$CertificateStore = 'CurrentUser',
        [string]$TimestampUrl = 'https://time.certum.pl'
    )
    if ($CertificateThumbprint -notmatch '^[0-9A-Fa-f]{40}$') { throw 'Explicit publisher certificate thumbprint required' }
    $certificate = Get-Item -LiteralPath "Cert:\$CertificateStore\My\$CertificateThumbprint" -ErrorAction Stop
    $codeSigningUsage = @($certificate.Extensions | Where-Object { $_.Oid.Value -eq '2.5.29.37' } |
        ForEach-Object { $_.EnhancedKeyUsages } | Where-Object { $_.Value -eq '1.3.6.1.5.5.7.3.3' })
    if (-not $certificate.HasPrivateKey -or $certificate.NotAfter -le (Get-Date) -or
        $certificate.NotBefore -gt (Get-Date) -or
        $codeSigningUsage.Count -eq 0) {
        throw 'A valid Code Signing certificate with an accessible private key is required'
    }
    $signTool = (Get-Command signtool.exe -CommandType Application -ErrorAction Stop).Source
    $toolCustody = $null
    $signedCustody = $null
    $targetParents = $null
    $targetLock = $null
    try {
    $target = (Get-Item -LiteralPath $Path -ErrorAction Stop).FullName
    $targetParents = Open-InstallerParentCustody $target
    Initialize-InstallerCustodyNative
    $targetLock = [LeadYa.InstallerCustody.NativeMethods]::OpenSigningFile($target)
    $toolCustody = Open-InstallerReadCustody $signTool
    $signTool = $toolCustody.Path
    $toolSignature = Get-AuthenticodeSignature -LiteralPath $toolCustody.Path -ErrorAction Stop
    if ([string]$toolSignature.Status -ne 'Valid' -or
        -not (Test-MicrosoftCertificateOrganization $toolSignature.SignerCertificate)) {
        throw 'Trusted Microsoft SignTool unavailable'
    }
    $arguments = @('sign', '/sha1', $CertificateThumbprint, '/s', 'My', '/fd', 'SHA256', '/tr', $TimestampUrl, '/td', 'SHA256')
    if ($CertificateStore -eq 'LocalMachine') { $arguments += '/sm' }
    $arguments += $target
    & $signTool @arguments | Out-Host
    if ($LASTEXITCODE -ne 0) { throw 'Authenticode signing failed' }
    $signedCustody = Open-InstallerReadCustody $target
    Assert-InstallerPublisher -Signature (Get-AuthenticodeSignature -LiteralPath $signedCustody.Path) -CertificateThumbprint $CertificateThumbprint
    } finally {
        Close-InstallerReadCustody $signedCustody
        Close-InstallerReadCustody $toolCustody
        if ($null -ne $targetLock) { $targetLock.Dispose() }
        Close-InstallerParentCustody $targetParents
    }
}

function Get-InstallerReleaseSecurityEvidence {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$CertificateThumbprint = $env:LEADYA_CODE_SIGNING_CERT_THUMBPRINT,
        [ValidateRange(1, 60)][int]$TimeoutSeconds = 60,
        [switch]$AssessmentOnly
    )
    $artifact = Get-Item -LiteralPath $Path -ErrorAction Stop
    if ($artifact.PSIsContainer -or $artifact.Length -eq 0 -or
        $artifact.Attributes -band [IO.FileAttributes]::ReparsePoint -or
        $artifact.FullName -match '["\r\n]' -or $artifact.Extension -notin @('.exe', '.msi', '.msix', '.msixbundle')) {
        throw 'A regular nonempty Windows package file is required'
    }
    $artifactLock = $null
    $artifactCustody = $null
    $scannerCustody = $null
    $scan = $null
    $stdout = $null
    $stderr = $null
    try {
    # Keep these bytes immutable across signature, hashes, and scanner reads.
    $artifactCustody = Open-InstallerReadCustody $artifact.FullName
    $artifactLock = $artifactCustody.Stream
    $signature = Get-AuthenticodeSignature -LiteralPath $artifactCustody.Path
    if (-not $AssessmentOnly) {
        Assert-InstallerPublisher -Signature $signature -CertificateThumbprint $CertificateThumbprint
    }
    $status = Get-MpComputerStatus -ErrorAction Stop
    $preferences = Get-MpPreference -ErrorAction Stop
    Assert-InstallerScanPolicy -Status $status -Preferences $preferences
    Assert-InstallerLocalThreatPolicy
    $scanner = Join-Path $env:ProgramFiles 'Windows Defender\MpCmdRun.exe'
    $scannerCustody = Open-InstallerReadCustody $scanner
    $scanner = $scannerCustody.Path
    $scannerSignature = Get-AuthenticodeSignature -LiteralPath $scanner -ErrorAction Stop
    if ([string]$scannerSignature.Status -ne 'Valid' -or
        -not (Test-MicrosoftCertificateOrganization $scannerSignature.SignerCertificate)) {
        throw 'Trusted Microsoft Defender scanner unavailable'
    }
    $artifactLock.Position = 0
    $before = (Get-FileHash -Algorithm SHA256 -InputStream $artifactLock).Hash.ToLowerInvariant()
    $scanStarted = [DateTimeOffset]::UtcNow
    $stdout = [IO.Path]::GetTempFileName()
    $stderr = [IO.Path]::GetTempFileName()
        $arguments = '-Scan -ScanType 3 -File "' + $artifactCustody.Path + '" -DisableRemediation'
        $scan = Start-Process -FilePath $scanner -ArgumentList $arguments -WindowStyle Hidden -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
        # Windows PowerShell needs the native handle retained for reliable ExitCode.
        $null = $scan.Handle
        if (-not $scan.WaitForExit($TimeoutSeconds * 1000)) {
            $scan.Kill()
            $scan.WaitForExit()
            throw 'Defender package scan timed out; no release evidence produced'
        }
        # With remediation disabled, exit 0 means no detection. Exit 2 also includes errors.
        if ($scan.ExitCode -ne 0) { throw 'Defender detected a threat or failed; package publication refused' }
        $artifactLock.Position = 0
        $after = (Get-FileHash -Algorithm SHA256 -InputStream $artifactLock).Hash.ToLowerInvariant()
        if ($before -ne $after) { throw 'Package changed during its release scan' }
        Assert-InstallerScanPolicy -Status (Get-MpComputerStatus -ErrorAction Stop) -Preferences (Get-MpPreference -ErrorAction Stop)
        Assert-InstallerLocalThreatPolicy
        return [ordered]@{
            schema = 'leadya-installer-security/v1'
            publication_ready = (-not [bool]$AssessmentOnly)
            artifact_sha256 = $after
            authenticode = [ordered]@{
                status = [string]$signature.Status
                publisher = $(if ($null -ne $signature.SignerCertificate) { $signature.SignerCertificate.Subject } else { $null })
                certificate_thumbprint = $(if ($null -ne $signature.SignerCertificate) { $signature.SignerCertificate.Thumbprint.ToLowerInvariant() } else { $null })
                timestamp_certificate_thumbprint = $(if ($null -ne $signature.TimeStamperCertificate) { $signature.TimeStamperCertificate.Thumbprint.ToLowerInvariant() } else { $null })
            }
            defender = [ordered]@{
                started_at = $scanStarted.ToString('o'); completed_at = [DateTimeOffset]::UtcNow.ToString('o')
                exit_code = 0; signature_version = $status.AntivirusSignatureVersion
                engine_version = $status.AMEngineVersion
                signature_updated_at = ([DateTimeOffset]([DateTime]$status.AntivirusSignatureLastUpdated).ToUniversalTime()).ToString('o')
                scanner_sha256 = (Get-FileHash -Algorithm SHA256 -InputStream $scannerCustody.Stream).Hash.ToLowerInvariant()
                no_exceptions = $true
            }
        }
    }
    finally {
        if ($null -ne $scan) { $scan.Dispose() }
        Close-InstallerReadCustody $scannerCustody
        Close-InstallerReadCustody $artifactCustody
        foreach ($temporaryFile in @($stdout, $stderr)) {
            if ($temporaryFile) { Remove-Item -LiteralPath $temporaryFile -Force -ErrorAction SilentlyContinue }
        }
    }
}
