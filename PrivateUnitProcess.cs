// First-party hidden process transport. Atomic job membership precedes child execution.
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading.Tasks;

public static class PrivateUnitProcess {
  public static bool CleanupVerified { get; private set; }
  [StructLayout(LayoutKind.Sequential)] struct BasicLimits {
    public long ProcessTime, JobTime; public uint Flags;
    public UIntPtr MinWorking, MaxWorking; public uint Active;
    public UIntPtr Affinity; public uint Priority, Scheduling;
  }
  [StructLayout(LayoutKind.Sequential)] struct IoCounters { public ulong A,B,C,D,E,F; }
  [StructLayout(LayoutKind.Sequential)] struct ExtendedLimits {
    public BasicLimits Basic; public IoCounters Io;
    public UIntPtr ProcessMemory, JobMemory, PeakProcess, PeakJob;
  }
  [StructLayout(LayoutKind.Sequential)] struct Accounting {
    public long A,B,C,D; public uint Faults, Total, Active, Terminated;
  }
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] struct Startup {
    public int Size; public string Reserved, Desktop, Title;
    public uint X,Y,XSize,YSize,XChars,YChars,Fill,Flags;
    public ushort Show, ReservedSize; public IntPtr ReservedPointer, Input, Output, Error;
  }
  [StructLayout(LayoutKind.Sequential)] struct StartupEx { public Startup Startup; public IntPtr Attributes; }
  [StructLayout(LayoutKind.Sequential)] struct ProcessInfo { public IntPtr Process,Thread; public uint Id,ThreadId; }
  [StructLayout(LayoutKind.Sequential)] struct Security { public int Size; public IntPtr Descriptor; public int Inherit; }
  [DllImport("kernel32.dll", SetLastError=true)] static extern IntPtr CreateJobObject(IntPtr attributes, string name);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool SetInformationJobObject(IntPtr job,int kind,ref ExtendedLimits limits,int length);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool QueryInformationJobObject(IntPtr job,int kind,out Accounting accounting,int size,IntPtr returned);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool TerminateJobObject(IntPtr job,uint exitCode);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool InitializeProcThreadAttributeList(IntPtr list,int count,uint flags,ref IntPtr size);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool UpdateProcThreadAttribute(IntPtr list,uint flags,IntPtr attribute,IntPtr value,IntPtr size,IntPtr previous,IntPtr returned);
  [DllImport("kernel32.dll")] static extern void DeleteProcThreadAttributeList(IntPtr list);
  [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool CreateProcess(string app,StringBuilder command,IntPtr pa,IntPtr ta,bool inherit,uint flags,IntPtr environment,string directory,ref StartupEx startup,out ProcessInfo info);
  [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern IntPtr CreateFile(string path,uint access,uint sharing,ref Security attributes,uint disposition,uint flags,IntPtr template);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool CloseHandle(IntPtr handle);
  [DllImport("kernel32.dll", SetLastError=true)] static extern uint WaitForSingleObject(IntPtr handle,uint timeout);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool GetExitCodeProcess(IntPtr handle,out uint result);
  static void Check(bool ok) { if(!ok) throw new Win32Exception(Marshal.GetLastWin32Error()); }
  static string Quote(string value) {
    if(value.IndexOf('\0')>=0) throw new ArgumentException("NUL argument");
    var b=new StringBuilder("\""); int slashes=0;
    foreach(char c in value) {
      if(c=='\\') {slashes++;continue;}
      if(c=='\"') b.Append('\\',slashes*2+1); else b.Append('\\',slashes);
      b.Append(c); slashes=0;
    }
    return b.Append('\\',slashes*2).Append('"').ToString();
  }
  public static int Run(string executable,string[] arguments,string directory,string log,int seconds,long maxBytes,IDictionary<string,string> environment) {
    CleanupVerified=false;
    if(seconds<1 || seconds>3600 || maxBytes<1024 || maxBytes>67108864) throw new ArgumentException("Process bounds");
    executable=Path.GetFullPath(executable); directory=Path.GetFullPath(directory);
    if(!File.Exists(executable) || !Directory.Exists(directory)) throw new ArgumentException("Missing executable or directory");
    var command=new StringBuilder(Quote(executable));
    if(String.Equals(Path.GetFileName(executable),"cmd.exe",StringComparison.OrdinalIgnoreCase)) {
      if(arguments.Length!=4 || arguments[0]!="/d" || arguments[1]!="/s" || arguments[2]!="/c" || arguments[3].IndexOf('\0')>=0) throw new ArgumentException("Closed cmd transport");
      command.Append(" /d /s /c ").Append(arguments[3]);
    } else foreach(string arg in arguments) command.Append(' ').Append(Quote(arg));
    IntPtr job=IntPtr.Zero,attrs=IntPtr.Zero,jobValue=IntPtr.Zero,handleValues=IntPtr.Zero,env=IntPtr.Zero,input=IntPtr.Zero;
    ProcessInfo process=new ProcessInfo(); bool initialized=false,created=false,drained=false;
    using(var pipe=new AnonymousPipeServerStream(PipeDirection.In,HandleInheritability.Inheritable))
    using(var output=new FileStream(log,FileMode.CreateNew,FileAccess.Write,FileShare.Read)) {
      Task pump=null; bool cap=false;
      try {
        job=CreateJobObject(IntPtr.Zero,null); Check(job!=IntPtr.Zero);
        var limits=new ExtendedLimits(); limits.Basic.Flags=0x2000;
        Check(SetInformationJobObject(job,9,ref limits,Marshal.SizeOf<ExtendedLimits>()));
        IntPtr size=IntPtr.Zero;
        InitializeProcThreadAttributeList(IntPtr.Zero,2,0,ref size);
        attrs=Marshal.AllocHGlobal(size); Check(InitializeProcThreadAttributeList(attrs,2,0,ref size)); initialized=true;
        jobValue=Marshal.AllocHGlobal(IntPtr.Size); Marshal.WriteIntPtr(jobValue,job);
        Check(UpdateProcThreadAttribute(attrs,0,new IntPtr(0x2000D),jobValue,new IntPtr(IntPtr.Size),IntPtr.Zero,IntPtr.Zero));
        var security=new Security{Size=Marshal.SizeOf<Security>(),Inherit=1};
        input=CreateFile("NUL",0x80000000,3,ref security,3,0,IntPtr.Zero); Check(input!=new IntPtr(-1));
        IntPtr writer=pipe.ClientSafePipeHandle.DangerousGetHandle();
        handleValues=Marshal.AllocHGlobal(IntPtr.Size*2); Marshal.WriteIntPtr(handleValues,0,input); Marshal.WriteIntPtr(handleValues,IntPtr.Size,writer);
        Check(UpdateProcThreadAttribute(attrs,0,new IntPtr(0x20002),handleValues,new IntPtr(IntPtr.Size*2),IntPtr.Zero,IntPtr.Zero));
        var names=new List<string>(environment.Keys); names.Sort(StringComparer.OrdinalIgnoreCase);
        var block=new StringBuilder();
        foreach(string name in names) {
          string value=environment[name];
          if(string.IsNullOrEmpty(name) || name.IndexOfAny(new[]{'=','\0'})>=0 || value.IndexOf('\0')>=0) throw new ArgumentException("Environment entry");
          block.Append(name).Append('=').Append(value).Append('\0');
        }
        block.Append('\0'); env=Marshal.StringToHGlobalUni(block.ToString());
        var startup=new StartupEx(); startup.Startup.Size=Marshal.SizeOf<StartupEx>(); startup.Attributes=attrs;
        startup.Startup.Flags=0x101; startup.Startup.Show=0;
        startup.Startup.Input=input; startup.Startup.Output=writer; startup.Startup.Error=writer;
        Check(CreateProcess(executable,command,IntPtr.Zero,IntPtr.Zero,true,0x08080400,env,directory,ref startup,out process)); created=true;
        pipe.DisposeLocalCopyOfClientHandle();
        pump=Task.Run(()=> {
          byte[] bytes=new byte[65536]; long total=0; int n;
          while((n=pipe.Read(bytes,0,bytes.Length))>0) {
            if(total+n>maxBytes) {cap=true; Check(TerminateJobObject(job,91)); break;}
            output.Write(bytes,0,n); total+=n;
          }
        });
        var watch=Stopwatch.StartNew(); bool timedOut=false;
        while(true) {
          uint result=WaitForSingleObject(process.Process,100);
          if(result==0) break;
          if(result!=258) throw new Win32Exception(Marshal.GetLastWin32Error());
          if(pump.IsFaulted) throw new IOException("Log transport failed",pump.Exception);
          if(watch.Elapsed.TotalSeconds>=seconds) {timedOut=true; Check(TerminateJobObject(job,92)); break;}
        }
        Check(WaitForSingleObject(process.Process,5000)==0);
        uint code; Check(GetExitCodeProcess(process.Process,out code));
        // Descendants are always owned by this anonymous job, including after parent exit.
        Check(TerminateJobObject(job,93));
        watch.Restart();
        while(true) {
          Accounting state; Check(QueryInformationJobObject(job,1,out state,Marshal.SizeOf<Accounting>(),IntPtr.Zero));
          if(state.Active==0) {drained=true;CleanupVerified=true;break;}
          if(watch.Elapsed.TotalSeconds>=5) throw new IOException("Owned children did not stop");
          System.Threading.Thread.Sleep(20);
        }
        if(!pump.Wait(5000)) throw new IOException("Owned output did not close");
        output.Flush();
        if(timedOut) throw new TimeoutException("Owned command timed out");
        if(cap) throw new IOException("Private log limit exceeded");
        return unchecked((int)code);
      } finally {
        if(created && !drained && job!=IntPtr.Zero) {
          TerminateJobObject(job,94);
          var cleanupWatch=Stopwatch.StartNew();
          while(cleanupWatch.Elapsed.TotalSeconds<5) {
            Accounting state;
            if(QueryInformationJobObject(job,1,out state,Marshal.SizeOf<Accounting>(),IntPtr.Zero) && state.Active==0) {CleanupVerified=true;break;}
            System.Threading.Thread.Sleep(20);
          }
        }
        if(pump!=null && !pump.IsCompleted) {pipe.Dispose(); try {pump.Wait(5000);} catch(AggregateException) {}}
        if(job!=IntPtr.Zero) CloseHandle(job);
        if(process.Thread!=IntPtr.Zero) CloseHandle(process.Thread);
        if(process.Process!=IntPtr.Zero) CloseHandle(process.Process);
        if(input!=IntPtr.Zero && input!=new IntPtr(-1)) CloseHandle(input);
        if(initialized) DeleteProcThreadAttributeList(attrs);
        foreach(IntPtr memory in new[]{attrs,jobValue,handleValues,env}) if(memory!=IntPtr.Zero) Marshal.FreeHGlobal(memory);
      }
    }
  }
}
