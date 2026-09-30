using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Text;
using System.Threading;
using Microsoft.Win32.SafeHandles;
using WixToolset.Dtf.WindowsInstaller;

namespace GoMapi.AdminCustomActions
{
    // Every machine transaction stops the installed suite app before
    // RemoveExistingProducts or any file action replaces or removes it.
    // The app, its interceptor launch and its sign-in startup all refuse to
    // start while the suite admission gate is closed, so the gate is closed
    // first and every exact-image instance in every session is then drained.
    //
    // Success and rollback do not reopen the gate here: the installed
    // resident service is the only writer of 'O' (openHealthySuite). It
    // reopens a closed gate on its one-minute heartbeat after it has proved
    // the installed product healthy and Windows Installer is idle, the same
    // path the final-uninstall fence already relies on after its rollback.
    //
    // Windows Installer records a file as in use while it costs files, before
    // any deferred action can run, and then lists or prompts for every process
    // with the same module name. A best-effort immediate pre-stop therefore
    // closes the installed app before costing. It runs as the installer
    // caller, so it may not reach other users' instances; the deferred stop
    // above stays the only transactional, fail-closed stop.
    public static partial class AdminMigration
    {
        private const string SuiteAppRelativePath = @"go-mapi\user\go-mapi.exe";
        private const string SuiteAppImageName = "go-mapi.exe";
        private const string SuiteAdmissionRelativePath = @"go-mapi\status\suite-admission-v1";
        private static readonly TimeSpan SuiteStopGrace = TimeSpan.FromSeconds(5);
        private static readonly TimeSpan SuiteStopBound = TimeSpan.FromSeconds(30);
        private static readonly TimeSpan SuiteAdmissionLockBound = TimeSpan.FromSeconds(2);
        private static readonly TimeSpan SuitePreStopBound = TimeSpan.FromSeconds(10);

        private const uint GenericRead = 0x80000000;
        private const uint GenericWrite = 0x40000000;
        private const uint FileShareRead = 0x1;
        private const uint FileShareWrite = 0x2;
        private const uint OpenExisting = 3;
        private const uint FileFlagOpenReparsePoint = 0x00200000;
        private const uint FileAttributeDirectory = 0x10;
        private const uint FileAttributeReparsePoint = 0x400;
        private const uint LockfileFailImmediately = 0x1;
        private const uint LockfileExclusiveLock = 0x2;
        private const int ErrorFileNotFound = 2;
        private const int ErrorPathNotFound = 3;
        private const int ErrorInvalidParameter = 87;
        private const int ErrorLockViolation = 33;
        private const uint Th32csSnapProcess = 0x2;
        private const uint ProcessTerminate = 0x0001;
        private const uint ProcessQueryLimitedInformation = 0x1000;
        private const uint Synchronize = 0x00100000;
        private const uint WaitObject0 = 0;
        private const uint WaitTimeout = 0x102;

        [StructLayout(LayoutKind.Sequential)]
        private struct ByHandleFileInformation
        {
            public uint FileAttributes;
            public System.Runtime.InteropServices.ComTypes.FILETIME CreationTime;
            public System.Runtime.InteropServices.ComTypes.FILETIME LastAccessTime;
            public System.Runtime.InteropServices.ComTypes.FILETIME LastWriteTime;
            public uint VolumeSerialNumber;
            public uint FileSizeHigh;
            public uint FileSizeLow;
            public uint NumberOfLinks;
            public uint FileIndexHigh;
            public uint FileIndexLow;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct ProcessEntry32
        {
            public uint Size;
            public uint Usage;
            public uint ProcessId;
            public IntPtr DefaultHeapId;
            public uint ModuleId;
            public uint Threads;
            public uint ParentProcessId;
            public int PriorityClassBase;
            public uint Flags;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)]
            public string ExeFile;
        }

        [DllImport("kernel32.dll", EntryPoint = "CreateFileW", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern SafeFileHandle CreateFileNative(string name, uint access, uint share, IntPtr security,
            uint disposition, uint flags, IntPtr template);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetFileInformationByHandle(SafeFileHandle file, out ByHandleFileInformation information);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool LockFileEx(SafeFileHandle file, uint flags, uint reserved, uint bytesLow, uint bytesHigh,
            ref NativeOverlapped overlapped);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool UnlockFileEx(SafeFileHandle file, uint reserved, uint bytesLow, uint bytesHigh,
            ref NativeOverlapped overlapped);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr CreateToolhelp32Snapshot(uint flags, uint processId);

        [DllImport("kernel32.dll", EntryPoint = "Process32FirstW", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool Process32First(IntPtr snapshot, ref ProcessEntry32 entry);

        [DllImport("kernel32.dll", EntryPoint = "Process32NextW", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool Process32Next(IntPtr snapshot, ref ProcessEntry32 entry);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr OpenProcess(uint access, [MarshalAs(UnmanagedType.Bool)] bool inherit, uint processId);

        [DllImport("kernel32.dll", EntryPoint = "QueryFullProcessImageNameW", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool QueryFullProcessImageName(IntPtr process, uint flags, StringBuilder name, ref uint size);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetProcessTimes(IntPtr process, out long creation, out long exit, out long kernel, out long user);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool ProcessIdToSessionId(uint processId, out uint sessionId);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool TerminateProcess(IntPtr process, uint exitCode);

        // Immediate, authored Return="ignore". It never touches the admission
        // gate, never reports a setup error and always returns success: every
        // instance it cannot open, query or stop is logged by PID, session and
        // Win32 error only and left to the deferred StopSuiteApps.
        [CustomAction]
        public static ActionResult PreStopSuiteApps(Session session)
        {
            var terminated = 0;
            var skipped = 0;
            try
            {
                var root = session["ProgramFiles64Folder"];
                if (string.IsNullOrEmpty(root) || !Path.IsPathRooted(root) || root.StartsWith(@"\\", StringComparison.Ordinal))
                {
                    session.Log("go-mapi suite app pre-stop: no fixed 64-bit Program Files folder; nothing stopped");
                    return ActionResult.Success;
                }
                var image = Path.GetFullPath(Path.Combine(root, SuiteAppRelativePath));
                var debug = WithPrivilege("SeDebugPrivilege", false,
                    () => PreStopInstalledApps(session, image, ref terminated, ref skipped));
                if (!debug)
                    session.Log("go-mapi suite app pre-stop: SeDebugPrivilege is not available to the installer caller");
                if (string.Equals(session["GOMAPI_TEST_FAILURE_POINT"], "pre-stop-throw", StringComparison.OrdinalIgnoreCase))
                    throw new InvalidOperationException("Requested validation failure point: pre-stop-throw");
                session.Log("go-mapi suite app pre-stop: terminated={0} skipped={1}", terminated, skipped);
            }
            catch (Exception error)
            {
                try
                {
                    session.Log("go-mapi suite app pre-stop ignored an error after terminated={0} skipped={1}: {2}: {3}",
                        terminated, skipped, error.GetType().Name, error.Message);
                }
                catch (Exception)
                {
                    // Logging is best effort as well.
                }
            }
            return ActionResult.Success;
        }

        // Terminates every exact-image instance this caller can open, then
        // waits for them within one bound. The second sweep catches an
        // instance started during the first wait. The per-handle poll has no
        // 64-handle limit.
        private static void PreStopInstalledApps(Session session, string image, ref int terminated, ref int skipped)
        {
            var instances = new Dictionary<string, SuiteAppInstance>(StringComparer.Ordinal);
            var reported = new HashSet<string>(StringComparer.Ordinal);
            var deadline = DateTime.UtcNow + SuitePreStopBound;
            try
            {
                for (var pass = 0; pass < 2; pass++)
                {
                    foreach (var item in SweepSuiteApps(image, instances))
                    {
                        if (!reported.Add(item))
                            continue;
                        skipped++;
                        session.Log("go-mapi suite app pre-stop: skipped {0}", item);
                    }
                    foreach (var key in instances.Keys.ToList())
                    {
                        var instance = instances[key];
                        if (instance.Terminated || WaitForSingleObject(instance.Handle, 0) == WaitObject0)
                            continue;
                        if (!TerminateProcess(instance.Handle, 1))
                        {
                            var error = Marshal.GetLastWin32Error();
                            if (WaitForSingleObject(instance.Handle, 0) == WaitObject0)
                                continue;
                            skipped++;
                            session.Log("go-mapi suite app pre-stop: skipped pid {0} session {1} terminate failed ({2})",
                                instance.ProcessId, instance.Session, error);
                            CloseHandle(instance.Handle);
                            instances.Remove(key);
                            continue;
                        }
                        instance.Terminated = true;
                        terminated++;
                    }
                    do
                    {
                        ReapExited(instances);
                        if (instances.Count == 0)
                            break;
                        Thread.Sleep(50);
                    } while (DateTime.UtcNow < deadline);
                }
                foreach (var instance in instances.Values)
                {
                    skipped++;
                    if (instance.Terminated)
                        terminated--;
                    session.Log("go-mapi suite app pre-stop: skipped pid {0} session {1} did not exit within the bound",
                        instance.ProcessId, instance.Session);
                }
            }
            finally
            {
                foreach (var instance in instances.Values)
                    CloseHandle(instance.Handle);
            }
        }

        [CustomAction]
        public static ActionResult StopSuiteApps(Session session)
        {
            return Guard(session, "stop-suite-apps", () =>
            {
                var data = session.CustomActionData;
                var programFiles = RequireFixedRoot(data, "ProgramFiles64");
                var programData = RequireFixedRoot(data, "CommonAppData");
                var failurePoint = data.ContainsKey("FailurePoint") ? data["FailurePoint"] : "";
                var prior = CloseSuiteAdmission(Path.Combine(programData, SuiteAdmissionRelativePath));
                session.Log("go-mapi suite app stop: admission gate prior state {0}, now closed", prior);
                var stopped = DrainSuiteApps(session, Path.Combine(programFiles, SuiteAppRelativePath),
                    string.Equals(failurePoint, "suite-stop-bound", StringComparison.OrdinalIgnoreCase));
                session.Log("go-mapi suite app stop complete: stopped={0}", stopped);
                MaybeFail(data, "after-suite-stop");
            });
        }

        // Deferred actions only see CustomActionData. The MSI directory
        // properties are resolved independently of the custom-action bitness.
        private static string RequireFixedRoot(CustomActionData data, string key)
        {
            var value = data.ContainsKey(key) ? data[key] : null;
            if (string.IsNullOrEmpty(value) || !Path.IsPathRooted(value) || value.StartsWith(@"\\", StringComparison.Ordinal))
                throw new InvalidDataException("Suite app stop requires a fixed local " + key + " root");
            return Path.GetFullPath(value);
        }

        // Returns the prior byte: 'O', 'C' (closed or malformed) or 'A' (no gate).
        // An absent gate already blocks interceptor launch and app startup, so
        // it is not created. An unsafe gate fails closed and is never rewritten.
        private static char CloseSuiteAdmission(string gate)
        {
            foreach (var directory in new[] { Path.GetDirectoryName(Path.GetDirectoryName(gate)), Path.GetDirectoryName(gate) })
            {
                if (!Directory.Exists(directory))
                    return 'A';
                if ((File.GetAttributes(directory) & System.IO.FileAttributes.ReparsePoint) != 0)
                    throw new InvalidDataException("Refusing reparse point on the suite admission path: " + directory);
            }
            using (var handle = CreateFileNative(gate, GenericRead | GenericWrite, FileShareRead | FileShareWrite, IntPtr.Zero,
                OpenExisting, FileFlagOpenReparsePoint, IntPtr.Zero))
            {
                if (handle.IsInvalid)
                {
                    var error = Marshal.GetLastWin32Error();
                    if (error == ErrorFileNotFound || error == ErrorPathNotFound)
                        return 'A';
                    throw new InvalidOperationException("Could not open the suite admission gate: " + error);
                }
                ValidateSuiteAdmission(gate, handle);
                var overlapped = new NativeOverlapped();
                var deadline = DateTime.UtcNow + SuiteAdmissionLockBound;
                while (!LockFileEx(handle, LockfileExclusiveLock | LockfileFailImmediately, 0, 1, 0, ref overlapped))
                {
                    var error = Marshal.GetLastWin32Error();
                    if (error != ErrorLockViolation)
                        throw new InvalidOperationException("Could not lock the suite admission gate: " + error);
                    if (DateTime.UtcNow >= deadline)
                        throw new TimeoutException("Suite admission gate lock is busy");
                    Thread.Sleep(25);
                }
                try
                {
                    ValidateSuiteAdmission(gate, handle);
                    using (var stream = new FileStream(handle, FileAccess.ReadWrite, 1, false))
                    {
                        var prior = 'C';
                        if (stream.Length == 1)
                        {
                            var value = stream.ReadByte();
                            if (value == 'O')
                                prior = 'O';
                        }
                        stream.Position = 0;
                        stream.WriteByte((byte)'C');
                        stream.SetLength(1);
                        stream.Flush(true);
                        return prior;
                    }
                }
                finally
                {
                    if (!handle.IsClosed)
                        UnlockFileEx(handle, 0, 1, 0, ref overlapped);
                }
            }
        }

        // Mirrors the resident service's validateFile/verifySuiteAdmissionACL.
        private static void ValidateSuiteAdmission(string gate, SafeFileHandle handle)
        {
            ByHandleFileInformation information;
            if (!GetFileInformationByHandle(handle, out information))
                throw new InvalidOperationException("Could not inspect the suite admission gate: " + Marshal.GetLastWin32Error());
            if ((information.FileAttributes & (FileAttributeReparsePoint | FileAttributeDirectory)) != 0 || information.NumberOfLinks != 1)
                throw new InvalidDataException("Suite admission gate is not a single regular protected file");
            var security = File.GetAccessControl(gate, AccessControlSections.Owner | AccessControlSections.Access);
            var descriptor = new RawSecurityDescriptor(security.GetSecurityDescriptorBinaryForm(), 0);
            var owner = descriptor.Owner == null ? null : descriptor.Owner.Value;
            if (owner != "S-1-5-18" && owner != "S-1-5-32-544")
                throw new InvalidDataException("Suite admission gate has an untrusted owner");
            if (descriptor.DiscretionaryAcl == null)
                throw new InvalidDataException("Suite admission gate lacks a DACL");
            const int writeMask = 0x2 | 0x4 | 0x10 | 0x100 | 0x10000 | 0x40000 | 0x80000 | 0x40000000 | 0x10000000;
            foreach (GenericAce ace in descriptor.DiscretionaryAcl)
            {
                if (ace.AceType == AceType.AccessDenied)
                    continue;
                var allowed = ace as CommonAce;
                if (ace.AceType != AceType.AccessAllowed || allowed == null)
                    throw new InvalidDataException("Suite admission gate has an unsupported ACL entry");
                var sid = allowed.SecurityIdentifier.Value;
                if ((allowed.AccessMask & writeMask) != 0 && sid != "S-1-5-18" && sid != "S-1-5-32-544" &&
                    !sid.StartsWith("S-1-5-80-", StringComparison.Ordinal))
                    throw new InvalidDataException("Suite admission gate grants untrusted write access");
            }
        }

        private sealed class SuiteAppInstance
        {
            public IntPtr Handle;
            public uint ProcessId;
            public uint Session;
            public bool Terminated;
        }

        // Drains every process whose image is exactly the installed suite app,
        // in every session, within one bound. The first grace lets instances
        // that observed the closed gate quit; the rest are terminated. A
        // same-name process that cannot be identified is never skipped: it
        // keeps the bound running and ends in a blocked, rolled-back setup.
        private static int DrainSuiteApps(Session session, string image, bool forceBound)
        {
            var instances = new Dictionary<string, SuiteAppInstance>(StringComparer.Ordinal);
            var stopped = 0;
            var start = DateTime.UtcNow;
            var terminated = false;
            try
            {
                while (true)
                {
                    var unresolved = SweepSuiteApps(image, instances);
                    stopped += ReapExited(instances);
                    if (instances.Count == 0 && unresolved.Count == 0 && !forceBound)
                    {
                        // A second sweep catches an instance scheduled across the first.
                        unresolved = SweepSuiteApps(image, instances);
                        stopped += ReapExited(instances);
                        if (instances.Count == 0 && unresolved.Count == 0)
                        {
                            session.Log("go-mapi suite app stop: no running installed app remains (terminated={0})", terminated);
                            return stopped;
                        }
                    }
                    var elapsed = DateTime.UtcNow - start;
                    if (elapsed >= SuiteStopBound || (forceBound && elapsed >= SuiteStopGrace))
                    {
                        var survivors = instances.Values.Select(item => "pid " + item.ProcessId + " session " + item.Session)
                            .Concat(unresolved).ToArray();
                        session.Log("go-mapi suite app stop bound exceeded; unresolved instances: {0}",
                            survivors.Length == 0 ? "(forced by test failure point)" : string.Join("; ", survivors));
                        throw new SetupBlockedException("Installed go-mapi app instances did not stop within the bound",
                            "go-mapi setup could not close the running go-mapi app in every user session, so no changes were made. " +
                            "Close go-mapi or sign out the other users, then run setup again. If the problem continues, " +
                            "create a verbose log (msiexec /i <package> /l*vx <log file>) and send it to your administrator or go-mapi support.");
                    }
                    if (elapsed >= SuiteStopGrace && !forceBound)
                    {
                        foreach (var instance in instances.Values)
                        {
                            if (instance.Terminated || WaitForSingleObject(instance.Handle, 0) == WaitObject0)
                                continue;
                            if (!TerminateProcess(instance.Handle, 1) && WaitForSingleObject(instance.Handle, 0) != WaitObject0)
                            {
                                // Retried on the next pass; the bound still applies.
                                session.Log("go-mapi suite app stop: terminate pid {0} session {1} failed: {2}",
                                    instance.ProcessId, instance.Session, Marshal.GetLastWin32Error());
                                continue;
                            }
                            instance.Terminated = true;
                            terminated = true;
                            session.Log("go-mapi suite app stop: terminated pid {0} session {1}", instance.ProcessId, instance.Session);
                        }
                    }
                    Thread.Sleep(50);
                }
            }
            finally
            {
                foreach (var instance in instances.Values)
                    CloseHandle(instance.Handle);
            }
        }

        private static int ReapExited(Dictionary<string, SuiteAppInstance> instances)
        {
            var exited = instances.Where(item => WaitForSingleObject(item.Value.Handle, 0) == WaitObject0).Select(item => item.Key).ToList();
            foreach (var key in exited)
            {
                CloseHandle(instances[key].Handle);
                instances.Remove(key);
            }
            return exited.Count;
        }

        // Returns descriptions of same-name processes whose image could not be
        // proven. Exact matches are retained by handle, keyed by PID and
        // creation time, so PID reuse cannot hide or redirect a termination.
        private static List<string> SweepSuiteApps(string image, Dictionary<string, SuiteAppInstance> instances)
        {
            var unresolved = new List<string>();
            var snapshot = CreateToolhelp32Snapshot(Th32csSnapProcess, 0);
            if (snapshot == new IntPtr(-1))
                throw new InvalidOperationException("Could not snapshot processes: " + Marshal.GetLastWin32Error());
            try
            {
                var entry = new ProcessEntry32 { Size = (uint)Marshal.SizeOf(typeof(ProcessEntry32)) };
                if (!Process32First(snapshot, ref entry))
                    throw new InvalidOperationException("Could not enumerate processes: " + Marshal.GetLastWin32Error());
                do
                {
                    if (string.Equals(entry.ExeFile, SuiteAppImageName, StringComparison.OrdinalIgnoreCase))
                        InspectSuiteCandidate(entry.ProcessId, image, instances, unresolved);
                    entry.Size = (uint)Marshal.SizeOf(typeof(ProcessEntry32));
                } while (Process32Next(snapshot, ref entry));
            }
            finally
            {
                CloseHandle(snapshot);
            }
            return unresolved;
        }

        private static void InspectSuiteCandidate(uint pid, string image, Dictionary<string, SuiteAppInstance> instances, List<string> unresolved)
        {
            uint session;
            var sessionText = ProcessIdToSessionId(pid, out session) ? session.ToString(CultureInfo.InvariantCulture) : "unknown";
            var handle = OpenProcess(ProcessQueryLimitedInformation | Synchronize | ProcessTerminate, false, pid);
            if (handle == IntPtr.Zero)
            {
                var error = Marshal.GetLastWin32Error();
                if (error != ErrorInvalidParameter) // exited between snapshot and open
                    unresolved.Add("pid " + pid + " session " + sessionText + " cannot be opened (" + error + ")");
                return;
            }
            var retained = false;
            try
            {
                var name = new StringBuilder(32768);
                var length = (uint)name.Capacity;
                if (!QueryFullProcessImageName(handle, 0, name, ref length))
                {
                    var error = Marshal.GetLastWin32Error();
                    if (WaitForSingleObject(handle, 0) != WaitObject0)
                        unresolved.Add("pid " + pid + " session " + sessionText + " image cannot be queried (" + error + ")");
                    return;
                }
                if (!string.Equals(Path.GetFullPath(name.ToString(0, (int)length)), image, StringComparison.OrdinalIgnoreCase))
                    return;
                long creation, exit, kernel, user;
                if (!GetProcessTimes(handle, out creation, out exit, out kernel, out user))
                {
                    unresolved.Add("pid " + pid + " session " + sessionText + " identity cannot be queried (" + Marshal.GetLastWin32Error() + ")");
                    return;
                }
                var key = pid.ToString(CultureInfo.InvariantCulture) + ":" + creation.ToString(CultureInfo.InvariantCulture);
                if (!instances.ContainsKey(key))
                {
                    instances[key] = new SuiteAppInstance { Handle = handle, ProcessId = pid, Session = session };
                    retained = true;
                }
            }
            finally
            {
                if (!retained)
                    CloseHandle(handle);
            }
        }
    }
}
