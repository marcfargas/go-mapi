$ErrorActionPreference = 'Stop'

if (-not ('Ticket569CapabilityNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using System.IO.Pipes;
using System.Security.Principal;
using System.Security.AccessControl;

public sealed class Ticket569CapabilityProcess : IDisposable {
    public IntPtr Handle { get; private set; }
    public IntPtr ThreadHandle { get; private set; }
    public uint ProcessId { get; private set; }
    public long CreationFileTimeUtc { get; private set; }
    public int ExitCode { get; private set; }
    internal Ticket569CapabilityProcess(IntPtr handle, IntPtr thread, uint pid, long created) {
        Handle=handle; ThreadHandle=thread; ProcessId=pid; CreationFileTimeUtc=created;
    }
    public bool Wait(int milliseconds) {
        if (Handle == IntPtr.Zero) throw new ObjectDisposedException("Ticket569CapabilityProcess");
        uint result=Ticket569CapabilityNative.WaitForSingleObject(Handle,(uint)milliseconds);
        if(result==0x102) return false;
        if(result!=0) throw new Win32Exception(Marshal.GetLastWin32Error(),"WaitForSingleObject failed");
        uint code;
        if(!Ticket569CapabilityNative.GetExitCodeProcess(Handle,out code)) throw new Win32Exception(Marshal.GetLastWin32Error(),"GetExitCodeProcess failed");
        ExitCode=unchecked((int)code); return true;
    }
    public void Resume() {
        if(ThreadHandle==IntPtr.Zero)throw new ObjectDisposedException("Ticket569CapabilityProcess");
        uint previous=Ticket569CapabilityNative.ResumeThread(ThreadHandle);
        if(previous==0xffffffff)throw new Win32Exception(Marshal.GetLastWin32Error(),"ResumeThread failed; the assigned process remains contained");
        if(previous!=1)throw new InvalidOperationException("Suspended child did not have exactly one initial suspend count");
    }
    public void Terminate(uint exitCode) {
        if (Handle==IntPtr.Zero) throw new ObjectDisposedException("Ticket569CapabilityProcess");
        if(!Ticket569CapabilityNative.TerminateProcess(Handle,exitCode) && !Wait(0))
            throw new Win32Exception(Marshal.GetLastWin32Error(),"TerminateProcess failed");
    }
    public void Dispose() {
        if(ThreadHandle!=IntPtr.Zero){Ticket569CapabilityNative.CloseHandle(ThreadHandle);ThreadHandle=IntPtr.Zero;}
        if(Handle!=IntPtr.Zero){Ticket569CapabilityNative.CloseHandle(Handle);Handle=IntPtr.Zero;}
    }
}

public sealed class Ticket569CapabilityJob : IDisposable {
    public IntPtr Handle { get; private set; }
    public string Name { get; private set; }
    internal Ticket569CapabilityJob(IntPtr handle,string name){Handle=handle;Name=name;}
    public uint ActiveProcesses {
        get {
            if(Handle==IntPtr.Zero) throw new ObjectDisposedException("Ticket569CapabilityJob");
            Ticket569CapabilityNative.JOBOBJECT_BASIC_ACCOUNTING_INFORMATION info;
            uint returned;
            if(!Ticket569CapabilityNative.QueryInformationJobObject(Handle,1,out info,(uint)Marshal.SizeOf(typeof(Ticket569CapabilityNative.JOBOBJECT_BASIC_ACCOUNTING_INFORMATION)),out returned))
                throw new Win32Exception(Marshal.GetLastWin32Error(),"QueryInformationJobObject failed");
            return info.ActiveProcesses;
        }
    }
    public uint LimitFlags { get { return Ticket569CapabilityNative.ReadJobLimitFlags(Handle); } }
    public void SetDacl(string sddl){
        if(Handle==IntPtr.Zero)throw new ObjectDisposedException("Ticket569CapabilityJob");
        RawSecurityDescriptor descriptor=new RawSecurityDescriptor(sddl);
        byte[] bytes=new byte[descriptor.BinaryLength];descriptor.GetBinaryForm(bytes,0);
        if(!Ticket569CapabilityNative.SetKernelObjectSecurity(Handle,4,bytes))throw new Win32Exception(Marshal.GetLastWin32Error(),"Could not set Job Object DACL");
    }
    public void Terminate(uint exitCode){
        if(Handle==IntPtr.Zero) throw new ObjectDisposedException("Ticket569CapabilityJob");
        if(!Ticket569CapabilityNative.TerminateJobObject(Handle,exitCode)) throw new Win32Exception(Marshal.GetLastWin32Error(),"TerminateJobObject failed");
    }
    public bool Wait(int milliseconds){
        if(Handle==IntPtr.Zero) throw new ObjectDisposedException("Ticket569CapabilityJob");
        uint result=Ticket569CapabilityNative.WaitForSingleObject(Handle,(uint)milliseconds);
        if(result==0) return true;
        if(result==0x102) return false;
        throw new Win32Exception(Marshal.GetLastWin32Error(),"Job handle wait failed");
    }
    public void Dispose(){if(Handle!=IntPtr.Zero){Ticket569CapabilityNative.CloseHandle(Handle);Handle=IntPtr.Zero;}}
}

public sealed class Ticket569CapabilityGate : IDisposable {
    public IntPtr Handle { get; private set; }
    public string Name { get; private set; }
    internal Ticket569CapabilityGate(IntPtr handle,string name){Handle=handle;Name=name;}
    public bool Wait(int milliseconds){
        if(Handle==IntPtr.Zero)throw new ObjectDisposedException("Ticket569CapabilityGate");
        uint result=Ticket569CapabilityNative.WaitForSingleObject(Handle,(uint)milliseconds);
        if(result==0)return true;
        if(result==0x102)return false;
        throw new Win32Exception(Marshal.GetLastWin32Error(),"Recovery gate wait failed");
    }
    public void Release(){
        if(Handle==IntPtr.Zero)throw new ObjectDisposedException("Ticket569CapabilityGate");
        if(!Ticket569CapabilityNative.SetEvent(Handle))throw new Win32Exception(Marshal.GetLastWin32Error(),"Recovery gate release failed");
    }
    public void SetDacl(string sddl){
        if(Handle==IntPtr.Zero)throw new ObjectDisposedException("Ticket569CapabilityGate");
        RawSecurityDescriptor descriptor=new RawSecurityDescriptor(sddl);
        byte[] bytes=new byte[descriptor.BinaryLength];descriptor.GetBinaryForm(bytes,0);
        if(!Ticket569CapabilityNative.SetKernelObjectSecurity(Handle,4,bytes))throw new Win32Exception(Marshal.GetLastWin32Error(),"Could not set named-event DACL");
    }
    public void Dispose(){if(Handle!=IntPtr.Zero){Ticket569CapabilityNative.CloseHandle(Handle);Handle=IntPtr.Zero;}}
}

public static class Ticket569CapabilityNative {
    // Parse the Windows argv quoting used by Quote(), rejecting unbalanced input.
    // Kept managed so parser regressions can run without Windows; Windows fixtures
    // compare these arguments with actual participant command lines.
    public static string[] SplitCommandLine(string command) {
        if (String.IsNullOrWhiteSpace(command)) throw new ArgumentException("Missing command line");
        var result = new System.Collections.Generic.List<string>();
        int i=0;
        while(i<command.Length){
            while(i<command.Length && Char.IsWhiteSpace(command[i]))i++;
            if(i==command.Length)break;
            var argument=new StringBuilder();bool quoted=false;
            while(i<command.Length && (quoted || !Char.IsWhiteSpace(command[i]))){
                int slashes=0;while(i<command.Length && command[i]=='\\'){slashes++;i++;}
                if(i<command.Length && command[i]=='"'){
                    argument.Append('\\',slashes/2);
                    if((slashes&1)!=0){argument.Append('"');i++;}
                    else{quoted=!quoted;i++;}
                }else{
                    argument.Append('\\',slashes);
                    if(i<command.Length && (quoted || !Char.IsWhiteSpace(command[i])))argument.Append(command[i++]);
                }
            }
            if(quoted)throw new ArgumentException("Unbalanced command line quoting");
            result.Add(argument.ToString());
        }
        return result.ToArray();
    }
    public const uint JOB_OBJECT_QUERY=0x0004;
    public const uint JOB_OBJECT_ASSIGN_PROCESS=0x0001;
    public const uint JOB_OBJECT_TERMINATE=0x0008;
    const uint JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE=0x00002000;
    const uint CREATE_SUSPENDED=0x00000004;
    const uint CREATE_NO_WINDOW=0x08000000;
    const uint CREATE_UNICODE_ENVIRONMENT=0x00000400;
    const uint STILL_ACTIVE=259;

    [StructLayout(LayoutKind.Sequential)] public struct JOBOBJECT_BASIC_ACCOUNTING_INFORMATION {
        public long TotalUserTime; public long TotalKernelTime; public long ThisPeriodTotalUserTime; public long ThisPeriodTotalKernelTime;
        public uint TotalPageFaultCount; public uint TotalProcesses; public uint ActiveProcesses; public uint TotalTerminatedProcesses;
    }
    [StructLayout(LayoutKind.Sequential)] public struct IO_COUNTERS { public ulong ReadOperationCount,WriteOperationCount,OtherOperationCount,ReadTransferCount,WriteTransferCount,OtherTransferCount; }
    [StructLayout(LayoutKind.Sequential)] public struct JOBOBJECT_BASIC_LIMIT_INFORMATION {
        public long PerProcessUserTimeLimit,PerJobUserTimeLimit; public uint LimitFlags; public UIntPtr MinimumWorkingSetSize,MaximumWorkingSetSize;
        public uint ActiveProcessLimit; public UIntPtr Affinity; public uint PriorityClass,SchedulingClass;
    }
    [StructLayout(LayoutKind.Sequential)] public struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION {
        public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation; public IO_COUNTERS IoInfo;
        public UIntPtr ProcessMemoryLimit,JobMemoryLimit,PeakProcessMemoryUsed,PeakJobMemoryUsed;
    }
    [StructLayout(LayoutKind.Sequential)] struct SECURITY_ATTRIBUTES { public int nLength; public IntPtr lpSecurityDescriptor; public int bInheritHandle; }
    [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)] struct STARTUPINFO {
        public int cb; public string lpReserved,lpDesktop,lpTitle; public int dwX,dwY,dwXSize,dwYSize,dwXCountChars,dwYCountChars,dwFillAttribute,dwFlags;
        public short wShowWindow,cbReserved2; public IntPtr lpReserved2,hStdInput,hStdOutput,hStdError;
    }
    [StructLayout(LayoutKind.Sequential)] struct PROCESS_INFORMATION { public IntPtr hProcess,hThread; public uint dwProcessId,dwThreadId; }
    [StructLayout(LayoutKind.Sequential)] struct FILETIME { public uint Low,High; public long ToLong(){return ((long)High<<32)|Low;} }

    [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern IntPtr CreateJobObjectW(ref SECURITY_ATTRIBUTES sa,string name);
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool SetInformationJobObject(IntPtr job,int infoClass,IntPtr info,uint length);
    [DllImport("kernel32.dll",SetLastError=true)] public static extern bool QueryInformationJobObject(IntPtr job,int infoClass,out JOBOBJECT_BASIC_ACCOUNTING_INFORMATION info,uint length,out uint returned);
    [DllImport("kernel32.dll",SetLastError=true)] public static extern bool QueryInformationJobObject(IntPtr job,int infoClass,IntPtr info,uint length,out uint returned);
    [DllImport("kernel32.dll",SetLastError=true)] public static extern bool TerminateJobObject(IntPtr job,uint exitCode);
    [DllImport("kernel32.dll",SetLastError=true)] public static extern bool TerminateProcess(IntPtr process,uint exitCode);
    [DllImport("kernel32.dll",SetLastError=true)] public static extern uint WaitForSingleObject(IntPtr handle,uint milliseconds);
    [DllImport("kernel32.dll",SetLastError=true)] public static extern bool GetExitCodeProcess(IntPtr process,out uint code);
    [DllImport("kernel32.dll",EntryPoint="SetLastError")] static extern void SetLastError(uint error);
    [DllImport("kernel32.dll",SetLastError=true)] public static extern bool CloseHandle(IntPtr handle);
    [DllImport("kernel32.dll",SetLastError=true)] public static extern bool SetEvent(IntPtr handle);
    [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern IntPtr CreateEventW(ref SECURITY_ATTRIBUTES sa, bool manualReset, bool initialState, string name);
    [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern IntPtr OpenEventW(uint access, bool inherit, string name);
    [DllImport("kernel32.dll",SetLastError=true)] static extern IntPtr OpenProcess(uint access,bool inherit,uint pid);
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool QueryFullProcessImageNameW(IntPtr process,uint flags,StringBuilder name,ref uint size);
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool AssignProcessToJobObject(IntPtr job,IntPtr process);
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool IsProcessInJob(IntPtr process,IntPtr job,out bool result);
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool ProcessIdToSessionId(uint processId,out uint sessionId);
    [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
    [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool CreateProcessW(string app,StringBuilder command,IntPtr pa,IntPtr ta,bool inherit,uint flags,IntPtr env,string cwd,ref STARTUPINFO startup,out PROCESS_INFORMATION pi);
    [DllImport("kernel32.dll",SetLastError=true)] public static extern uint ResumeThread(IntPtr thread);
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool GetProcessTimes(IntPtr process,out FILETIME creation,out FILETIME exit,out FILETIME kernel,out FILETIME user);
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool GetNamedPipeClientProcessId(IntPtr pipe,out uint clientProcessId);
    [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern IntPtr OpenJobObjectW(uint access,bool inherit,string name);
    [DllImport("advapi32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool ConvertStringSecurityDescriptorToSecurityDescriptorW(string sddl,uint revision,out IntPtr descriptor,out uint size);
    [DllImport("advapi32.dll",SetLastError=true)] public static extern bool SetKernelObjectSecurity(IntPtr handle,int securityInformation,byte[] descriptor);
    [DllImport("kernel32.dll",SetLastError=true)] static extern IntPtr LocalFree(IntPtr memory);

    public static Ticket569CapabilityJob CreateJob(string globalName,string sddl) {
        if(String.IsNullOrWhiteSpace(globalName) || !globalName.StartsWith("Global\\",StringComparison.Ordinal)) throw new ArgumentException("Job name must be run-scoped under Global\\");
        IntPtr descriptor;
        uint size;
        if(!ConvertStringSecurityDescriptorToSecurityDescriptorW(sddl,1,out descriptor,out size)) throw new Win32Exception(Marshal.GetLastWin32Error(),"Invalid job-object DACL");
        try {
            SECURITY_ATTRIBUTES sa=new SECURITY_ATTRIBUTES{nLength=Marshal.SizeOf(typeof(SECURITY_ATTRIBUTES)),lpSecurityDescriptor=descriptor,bInheritHandle=0};
            SetLastError(0);
            IntPtr handle=CreateJobObjectW(ref sa,globalName);
            int createError=Marshal.GetLastWin32Error();
            if(handle==IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error(),"CreateJobObject failed");
            if(createError==183){CloseHandle(handle);throw new InvalidOperationException("Run-scoped Job Object name already exists");}
            JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits=new JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
            limits.BasicLimitInformation.LimitFlags=JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
            IntPtr memory=Marshal.AllocHGlobal(Marshal.SizeOf(typeof(JOBOBJECT_EXTENDED_LIMIT_INFORMATION)));
            try {
                Marshal.StructureToPtr(limits,memory,false);
                if(!SetInformationJobObject(handle,9,memory,(uint)Marshal.SizeOf(typeof(JOBOBJECT_EXTENDED_LIMIT_INFORMATION)))){CloseHandle(handle);throw new Win32Exception(Marshal.GetLastWin32Error(),"Could not enable kill-on-close");}
            } finally {Marshal.FreeHGlobal(memory);}
            Ticket569CapabilityJob created=new Ticket569CapabilityJob(handle,globalName);
            if(created.LimitFlags!=JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE){created.Dispose();throw new InvalidOperationException("Job Object kill-on-close/breakaway limits did not read back exactly");}
            return created;
        } finally {LocalFree(descriptor);}
    }
    public static uint ReadJobLimitFlags(IntPtr handle){
        if(handle==IntPtr.Zero)throw new ArgumentException("Job handle is invalid");
        IntPtr memory=Marshal.AllocHGlobal(Marshal.SizeOf(typeof(JOBOBJECT_EXTENDED_LIMIT_INFORMATION)));
        try {uint returned;if(!QueryInformationJobObject(handle,9,memory,(uint)Marshal.SizeOf(typeof(JOBOBJECT_EXTENDED_LIMIT_INFORMATION)),out returned))throw new Win32Exception(Marshal.GetLastWin32Error(),"Query job limits failed");
             JOBOBJECT_EXTENDED_LIMIT_INFORMATION info=(JOBOBJECT_EXTENDED_LIMIT_INFORMATION)Marshal.PtrToStructure(memory,typeof(JOBOBJECT_EXTENDED_LIMIT_INFORMATION));return info.BasicLimitInformation.LimitFlags;} finally {Marshal.FreeHGlobal(memory);}
    }
    public static Ticket569CapabilityProcess OpenIdentity(uint pid,long expectedCreation){
        IntPtr handle=OpenProcess(0x00101001,false,pid);
        if(handle==IntPtr.Zero)throw new Win32Exception(Marshal.GetLastWin32Error(),"Cannot retain exact process handle");
        try{
            FILETIME created,exited,kernel,user;
            if(!GetProcessTimes(handle,out created,out exited,out kernel,out user))throw new Win32Exception(Marshal.GetLastWin32Error());
            if(created.ToLong()!=expectedCreation)throw new InvalidOperationException("Retained process creation identity differs");
            Ticket569CapabilityProcess process=new Ticket569CapabilityProcess(handle,IntPtr.Zero,pid,created.ToLong());
            handle=IntPtr.Zero;return process;
        }finally{if(handle!=IntPtr.Zero)CloseHandle(handle);}
    }
    public static bool ProcessCreationMatches(uint pid,long expected,out long observed){
        const uint access=0x00100000|0x00001000; observed=0;
        IntPtr handle=OpenProcess(access,false,pid); if(handle==IntPtr.Zero)return false;
        try {FILETIME created,exited,kernel,user;if(!GetProcessTimes(handle,out created,out exited,out kernel,out user))return false;observed=created.ToLong();return observed==expected;}finally{CloseHandle(handle);}
    }
    public static bool TerminateProcessIfIdentityMatches(uint pid,long expected,int waitMilliseconds,out long observed,out uint exitCode){
        const uint access=0x00100000|0x00001000|0x00000001; observed=0;exitCode=0;
        IntPtr handle=OpenProcess(access,false,pid);if(handle==IntPtr.Zero)return false;
        try {
            FILETIME created,exited,kernel,user;if(!GetProcessTimes(handle,out created,out exited,out kernel,out user))return false;
            observed=created.ToLong();if(observed!=expected)return false;
            uint status=WaitForSingleObject(handle,0);
            if(status==0)return GetExitCodeProcess(handle,out exitCode);
            if(status!=0x102)return false;
            if(!TerminateProcess(handle,137) && WaitForSingleObject(handle,0)!=0)return false;
            if(WaitForSingleObject(handle,(uint)waitMilliseconds)!=0)return false;
            return GetExitCodeProcess(handle,out exitCode);
        } finally {CloseHandle(handle);}
    }
    public static Ticket569CapabilityJob OpenJob(string globalName,uint access){
        if(String.IsNullOrWhiteSpace(globalName)||!globalName.StartsWith("Global\\",StringComparison.Ordinal))throw new ArgumentException("Job name must be under Global\\");
        IntPtr handle=OpenJobObjectW(access,false,globalName);
        if(handle==IntPtr.Zero)throw new Win32Exception(Marshal.GetLastWin32Error(),"OpenJobObject failed");
        return new Ticket569CapabilityJob(handle,globalName);
    }
    public static Ticket569CapabilityGate CreateGate(string globalName,string sddl){
        if(String.IsNullOrWhiteSpace(globalName)||!globalName.StartsWith("Global\\",StringComparison.Ordinal))throw new ArgumentException("Gate name must be run-scoped under Global\\");
        IntPtr descriptor;uint size;
        if(!ConvertStringSecurityDescriptorToSecurityDescriptorW(sddl,1,out descriptor,out size))throw new Win32Exception(Marshal.GetLastWin32Error(),"Invalid recovery-gate DACL");
        try{
            SECURITY_ATTRIBUTES sa=new SECURITY_ATTRIBUTES{nLength=Marshal.SizeOf(typeof(SECURITY_ATTRIBUTES)),lpSecurityDescriptor=descriptor,bInheritHandle=0};
            SetLastError(0);
            IntPtr handle=CreateEventW(ref sa,true,false,globalName);
            int createError=Marshal.GetLastWin32Error();
            if(handle==IntPtr.Zero)throw new Win32Exception(Marshal.GetLastWin32Error(),"CreateEvent for recovery gate failed");
            if(createError==183){CloseHandle(handle);throw new InvalidOperationException("Run-scoped recovery gate already exists");}
            return new Ticket569CapabilityGate(handle,globalName);
        }finally{LocalFree(descriptor);}
    }
    public static Ticket569CapabilityGate OpenGate(string globalName,uint access){
        if(String.IsNullOrWhiteSpace(globalName)||!globalName.StartsWith("Global\\",StringComparison.Ordinal))throw new ArgumentException("Gate name must be under Global\\");
        IntPtr handle=OpenEventW(access,false,globalName);
        if(handle==IntPtr.Zero)throw new Win32Exception(Marshal.GetLastWin32Error(),"OpenEvent for recovery gate failed");
        return new Ticket569CapabilityGate(handle,globalName);
    }
    public static uint GetPipeClientProcessId(IntPtr pipe){uint pid;if(!GetNamedPipeClientProcessId(pipe,out pid))throw new Win32Exception(Marshal.GetLastWin32Error(),"GetNamedPipeClientProcessId failed");return pid;}
    public static string GetPipeClientSid(NamedPipeServerStream pipe){string sid=null;pipe.RunAsClient(delegate(){using(WindowsIdentity identity=WindowsIdentity.GetCurrent())sid=identity.User.Value;});if(String.IsNullOrEmpty(sid))throw new InvalidOperationException("Could not identify named-pipe client SID");return sid;}
    static void ValidateRetainedProcessCreation(IntPtr process,long expectedCreation){
        if(process==IntPtr.Zero || expectedCreation<=0)throw new ArgumentException("Exact retained process handle/creation is required");
        FILETIME created,exited,kernel,user;
        if(!GetProcessTimes(process,out created,out exited,out kernel,out user))throw new Win32Exception(Marshal.GetLastWin32Error(),"Cannot read retained process creation");
        if(created.ToLong()!=expectedCreation)throw new InvalidOperationException("Retained process creation identity differs");
    }
    public static void AssignRetainedProcess(Ticket569CapabilityJob job,IntPtr process,long expectedCreation){
        if(job==null || job.Handle==IntPtr.Zero)throw new ArgumentException("A retained owner Job handle is required");
        ValidateRetainedProcessCreation(process,expectedCreation);
        if(WaitForSingleObject(process,0)!=0x102)throw new InvalidOperationException("Recovery launcher is not live before owner assignment");
        uint flags=job.LimitFlags;
        if((flags&0x2000)==0 || (flags&0x1800)!=0 || job.ActiveProcesses!=0)throw new InvalidOperationException("Recovery Job must be empty, kill-on-close and deny breakaway before owner assignment");
        if(!AssignProcessToJobObject(job.Handle,process))throw new Win32Exception(Marshal.GetLastWin32Error(),"Owner recovery-launcher assignment failed before gate release");
        ValidateRetainedProcessCreation(process,expectedCreation);
        bool member;if(!IsProcessInJob(process,job.Handle,out member))throw new Win32Exception(Marshal.GetLastWin32Error(),"Cannot verify retained launcher Job membership");
        flags=job.LimitFlags;
        if(!member || job.ActiveProcesses!=1 || (flags&0x2000)==0 || (flags&0x1800)!=0)throw new InvalidOperationException("Owner-assigned recovery launcher containment did not verify before gate release");
    }
    public static bool StopRetainedProcess(IntPtr process,long expectedCreation,int waitMilliseconds){
        if(waitMilliseconds<0 || waitMilliseconds>30000)throw new ArgumentOutOfRangeException("waitMilliseconds");
        ValidateRetainedProcessCreation(process,expectedCreation);
        uint state=WaitForSingleObject(process,0);
        if(state==0)return true;
        if(state!=0x102)throw new Win32Exception(Marshal.GetLastWin32Error(),"Cannot query retained launcher exit");
        if(!TerminateProcess(process,137) && WaitForSingleObject(process,0)!=0)throw new Win32Exception(Marshal.GetLastWin32Error(),"Cannot terminate exact retained launcher");
        state=WaitForSingleObject(process,(uint)waitMilliseconds);
        if(state==0)return true;
        if(state==0x102)return false;
        throw new Win32Exception(Marshal.GetLastWin32Error(),"Cannot wait exact retained launcher exit");
    }
    public static Ticket569CapabilityProcess StartSuspendedInJob(Ticket569CapabilityJob job,string executable,string[] arguments,string workingDirectory,string expectedSID,int expectedSessionId,bool leaveSuspended){
        return StartSuspendedInJob(job,executable,arguments,workingDirectory,expectedSID,expectedSessionId,leaveSuspended,false);
    }
    public static Ticket569CapabilityProcess StartSuspendedInJob(Ticket569CapabilityJob job,string executable,string[] arguments,string workingDirectory,string expectedSID,int expectedSessionId,bool leaveSuspended,bool inheritExistingJob){
        if(job==null||job.Handle==IntPtr.Zero)throw new ArgumentException("A live Job Object is required");
        if(String.IsNullOrWhiteSpace(executable)||!System.IO.File.Exists(executable))throw new System.IO.FileNotFoundException("Process executable not found",executable);
        if(inheritExistingJob){
            uint flags=job.LimitFlags;
            if(!IsCurrentProcessInJob(job) || job.ActiveProcesses!=1 || (flags&0x2000)==0 || (flags&0x1800)!=0)throw new InvalidOperationException("Recovery parent must be the sole contained process with kill-on-close and no breakaway");
        }
        StringBuilder command=new StringBuilder(Quote(executable));
        foreach(string arg in arguments)command.Append(' ').Append(Quote(arg));
        STARTUPINFO startup=new STARTUPINFO(); startup.cb=Marshal.SizeOf(typeof(STARTUPINFO));
        PROCESS_INFORMATION pi;
        if(!CreateProcessW(executable,command,IntPtr.Zero,IntPtr.Zero,false,CREATE_SUSPENDED|CREATE_NO_WINDOW|CREATE_UNICODE_ENVIRONMENT,IntPtr.Zero,workingDirectory,ref startup,out pi))
            throw new Win32Exception(Marshal.GetLastWin32Error(),"CreateProcess suspended failed");
        try {
            if(!inheritExistingJob && !AssignProcessToJobObject(job.Handle,pi.hProcess))throw new Win32Exception(Marshal.GetLastWin32Error(),"AssignProcessToJobObject failed; process was never resumed");
            FILETIME created,exited,kernel,user;
            if(!GetProcessTimes(pi.hProcess,out created,out exited,out kernel,out user))throw new Win32Exception(Marshal.GetLastWin32Error(),"GetProcessTimes failed");
            string inheritedSID=WindowsIdentity.GetCurrent().User.Value;
            uint childSession;if(!ProcessIdToSessionId(pi.dwProcessId,out childSession))throw new Win32Exception(Marshal.GetLastWin32Error(),"ProcessIdToSessionId failed for suspended child");
            bool inJob;if(!IsProcessInJob(pi.hProcess,job.Handle,out inJob))throw new Win32Exception(Marshal.GetLastWin32Error(),"IsProcessInJob failed for suspended child");
            if(!String.Equals(expectedSID,inheritedSID,StringComparison.Ordinal)||childSession!=(uint)expectedSessionId||!inJob||(inheritExistingJob && job.ActiveProcesses!=2))throw new InvalidOperationException("Suspended child token SID/session or Job Object assignment did not match the required identity; child was never resumed");
            Ticket569CapabilityProcess child=new Ticket569CapabilityProcess(pi.hProcess,pi.hThread,pi.dwProcessId,created.ToLong());
            if(!leaveSuspended)child.Resume();
            // Transfer both handles only after every operation that can fail. The catch
            // block owns and closes the original handles on every earlier failure.
            pi.hProcess=IntPtr.Zero;
            pi.hThread=IntPtr.Zero;
            return child;
        } catch {
            if(pi.hProcess!=IntPtr.Zero){TerminateProcess(pi.hProcess,1);WaitForSingleObject(pi.hProcess,5000);CloseHandle(pi.hProcess);}
            if(pi.hThread!=IntPtr.Zero)CloseHandle(pi.hThread);
            throw;
        }
    }
    public static void AssignCurrentProcess(Ticket569CapabilityJob job){
        if(job==null||job.Handle==IntPtr.Zero)throw new ArgumentException("A live recovery Job Object is required");
        if(!AssignProcessToJobObject(job.Handle,GetCurrentProcess()))throw new Win32Exception(Marshal.GetLastWin32Error(),"Assigning recovery launcher to its supervisor-created Job Object failed");
    }
    public static bool IsCurrentProcessInJob(Ticket569CapabilityJob job){
        if(job==null||job.Handle==IntPtr.Zero)throw new ArgumentException("A live Job Object is required");
        bool result;if(!IsProcessInJob(GetCurrentProcess(),job.Handle,out result))throw new Win32Exception(Marshal.GetLastWin32Error(),"IsProcessInJob failed");return result;
    }
    public static bool IsProcessInJobById(uint pid,Ticket569CapabilityJob job){
        if(job==null||job.Handle==IntPtr.Zero)throw new ArgumentException("A live Job Object is required");
        IntPtr process=OpenProcess(0x1000,false,pid);
        if(process==IntPtr.Zero)throw new Win32Exception(Marshal.GetLastWin32Error(),"OpenProcess for Job Object membership check failed");
        try{bool result;if(!IsProcessInJob(process,job.Handle,out result))throw new Win32Exception(Marshal.GetLastWin32Error(),"IsProcessInJob for child failed");return result;}
        finally{CloseHandle(process);}
    }
    static string Quote(string value){
        if(value==null)return "\"\"";
        StringBuilder b=new StringBuilder("\""); int slashes=0;
        foreach(char c in value){if(c=='\\'){slashes++;continue;} if(c=='\"'){b.Append('\\',slashes*2+1).Append('"');slashes=0;continue;} b.Append('\\',slashes).Append(c);slashes=0;}
        b.Append('\\',slashes*2).Append('"');return b.ToString();
    }
}
'@ -ErrorAction Stop
}

function New-HostedCapabilityJob {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Name,[Parameter(Mandatory)][string] $DaclSddl)
    [Ticket569CapabilityNative]::CreateJob($Name,$DaclSddl)
}
function Open-HostedCapabilityJob {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Name,[uint32] $Access = 0x000C)
    [Ticket569CapabilityNative]::OpenJob($Name,$Access)
}
function New-HostedCapabilityGate {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Name,[Parameter(Mandatory)][string] $DaclSddl)
    [Ticket569CapabilityNative]::CreateGate($Name,$DaclSddl)
}
function Open-HostedCapabilityGate {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Name,[uint32] $Access = 0x00100000)
    [Ticket569CapabilityNative]::OpenGate($Name,$Access)
}
function Set-HostedCapabilityGateDacl {
    [CmdletBinding()]
    param([Parameter(Mandatory)][Ticket569CapabilityGate] $Gate,[Parameter(Mandatory)][string] $DaclSddl)
    $Gate.SetDacl($DaclSddl)
}
function Set-HostedCapabilityFailureEvent {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidatePattern('^Global\\Ticket569-[a-f0-9]{32}-failure$')][string] $Name)
    $event=Open-HostedCapabilityGate -Name $Name -Access 0x0002
    try{$event.Release()}finally{$event.Dispose()}
}

function Set-HostedCapabilityJobDacl {
    [CmdletBinding()]
    param([Parameter(Mandatory)][Ticket569CapabilityJob] $Job,[Parameter(Mandatory)][string] $DaclSddl)
    $Job.SetDacl($DaclSddl)
}
function Add-CurrentProcessToHostedCapabilityJob {
    [CmdletBinding()]
    param([Parameter(Mandatory)][Ticket569CapabilityJob] $Job)
    [Ticket569CapabilityNative]::AssignCurrentProcess($Job)
}
function Test-CurrentProcessInHostedCapabilityJob {
    [CmdletBinding()]
    param([Parameter(Mandatory)][Ticket569CapabilityJob] $Job)
    [Ticket569CapabilityNative]::IsCurrentProcessInJob($Job)
}
function Test-HostedCapabilityProcessInJob {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateRange(1,4294967295)][uint32] $ProcessId,
          [Parameter(Mandatory)][ValidatePattern('^Global\\Ticket569-[A-Za-z0-9-]+$')][string] $JobName)
    $job=Open-HostedCapabilityJob -Name $JobName -Access 0x0004
    try{[Ticket569CapabilityNative]::IsProcessInJobById($ProcessId,$job)}finally{$job.Dispose()}
}
function Start-HostedCapabilityProcess {
    [CmdletBinding()]
    param([Parameter(Mandatory)][Ticket569CapabilityJob] $Job,[Parameter(Mandatory)][string] $Executable,
          [string[]] $ArgumentList = @(),[string] $WorkingDirectory = $PWD.Path,[switch] $LeaveSuspended,[switch] $InheritExistingJob)
    $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $session=[Diagnostics.Process]::GetCurrentProcess().SessionId
    [Ticket569CapabilityNative]::StartSuspendedInJob($Job,$Executable,$ArgumentList,$WorkingDirectory,$sid,$session,[bool]$LeaveSuspended,[bool]$InheritExistingJob)
}
function Add-HostedCapabilityRetainedProcessToJob {
    [CmdletBinding()]
    param([Parameter(Mandatory)][Ticket569CapabilityJob]$Job,[Parameter(Mandatory)][IntPtr]$ProcessHandle,[Parameter(Mandatory)][long]$CreationFileTimeUtc)
    [Ticket569CapabilityNative]::AssignRetainedProcess($Job,$ProcessHandle,$CreationFileTimeUtc)
}
function Stop-HostedCapabilityRetainedProcess {
    [CmdletBinding()]
    param([Parameter(Mandatory)][IntPtr]$ProcessHandle,[Parameter(Mandatory)][long]$CreationFileTimeUtc,[ValidateRange(0,30000)][int]$WaitMilliseconds=5000)
    [Ticket569CapabilityNative]::StopRetainedProcess($ProcessHandle,$CreationFileTimeUtc,$WaitMilliseconds)
}
function Open-HostedCapabilityProcessIdentity {
    [CmdletBinding()]
    param([Parameter(Mandatory)][uint32]$ProcessId,[Parameter(Mandatory)][long]$CreationFileTimeUtc)
    [Ticket569CapabilityNative]::OpenIdentity($ProcessId,$CreationFileTimeUtc)
}

function Stop-HostedCapabilityProcessIdentity {
    [CmdletBinding()]
    param([Parameter(Mandatory)][uint32] $ProcessId,[Parameter(Mandatory)][long] $CreationFileTimeUtc,[ValidateRange(0,30000)][int] $WaitMilliseconds = 5000)
    $observed=[long]0
    $exit=[uint32]0
    $terminated=[Ticket569CapabilityNative]::TerminateProcessIfIdentityMatches($ProcessId,$CreationFileTimeUtc,$WaitMilliseconds,[ref]$observed,[ref]$exit)
    [pscustomobject]@{ terminated=$terminated; observedCreationFileTimeUtc=$observed; exitCode=$exit }
}

function Test-HostedCapabilityProcessIdentity {
    [CmdletBinding()]
    param([Parameter(Mandatory)][uint32] $ProcessId,[Parameter(Mandatory)][long] $CreationFileTimeUtc)
    $observed=[long]0
    $matches=[Ticket569CapabilityNative]::ProcessCreationMatches($ProcessId,$CreationFileTimeUtc,[ref]$observed)
    [pscustomobject]@{ matches=$matches; observedCreationFileTimeUtc=$observed }
}
function Get-HostedCapabilityPipeClientProcessId {
    [CmdletBinding()]
    param([Parameter(Mandatory)][IntPtr] $PipeHandle)
    [Ticket569CapabilityNative]::GetPipeClientProcessId($PipeHandle)
}
function Get-HostedCapabilityPipeClientSid {
    [CmdletBinding()]
    param([Parameter(Mandatory)][IO.Pipes.NamedPipeServerStream] $Pipe)
    [Ticket569CapabilityNative]::GetPipeClientSid($Pipe)
}
Export-ModuleMember -Function Add-HostedCapabilityRetainedProcessToJob, Stop-HostedCapabilityRetainedProcess, Open-HostedCapabilityProcessIdentity, New-HostedCapabilityJob, Open-HostedCapabilityJob, New-HostedCapabilityGate, Open-HostedCapabilityGate, Set-HostedCapabilityGateDacl, Set-HostedCapabilityFailureEvent, Set-HostedCapabilityJobDacl, Start-HostedCapabilityProcess, Add-CurrentProcessToHostedCapabilityJob, Test-CurrentProcessInHostedCapabilityJob, Test-HostedCapabilityProcessInJob, Test-HostedCapabilityProcessIdentity, Stop-HostedCapabilityProcessIdentity, Get-HostedCapabilityPipeClientProcessId, Get-HostedCapabilityPipeClientSid
function Get-HostedCapabilityRecoveryLauncher {
    [CmdletBinding()]
    param([Parameter(Mandatory)][uint32[]]$ProcessIds,[string]$ExpectedSID,[int]$ExpectedSessionId,[string]$Executable,[string]$ScriptPath,[string]$RunId,[string]$SourceSHA,[string]$LauncherSHA256,[string]$WorkerSHA256,[string]$GateName)
    if($ProcessIds.Count -ne 1){throw 'Recovery launch requires exactly one candidate process; duplicates are not authorized'}
    $process=Get-Process -Id ([int]$ProcessIds[0]) -ErrorAction Stop
    try{
        $null=$process.Handle
        $info=Get-CimInstance Win32_Process -Filter "ProcessId=$($process.Id)" -ErrorAction Stop
        $actualSID=(Invoke-CimMethod -InputObject $info -MethodName GetOwnerSid -ErrorAction Stop).Sid
        $argumentsProven=Test-HostedCapabilityCommandArguments $info.CommandLine @{'-File'=$ScriptPath;'-RunId'=$RunId;'-SourceSHA'=$SourceSHA;'-ExpectedLauncherSHA256'=$LauncherSHA256;'-ExpectedWorkerSHA256'=$WorkerSHA256;'-RecoveryGateName'=$GateName}
        $creation=$process.StartTime.ToUniversalTime().ToFileTimeUtc()
        if($process.HasExited -or $actualSID -cne $ExpectedSID -or $process.SessionId -ne $ExpectedSessionId -or
           [IO.Path]::GetFullPath($process.Path) -cne [IO.Path]::GetFullPath($Executable) -or !$argumentsProven -or
           !(Test-HostedCapabilityProcessIdentity -ProcessId ([uint32]$process.Id) -CreationFileTimeUtc $creation).matches){throw 'Recovery candidate differs from the exact source/run/script/hash/image/SID/session authorization'}
        [pscustomobject]@{Process=$process;CreationFileTimeUtc=$creation;SID=$actualSID;SessionId=$process.SessionId}
        $process=$null
    }finally{if($process){$process.Dispose()}}
}
Export-ModuleMember -Function Get-HostedCapabilityRecoveryLauncher

function Test-HostedCapabilityCommandArguments([string]$CommandLine,[Collections.IDictionary]$Expected) {
    try {
        $arguments=[Ticket569CapabilityNative]::SplitCommandLine($CommandLine)
        foreach($key in $Expected.Keys){
            $found=@();for($i=1;$i -lt $arguments.Length;$i++){if([string]::Equals($arguments[$i],[string]$key,[StringComparison]::OrdinalIgnoreCase)){$found+=,$i}}
            if($found.Count -ne 1 -or $found[0]+1 -ge $arguments.Length -or $arguments[$found[0]+1] -cne [string]$Expected[$key]){return $false}
        }
        return $true
    }catch{return $false}
}
Export-ModuleMember -Function Test-HostedCapabilityCommandArguments
