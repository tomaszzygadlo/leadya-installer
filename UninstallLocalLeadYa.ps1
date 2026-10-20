param(
    [string]$InstallDirectory,
    [string]$PublicOrigin,
    [ValidateSet(0, 1)][int]$RemoveProfile = 1,
    [ValidateSet(0, 1)][int]$RemoveInstallers = 1,
    [string]$ResultFile,
    [int]$OwnerProcessId,
    [long]$OwnerCreationTime,
    [string]$OwnerExecutable,
    [long]$DeadlineTick,
    [switch]$FunctionsOnly
)
$ErrorActionPreference = 'Stop'
$env:PSModulePath = Join-Path $PSHOME 'Modules'
if (-not ('LeadYa.LocalUninstallFiles' -as [type])) {
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.IO.Compression;
using System.Collections.Generic;
using System.Text;
using System.Text.RegularExpressions;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
namespace LeadYa {
    public static class LocalUninstallFiles {
        static SafeWaitHandle owner;
        static ulong deadline;
        [StructLayout(LayoutKind.Sequential)] struct Info {
            public uint Attributes; public System.Runtime.InteropServices.ComTypes.FILETIME Created, Accessed, Written;
            public uint Volume, SizeHigh, SizeLow, Links, IndexHigh, IndexLow;
        }
        [StructLayout(LayoutKind.Sequential)] struct Basic { public long Created, Accessed, Written, Changed; public uint Attributes; }
        [StructLayout(LayoutKind.Sequential)] struct Disposition { [MarshalAs(UnmanagedType.Bool)] public bool Delete; }
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        static extern SafeFileHandle CreateFile(string path, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template);
        [DllImport("kernel32.dll", SetLastError=true)] static extern bool GetFileInformationByHandle(SafeFileHandle file, out Info info);
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        static extern uint GetFinalPathNameByHandle(SafeFileHandle file, StringBuilder path, uint size, uint flags);
        [DllImport("kernel32.dll", EntryPoint="SetFileInformationByHandle", SetLastError=true)]
        static extern bool SetBasic(SafeFileHandle file, int type, ref Basic info, uint size);
        [DllImport("kernel32.dll", EntryPoint="SetFileInformationByHandle", SetLastError=true)]
        static extern bool SetDisposition(SafeFileHandle file, int type, ref Disposition info, uint size);
        [DllImport("kernel32.dll", SetLastError=true)]
        static extern bool ReadFile(SafeFileHandle file, byte[] bytes, uint count, out uint read, IntPtr overlapped);
        [DllImport("kernel32.dll", SetLastError=true)] static extern SafeWaitHandle OpenProcess(uint access, bool inherit, int pid);
        [DllImport("kernel32.dll", SetLastError=true)] static extern bool GetProcessTimes(SafeWaitHandle process, out long created, out long exited, out long kernel, out long user);
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool QueryFullProcessImageName(SafeWaitHandle process, uint flags, StringBuilder image, ref uint size);
        [DllImport("kernel32.dll")] static extern uint WaitForSingleObject(SafeWaitHandle process, uint milliseconds);
        [DllImport("kernel32.dll")] static extern ulong GetTickCount64();
        [DllImport("shell32.dll")] static extern int SHGetKnownFolderPath([MarshalAs(UnmanagedType.LPStruct)] Guid id, uint flags, IntPtr token, out IntPtr path);
        sealed class Node : IDisposable {
            public SafeFileHandle Handle; public string Path; public uint Attributes;
            public void Dispose() { Handle.Dispose(); }
        }
        public static void ClearOwner() { if (owner != null) { owner.Dispose(); owner=null; } }
        public static long DeadlineIn(int seconds) { return (long)GetTickCount64() + seconds * 1000L; }
        public static void ConfigureOwner(int pid, long creationTime, string executable, long deadlineTick) {
            ClearOwner();
            var process = OpenProcess(0x101000, false, pid);
            long created, exited, kernel, user; uint size=32768; var image = new StringBuilder((int)size);
            if (process.IsInvalid || !GetProcessTimes(process, out created, out exited, out kernel, out user) || created != creationTime ||
                !QueryFullProcessImageName(process, 0, image, ref size) || !String.Equals(image.ToString(), executable, StringComparison.OrdinalIgnoreCase) ||
                WaitForSingleObject(process, 0) != 258) { process.Dispose(); throw new IOException("LOCAL_UNINSTALL_OWNER"); }
            owner=process;
            deadline=(ulong)Math.Max(0, deadlineTick);
            CheckOwner();
        }
        public static void CheckOwner() {
            if (owner == null) return; // Library-only native fixtures do not launch a background worker.
            if (WaitForSingleObject(owner, 0) != 258) throw new IOException("LOCAL_UNINSTALL_OWNER");
            if (GetTickCount64() >= deadline) throw new IOException("LOCAL_UNINSTALL_DEADLINE");
        }
        static string Full(string path) {
            path = System.IO.Path.GetFullPath(path).TrimEnd('\\');
            if (!Regex.IsMatch(path, @"^[A-Za-z]:\\") || path.Length <= 3 || path.Substring(2).Contains(":")) throw new IOException("LOCAL_UNINSTALL_PATH");
            return path;
        }
        static Node Pin(string path, bool directory, bool deleting, bool reading) {
            CheckOwner();
            uint access = 0x20080u | (deleting ? 0x10100u : 0u) | (reading ? 0x80000000u : 0u);
            var handle = CreateFile(@"\\?\" + path, access, directory ? 3u : 1u, IntPtr.Zero, 3, 0x02200000, IntPtr.Zero);
            if (handle.IsInvalid) { handle.Dispose(); throw new IOException("LOCAL_UNINSTALL_IN_USE"); }
            try {
                Info info;
                if (!GetFileInformationByHandle(handle, out info)) throw new IOException("LOCAL_UNINSTALL_IN_USE");
                if ((info.Attributes & 0x400) != 0) throw new IOException("LOCAL_UNINSTALL_REPARSE");
                if (((info.Attributes & 0x10) != 0) != directory || (!directory && info.Links != 1)) throw new IOException("LOCAL_UNINSTALL_PATH");
                var final = new StringBuilder(32768);
                uint size = GetFinalPathNameByHandle(handle, final, (uint)final.Capacity, 0);
                if (size == 0 || size >= final.Capacity || !String.Equals(final.ToString(), @"\\?\" + path, StringComparison.OrdinalIgnoreCase)) throw new IOException("LOCAL_UNINSTALL_PATH");
                return new Node { Handle=handle, Path=path, Attributes=info.Attributes };
            } catch { handle.Dispose(); throw; }
        }
        static void Ancestors(string root, List<Node> held) {
            var chain = new Stack<string>();
            for (var directory = Directory.GetParent(root); directory != null; directory = directory.Parent) chain.Push(directory.FullName);
            while (chain.Count != 0) held.Add(Pin(chain.Pop(), true, false, false));
        }
        static void Gather(string root, List<Node> nodes) {
            CheckOwner();
            if (nodes.Count >= 200000) throw new IOException("LOCAL_UNINSTALL_TOO_LARGE");
            var attributes = File.GetAttributes(@"\\?\" + root);
            bool directory = (attributes & FileAttributes.Directory) != 0;
            var node = Pin(root, directory, true, !directory && System.IO.Path.GetFileName(root) == "leadya-local-install.txt");
            nodes.Add(node);
            if (directory) foreach (string child in Directory.EnumerateFileSystemEntries(@"\\?\" + root)) Gather(child.Substring(4), nodes);
        }
        static void Delete(Node node) {
            CheckOwner();
            if ((node.Attributes & 1) != 0) {
                var basic = new Basic { Attributes=node.Attributes & ~1u };
                if (!SetBasic(node.Handle, 0, ref basic, (uint)Marshal.SizeOf(typeof(Basic)))) throw new IOException("LOCAL_UNINSTALL_IN_USE");
            }
            var disposition = new Disposition { Delete=true };
            if (!SetDisposition(node.Handle, 4, ref disposition, (uint)Marshal.SizeOf(typeof(Disposition)))) throw new IOException("LOCAL_UNINSTALL_IN_USE");
            node.Dispose();
        }
        public static void DeleteProfile(string path, string origin) { DeleteProfiles(new string[] { path }, origin); }
        static bool Empty(string path) {
            using (var entries = Directory.EnumerateFileSystemEntries(@"\\?\" + path).GetEnumerator()) { return !entries.MoveNext(); }
        }
        public static void DeleteProfiles(string[] paths, string origin) {
            DeleteProfiles(paths, origin, null);
        }
        // The optional observer is a library test seam; the executable entry point never supplies it.
        public static void DeleteProfiles(string[] paths, string origin, Action<string> beforeDelete) {
            var ancestors = new List<Node>(); var nodes = new List<Node>();
            var roots = new List<Node>(); var proofs = new List<Node>();
            try {
                foreach (string candidate in paths) {
                    string root = Full(candidate);
                    try { File.GetAttributes(@"\\?\" + root); }
                    catch (FileNotFoundException) { continue; }
                    catch (DirectoryNotFoundException) { continue; }
                    Ancestors(root, ancestors);
                    Gather(root, nodes);
                    Node rootNode = nodes.Find(node => String.Equals(node.Path, root, StringComparison.OrdinalIgnoreCase));
                    string marker = System.IO.Path.Combine(root, "leadya-local-install.txt");
                    Node proof = nodes.Find(node => String.Equals(node.Path, marker, StringComparison.OrdinalIgnoreCase));
                    // An empty exact root may remain if removing its final marker succeeded but
                    // removing the directory failed. Never accept a nonempty unmarked profile.
                    if (proof == null && (rootNode.Attributes & 0x10) != 0 &&
                        Empty(root)) {
                        roots.Add(rootNode); proofs.Add(null); continue;
                    }
                    if (proof == null || (proof.Attributes & 0x10) != 0) throw new IOException("LOCAL_UNINSTALL_MARKER");
                    byte[] bytes = new byte[65537]; uint read;
                    if (!ReadFile(proof.Handle, bytes, (uint)bytes.Length, out read, IntPtr.Zero) || read == 0 || read > 65536) throw new IOException("LOCAL_UNINSTALL_MARKER");
                    Encoding encoding = read >= 2 && bytes[0] == 255 && bytes[1] == 254 ? new UnicodeEncoding(false, true, true) :
                        read >= 2 && bytes[0] == 254 && bytes[1] == 255 ? new UnicodeEncoding(true, true, true) : (Encoding)new UTF8Encoding(false, true);
                    string text = encoding.GetString(bytes, 0, (int)read).TrimStart('\uFEFF');
                    string[] lines = text.Replace("\r", "").TrimEnd('\n').Split('\n');
                    if (lines.Length != 3 || lines[0] != "LOCAL" || !String.Equals(lines[1], root, StringComparison.OrdinalIgnoreCase) || lines[2] != origin) throw new IOException("LOCAL_UNINSTALL_MARKER");
                    roots.Add(rootNode); proofs.Add(proof);
                }
                // Every existing descendant and marker is pinned before the first deletion.
                CheckOwner();
                for (int rootIndex=0; rootIndex<roots.Count; rootIndex++) {
                    Node root = roots[rootIndex], proof = proofs[rootIndex];
                    for (int i=nodes.Count-1; i>=0; i--) {
                        Node node = nodes[i];
                        if (node == root || node == proof || !node.Path.StartsWith(root.Path + "\\", StringComparison.OrdinalIgnoreCase)) continue;
                        if (beforeDelete != null) beforeDelete(node.Path);
                        Delete(node);
                    }
                    if (proof != null) { if (beforeDelete != null) beforeDelete(proof.Path); Delete(proof); }
                    if (beforeDelete != null) beforeDelete(root.Path);
                    Delete(root);
                }
            } finally {
                for (int i=nodes.Count-1; i>=0; i--) nodes[i].Dispose();
                for (int i=ancestors.Count-1; i>=0; i--) ancestors[i].Dispose();
            }
        }
        static bool Nsis(Stream stream) {
            byte[] buffer = new byte[1048576]; int count = 0;
            while (count < buffer.Length) { CheckOwner(); int read = stream.Read(buffer, count, buffer.Length-count); if (read == 0) break; count += read; }
            return count > 512 && buffer[0] == 'M' && buffer[1] == 'Z' && Encoding.ASCII.GetString(buffer, 0, count).Contains("NullsoftInst");
        }
        static bool Installer(Node node) {
            string path = node.Path;
            string name = System.IO.Path.GetFileName(path);
            if (!Regex.IsMatch(name, @"^Leadya(?:Vps)?Installer(?:-[A-Z0-9_]+)?(?: \(\d+\))?\.(exe|zip)$", RegexOptions.IgnoreCase)) return false;
            // Read the already-pinned object, without reopening a path or closing its deletion handle.
            using (var alias = new SafeFileHandle(node.Handle.DangerousGetHandle(), false))
            using (var input = new FileStream(alias, FileAccess.Read)) {
              if (input.Length > 8388608) return false;
              if (System.IO.Path.GetExtension(path).Equals(".exe", StringComparison.OrdinalIgnoreCase)) return Nsis(input);
              using (var archive = new ZipArchive(input, ZipArchiveMode.Read)) {
                if (archive.Entries.Count > 8) return false;
                bool executable = false;
                foreach (var entry in archive.Entries) {
                    CheckOwner();
                    if (entry.Length > 8388608) return false;
                    if (!Regex.IsMatch(entry.FullName, @"^LeadyaVpsInstaller-[A-Z0-9_]+\.(exe|txt|manifest)$", RegexOptions.IgnoreCase)) return false;
                    if (entry.FullName.EndsWith(".exe", StringComparison.OrdinalIgnoreCase)) using (var body = entry.Open()) { if (!Nsis(body)) return false; executable = true; }
                }
                return executable;
              }
            }
        }
        public static int DeleteInstallers(string directory) {
            directory = Full(directory); var held = new List<Node>(); int deleted = 0;
            try {
                Ancestors(directory, held); held.Add(Pin(directory, true, false, false));
                foreach (string file in Directory.EnumerateFiles(@"\\?\" + directory)) {
                    string path = file.Substring(4);
                    if (!Regex.IsMatch(System.IO.Path.GetFileName(path), @"^Leadya(?:Vps)?Installer(?:-[A-Z0-9_]+)?(?: \(\d+\))?\.(exe|zip)$", RegexOptions.IgnoreCase)) continue;
                    using (var node = Pin(path, false, true, true)) {
                        bool recognized;
                        try { recognized = Installer(node); } catch (InvalidDataException) { recognized = false; }
                        if (recognized) { Delete(node); deleted++; }
                    }
                }
                return deleted;
            } finally { for (int i=held.Count-1; i>=0; i--) held[i].Dispose(); }
        }
        public static string Downloads() {
            IntPtr path; int result = SHGetKnownFolderPath(new Guid("374DE290-123F-4565-9164-39C4925E467B"), 0, IntPtr.Zero, out path);
            if (result != 0) Marshal.ThrowExceptionForHR(result);
            try { return Marshal.PtrToStringUni(path); } finally { Marshal.FreeCoTaskMem(path); }
        }
    }
}
'@ -ReferencedAssemblies System.IO.Compression
}
function Invoke-LocalUserCleanup([string[]]$Profiles, [string]$Origin, [string]$Downloads, [bool]$Profile, [bool]$Installers) {
    if ($Profile) { [LeadYa.LocalUninstallFiles]::DeleteProfiles($Profiles, $Origin) }
    if ($Installers) { return [LeadYa.LocalUninstallFiles]::DeleteInstallers($Downloads) }
    return 0
}
if ($FunctionsOnly) { return }
$result = 'LOCAL_UNINSTALL_FAILED'
try {
    if (([Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'LOCAL_ELEVATED_RUNTIME' }
    if ([IO.Path]::GetFullPath($ResultFile) -ine (Join-Path $PSScriptRoot 'leadya-user-cleanup-result.txt')) { throw 'LOCAL_UNINSTALL_RESULT' }
    [LeadYa.LocalUninstallFiles]::ConfigureOwner($OwnerProcessId, $OwnerCreationTime, $OwnerExecutable, $DeadlineTick)
    $root = [IO.Path]::GetFullPath($InstallDirectory).TrimEnd('\')
    $uri = [Uri]$PublicOrigin
    if ($root.Length -le 3 -or $root -notmatch '^[A-Za-z]:\\' -or -not $uri.IsAbsoluteUri -or $uri.UserInfo -or $uri.Query -or $uri.Fragment -or $uri.AbsolutePath -ne '/' -or
        ($uri.Scheme -ne 'https' -and -not ($uri.Scheme -eq 'http' -and $uri.IsLoopback))) { throw 'LOCAL_UNINSTALL_BINDING' }
    $hasher = [Security.Cryptography.SHA256]::Create()
    try { $id = ([BitConverter]::ToString($hasher.ComputeHash([Text.Encoding]::UTF8.GetBytes($root.ToUpperInvariant() + "`n" + $PublicOrigin)))).Replace('-', '').ToLowerInvariant() }
    finally { $hasher.Dispose() }
    $profiles = @((Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) ('LeadYa/installations/' + $id)),
        (Join-Path ([Environment]::GetFolderPath('UserProfile')) ('.leadya-client/installations/' + $id)))
    $downloads = if ($RemoveInstallers) { [LeadYa.LocalUninstallFiles]::Downloads() } else { $null }
    $deleted = Invoke-LocalUserCleanup $profiles $PublicOrigin $downloads ([bool]$RemoveProfile) ([bool]$RemoveInstallers)
    $shell = New-Object -ComObject WScript.Shell
    $package = Join-Path $(if ($env:ProgramW6432) { $env:ProgramW6432 } else { $env:ProgramFiles }) ('LeadYaInstallerPackages/' + $id)
    $links = @((Join-Path ([Environment]::GetFolderPath('Desktop')) 'Leadya.lnk'),
        (Join-Path ([Environment]::GetFolderPath('Startup')) 'Leadya.lnk'),
        (Join-Path ([Environment]::GetFolderPath('Programs')) 'Leadya/Leadya.lnk'),
        (Join-Path ([Environment]::GetFolderPath('Programs')) 'Leadya/UninstallLeadya.lnk'))
    foreach ($path in $links) {
        [LeadYa.LocalUninstallFiles]::CheckOwner()
        if (-not [IO.File]::Exists($path)) { continue }
        $link = $shell.CreateShortcut($path)
        if ($link.TargetPath -in @((Join-Path $root 'Uninstall.exe'), (Join-Path $package 'Uninstall.exe'), (Join-Path $package 'LeadyaCheckingProgram.bat')) -or
            $link.Arguments.Contains((Join-Path $package 'LaunchLocalLeadYa.'))) {
            [LeadYa.LocalUninstallFiles]::CheckOwner()
            [IO.File]::Delete($path)
        }
    }
    foreach ($key in @('HKCU:/Environment')) {
        $registeredHome = (Get-ItemProperty -LiteralPath $key -Name LEADYA_HOME -ErrorAction SilentlyContinue).LEADYA_HOME
        if ($registeredHome -in (@($root) + $profiles)) {
            [LeadYa.LocalUninstallFiles]::CheckOwner()
            Remove-ItemProperty -LiteralPath $key -Name LEADYA_HOME
        }
    }
    $result = 'LOCAL_UNINSTALL_OK'
} catch {
    $errorCode = $_.Exception.ToString()
    if ($errorCode -match 'LOCAL_UNINSTALL_[A-Z_]+') { $result = $Matches[0] }
} finally {
    [LeadYa.LocalUninstallFiles]::ClearOwner()
    if ($ResultFile -and [IO.Path]::GetFullPath($ResultFile) -ieq (Join-Path $PSScriptRoot 'leadya-user-cleanup-result.txt')) {
        # The administrator creates this fixed writable result file in a read-only directory.
        # A completion suffix lets NSIS distinguish a complete result from a partial write.
        for ($attempt = 0; $attempt -lt 20; $attempt++) {
            try { $stream = [IO.File]::Open($ResultFile, 'Open', 'Write', 'Read'); break }
            catch [IO.IOException] { if ($attempt -eq 19) { throw }; Start-Sleep -Milliseconds 50 }
        }
        try { $bytes = [Text.Encoding]::ASCII.GetBytes($result + ':END'); $stream.SetLength(0); $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) }
        finally { $stream.Dispose() }
    }
}
if ($result -cne 'LOCAL_UNINSTALL_OK') { exit 12 }
