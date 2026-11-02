using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

public static class AttachmentNative
{
    const string Target = "go-mapi:oauth-tokens";
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct Credential
    {
        public uint Flags, Type;
        public string TargetName, Comment;
        public long LastWritten;
        public uint CredentialBlobSize;
        public IntPtr CredentialBlob;
        public uint Persist, AttributeCount;
        public IntPtr Attributes;
        public string TargetAlias, UserName;
    }
    [DllImport("advapi32.dll", EntryPoint = "CredWriteW", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool CredWrite(ref Credential credential, uint flags);
    [DllImport("advapi32.dll", EntryPoint = "CredReadW", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool CredRead(string target, uint type, uint flags, out IntPtr credential);
    [DllImport("advapi32.dll", EntryPoint = "CredDeleteW", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool CredDelete(string target, uint type, uint flags);
    [DllImport("advapi32.dll")] static extern void CredFree(IntPtr credential);

    public static bool CredentialExists()
    {
        IntPtr credential;
        if (CredRead(Target, 1, 0, out credential)) { CredFree(credential); return true; }
        int error = Marshal.GetLastWin32Error();
        if (error != 1168) throw new Win32Exception(error);
        return false;
    }
    public static void WriteCredential(string value)
    {
        byte[] bytes = Encoding.UTF8.GetBytes(value);
        IntPtr data = Marshal.AllocHGlobal(bytes.Length);
        try
        {
            Marshal.Copy(bytes, 0, data, bytes.Length);
            Credential credential = new Credential {
                Type = 1, TargetName = Target, CredentialBlobSize = (uint)bytes.Length,
                CredentialBlob = data, Persist = 2, UserName = "oauth-tokens"
            };
            if (!CredWrite(ref credential, 0)) throw new Win32Exception(Marshal.GetLastWin32Error());
        }
        finally { Marshal.FreeHGlobal(data); }
    }
    public static void RemoveCredential()
    {
        if (!CredDelete(Target, 1, 0)) {
            int error = Marshal.GetLastWin32Error();
            if (error != 1168) throw new Win32Exception(error);
        }
    }

    [DllImport("kernel32.dll", EntryPoint = "LoadLibraryW", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern IntPtr LoadLibrary(string path);
    [DllImport("kernel32.dll", CharSet = CharSet.Ansi, SetLastError = true)]
    static extern IntPtr GetProcAddress(IntPtr module, string name);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool FreeLibrary(IntPtr module);
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Ansi)]
    struct Recipient { public uint Reserved, Class; public string Name, Address; public uint EntrySize; public IntPtr Entry; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Ansi)]
    struct Attachment { public uint Reserved, Flags, Position; public string Path, Name; public IntPtr Type; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Ansi)]
    struct Message
    {
        public uint Reserved;
        public string Subject, Body, MessageType, Date, Conversation;
        public uint Flags;
        public IntPtr Originator;
        public uint RecipientCount;
        public IntPtr Recipients;
        public uint FileCount;
        public IntPtr Files;
    }
    [UnmanagedFunctionPointer(CallingConvention.Winapi, CharSet = CharSet.Ansi)]
    delegate uint SendMail(UIntPtr session, UIntPtr ui, ref Message message, uint flags, uint reserved);

    public static uint Send(string dllPath, string root, string subject, string recipient)
    {
        IntPtr dll = LoadLibrary(dllPath);
        if (dll == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
        IntPtr recipients = IntPtr.Zero, files = IntPtr.Zero;
        int initialized = 0, size = Marshal.SizeOf(typeof(Attachment));
        try
        {
            IntPtr entry = GetProcAddress(dll, "MAPISendMail");
            if (entry == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
            SendMail send = (SendMail)Marshal.GetDelegateForFunctionPointer(entry, typeof(SendMail));
            Recipient to = new Recipient { Class = 1, Name = "Synthetic attachment recipient", Address = "SMTP:" + recipient };
            recipients = Marshal.AllocHGlobal(Marshal.SizeOf(to));
            Marshal.StructureToPtr(to, recipients, false);
            files = Marshal.AllocHGlobal(size * 2);
            foreach (string name in new[] { "report.txt", "image.bin" })
            {
                Attachment file = new Attachment { Position = 0xffffffff, Path = System.IO.Path.Combine(root, name), Name = name };
                Marshal.StructureToPtr(file, IntPtr.Add(files, size * initialized), false);
                initialized++;
            }
            Message message = new Message {
                Subject = subject, Body = "Synthetic body", RecipientCount = 1, Recipients = recipients,
                FileCount = 2, Files = files
            };
            return send(UIntPtr.Zero, UIntPtr.Zero, ref message, 0, 0);
        }
        finally
        {
            if (recipients != IntPtr.Zero) { Marshal.DestroyStructure(recipients, typeof(Recipient)); Marshal.FreeHGlobal(recipients); }
            for (int i = 0; i < initialized; i++) Marshal.DestroyStructure(IntPtr.Add(files, size * i), typeof(Attachment));
            if (files != IntPtr.Zero) Marshal.FreeHGlobal(files);
            FreeLibrary(dll);
        }
    }
}

// The launcher owns the worker tree; PID enumeration never grants cleanup authority.
public sealed class AttachmentJob : IDisposable
{
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern IntPtr CreateJobObject(IntPtr attributes, string name);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool TerminateJobObject(IntPtr job, uint exitCode);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool CloseHandle(IntPtr handle);
    IntPtr handle;
    public AttachmentJob()
    {
        handle = CreateJobObject(IntPtr.Zero, null);
        if (handle == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
    }
    public void Assign(IntPtr process)
    {
        if (!AssignProcessToJobObject(handle, process)) throw new Win32Exception(Marshal.GetLastWin32Error());
    }
    public void Dispose()
    {
        if (handle == IntPtr.Zero) return;
        if (!TerminateJobObject(handle, 1)) throw new Win32Exception(Marshal.GetLastWin32Error());
        if (!CloseHandle(handle)) throw new Win32Exception(Marshal.GetLastWin32Error());
        handle = IntPtr.Zero;
    }
}
