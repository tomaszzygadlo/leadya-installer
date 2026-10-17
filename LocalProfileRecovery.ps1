# Read retained LOCAL data only. This helper never executes code from the old profile.
if (-not ('LeadYa.RetainedProfile' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Text;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;
using Microsoft.Win32.SafeHandles;
namespace LeadYa {
    public sealed class RetainedProfile : IDisposable {
        readonly List<SafeFileHandle> pins = new List<SafeFileHandle>();
        readonly List<FileStream> streams = new List<FileStream>();
        public byte[] Configuration { get; private set; }
        [StructLayout(LayoutKind.Sequential)] struct FileInfo {
            public uint Attributes; public System.Runtime.InteropServices.ComTypes.FILETIME Created, Accessed, Written;
            public uint Volume, SizeHigh, SizeLow, Links, IndexHigh, IndexLow;
        }
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        static extern SafeFileHandle CreateFile(string path, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template);
        [DllImport("kernel32.dll", SetLastError=true)] static extern bool GetFileInformationByHandle(SafeFileHandle file, out FileInfo info);
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        static extern uint GetFinalPathNameByHandle(SafeFileHandle file, StringBuilder name, uint size, uint flags);
        [DllImport("advapi32.dll")] static extern uint GetSecurityInfo(SafeFileHandle file, uint type, uint requested,
            out IntPtr owner, out IntPtr group, out IntPtr dacl, out IntPtr sacl, out IntPtr descriptor);
        [DllImport("advapi32.dll")] static extern uint GetSecurityDescriptorLength(IntPtr descriptor);
        [DllImport("kernel32.dll")] static extern IntPtr LocalFree(IntPtr memory);
        static IOException Refused() { return new IOException("LOCAL_RETAINED_PROFILE_REFUSED"); }
        SafeFileHandle Pin(string path, bool directory, bool privateAcl, bool exclusive, bool createNew = false) {
            // READ_CONTROL + FILE_READ_ATTRIBUTES; files also need GENERIC_READ. No write/delete sharing.
            var handle = CreateFile(path, createNew ? 0xC0020080u : (directory ? 0x20080u : 0x80020080u), exclusive ? 0u : 1u,
                IntPtr.Zero, createNew ? 1u : 3u, 0x02200000, IntPtr.Zero);
            if (handle.IsInvalid) { handle.Dispose(); throw Refused(); }
            pins.Add(handle);
            FileInfo info;
            if (!GetFileInformationByHandle(handle, out info) || (info.Attributes & 0x400) != 0 ||
                ((info.Attributes & 0x10) != 0) != directory || (!directory && info.Links != 1)) throw Refused();
            var name = new StringBuilder(32768);
            uint length = GetFinalPathNameByHandle(handle, name, (uint)name.Capacity, 0);
            if (length == 0 || length >= name.Capacity ||
                !String.Equals(name.ToString(), "\\\\?\\" + path, StringComparison.OrdinalIgnoreCase)) throw Refused();
            if (privateAcl) {
                IntPtr owner, group, dacl, sacl, descriptor;
                uint result = GetSecurityInfo(handle, 1, 5, out owner, out group, out dacl, out sacl, out descriptor);
                if (result != 0 || descriptor == IntPtr.Zero) throw Refused();
                try {
                    byte[] bytes = new byte[GetSecurityDescriptorLength(descriptor)];
                    Marshal.Copy(descriptor, bytes, 0, bytes.Length);
                    var acl = new RawSecurityDescriptor(bytes, 0);
                    var allowed = new HashSet<string> { WindowsIdentity.GetCurrent().User.Value, "S-1-5-18", "S-1-5-32-544" };
                    if (acl.Owner == null || !allowed.Contains(acl.Owner.Value) || acl.DiscretionaryAcl == null || acl.DiscretionaryAcl.Count == 0) throw Refused();
                    foreach (GenericAce entry in acl.DiscretionaryAcl) {
                        if ((entry.AceFlags & AceFlags.InheritOnly) != 0) continue;
                        var ace = entry as CommonAce;
                        if (ace == null || ace.AceQualifier != AceQualifier.AccessAllowed || !allowed.Contains(ace.SecurityIdentifier.Value)) throw Refused();
                    }
                } finally { LocalFree(descriptor); }
            }
            return handle;
        }
        byte[] Read(string path, int limit) {
            var handle = Pin(path, false, true, false);
            var stream = new FileStream(handle, FileAccess.Read);
            streams.Add(stream);
            {
                if (stream.Length < 1 || stream.Length > limit) throw Refused();
                byte[] bytes = new byte[(int)stream.Length];
                int offset = 0;
                while (offset < bytes.Length) { int count = stream.Read(bytes, offset, bytes.Length-offset); if (count == 0) throw Refused(); offset += count; }
                return bytes;
            }
        }
        public static void WritePrivateSnapshot(string path, byte[] bytes) {
            using (var proof = new RetainedProfile()) {
                path = Path.GetFullPath(path);
                string root = Path.GetDirectoryName(path);
                var chain = new Stack<string>();
                for (var part = new DirectoryInfo(root); part != null; part = part.Parent) chain.Push(part.FullName);
                while (chain.Count != 0) {
                    string part = chain.Pop();
                    proof.Pin(part, true, String.Equals(part, root, StringComparison.OrdinalIgnoreCase), false);
                }
                // CREATE_NEW plus an exclusive handle: inspect the empty file's effective
                // DACL and identity before any secret, without repairing inherited permissions.
                var handle = proof.Pin(path, false, true, true, true);
                using (var stream = new FileStream(handle, FileAccess.Write)) {
                    stream.Write(bytes, 0, bytes.Length);
                    stream.Flush(true);
                }
            }
        }
        public static RetainedProfile Open(string root, string origin) {
            var result = new RetainedProfile();
            try {
                root = Path.GetFullPath(root).TrimEnd('\\');
                var chain = new Stack<string>();
                for (var part = new DirectoryInfo(root); part != null; part = part.Parent) chain.Push(part.FullName);
                while (chain.Count != 0) { string part = chain.Pop(); result.Pin(part, true, String.Equals(part,root,StringComparison.OrdinalIgnoreCase),false); }
                result.Pin(Path.Combine(root,"bot_files"), true, true, false);
                result.Pin(Path.Combine(root,".leadya-agent-runtime"), true, true, false);
                result.Pin(Path.Combine(root,".leadya-agent-runtime","supervisor.lock"),false,true,true);
                result.Pin(Path.Combine(root,".leadya-agent-runtime","engine.lock"),false,true,true);
                // No backup resurrection or reset/logout bypass.
                if (File.Exists(Path.Combine(root,"client-reset-required.txt"))) throw Refused();
                string marker = new UTF8Encoding(false,true).GetString(result.Read(Path.Combine(root,"leadya-local-install.txt"),16384));
                if (marker.Replace("\r\n","\n") != "LOCAL\n"+root+"\n"+origin+"\n") throw Refused();
                result.Configuration = result.Read(Path.Combine(root,"bot_files","bot.properties"),65536);
                return result;
            } catch { result.Dispose(); throw; }
        }
        public void Dispose() {
            if (Configuration != null) { Array.Clear(Configuration,0,Configuration.Length); Configuration=null; }
            foreach (var stream in streams) stream.Dispose(); streams.Clear();
            for (int i=pins.Count-1;i>=0;--i) pins[i].Dispose(); pins.Clear();
        }
    }
}
'@
}
