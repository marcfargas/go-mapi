using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Security.Cryptography;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32;
using Newtonsoft.Json;
using WixToolset.Dtf.WindowsInstaller;

namespace GoMapi.AdminCustomActions
{
    public static class AdminMigration
    {
        private const string ProductName = "go-mapi";
        private const string MailRoot = @"SOFTWARE\Clients\Mail";
        private const string ClientKey = @"SOFTWARE\Clients\Mail\go-mapi";
        private const string InstalledSchema = "go-mapi-installed-interceptor-v1";
        private const string QueueProtocol = "queue-v1";
        private const string JournalSchema = "go-mapi-admin-migration-journal-v1";
        private const string ActiveDllPath = @"%ProgramW6432%\go-mapi\interceptor\%PROCESSOR_ARCHITECTURE%\go-mapi.dll";
        private const string UninstallCleanupKey = @"SOFTWARE\go-mapi\UninstallCleanup";
        private const string VolatileBootKey = @"SOFTWARE\go-mapi\MachineProduct\ServiceBoot";
        private const string SystemUpgradeCode = "{B3C97B33-3F10-47CA-9FA7-24EE3B75E325}";
        private const string SuiteUpgradeCode = "{2E050A24-94A2-4FC9-B176-C5CCC1225FE6}";
        private const uint ErrorNoMoreItems = 259;
        private const uint MachineContext = 4;
        private const uint TokenQuery = 0x0008;
        private const uint TokenAdjustPrivileges = 0x0020;
        private const uint SePrivilegeEnabled = 0x0002;
        private const int ErrorNoToken = 1008;
        private const int ErrorNotAllAssigned = 1300;

        [StructLayout(LayoutKind.Sequential)]
        private struct Luid
        {
            public uint LowPart;
            public int HighPart;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct TokenPrivileges
        {
            public uint PrivilegeCount;
            public Luid Luid;
            public uint Attributes;
        }

        [DllImport("kernel32.dll")]
        private static extern IntPtr GetCurrentThread();

        [DllImport("kernel32.dll")]
        private static extern IntPtr GetCurrentProcess();

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CloseHandle(IntPtr handle);

        [DllImport("advapi32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool OpenThreadToken(IntPtr thread, uint access, [MarshalAs(UnmanagedType.Bool)] bool openAsSelf, out IntPtr token);

        [DllImport("advapi32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);

        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool LookupPrivilegeValue(string systemName, string name, out Luid luid);

        [DllImport("advapi32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool AdjustTokenPrivileges(IntPtr token, [MarshalAs(UnmanagedType.Bool)] bool disableAll,
            ref TokenPrivileges newState, uint bufferLength, out TokenPrivileges previousState, out uint returnLength);

        [DllImport("advapi32.dll", EntryPoint = "AdjustTokenPrivileges", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool RestoreTokenPrivileges(IntPtr token, [MarshalAs(UnmanagedType.Bool)] bool disableAll,
            ref TokenPrivileges newState, uint bufferLength, IntPtr previousState, IntPtr returnLength);

        [DllImport("msi.dll", EntryPoint = "MsiEnumRelatedProductsW", CharSet = CharSet.Unicode)]
        private static extern uint EnumRelatedProducts(string upgradeCode, uint reserved, uint index, StringBuilder productCode);

        [DllImport("msi.dll", EntryPoint = "MsiEnumProductsExW", CharSet = CharSet.Unicode)]
        private static extern uint EnumMachineProduct(string productCode, string userSid, uint context, uint index,
            StringBuilder installedProductCode, out uint installedContext, IntPtr sid, IntPtr sidLength);

        [DllImport("msi.dll", EntryPoint = "MsiGetProductInfoExW", CharSet = CharSet.Unicode)]
        private static extern uint GetMachineProductInfo(string productCode, string userSid, uint context,
            string property, StringBuilder value, ref uint valueLength);

        private static List<string> RelatedMachineProducts(string upgradeCode)
        {
            var products = new List<string>();
            for (uint index = 0; index < 128; index++)
            {
                var code = new StringBuilder(39);
                var result = EnumRelatedProducts(upgradeCode, 0, index, code);
                if (result == ErrorNoMoreItems) return products;
                if (result != 0) throw new InvalidOperationException("Related-product inventory failed: " + result);
                var installed = new StringBuilder(39);
                uint context;
                result = EnumMachineProduct(code.ToString(), null, MachineContext, 0, installed, out context, IntPtr.Zero, IntPtr.Zero);
                if (result != 0 || context != MachineContext ||
                    !string.Equals(code.ToString(), installed.ToString(), StringComparison.OrdinalIgnoreCase))
                    throw new InvalidOperationException("Related product has ambiguous or non-machine installation context: " + code);
                // Both enumeration APIs include advertised products. An advertised
                // registration is not an installed source that can be migrated.
                var state = new StringBuilder(16);
                uint stateLength = 16;
                result = GetMachineProductInfo(code.ToString(), null, MachineContext, "State", state, ref stateLength);
                if (result != 0 || state.ToString() != "5")
                    throw new InvalidOperationException("Related machine product is not installed or its state is ambiguous: " + code);
                products.Add(code.ToString().ToUpperInvariant());
            }
            throw new InvalidOperationException("Related-product inventory exceeded its bound");
        }

        [CustomAction]
        public static ActionResult ValidateMachineTransaction(Session session)
        {
            return Guard(session, "validate-machine-transaction", () =>
            {
                if (!session.GetMode(InstallRunMode.RollbackEnabled) ||
                    !string.IsNullOrEmpty(session["RollbackDisabled"]))
                    throw new SetupBlockedException("Machine transaction requires Windows Installer rollback support",
                        "go-mapi setup requires Windows Installer rollback, which is disabled on this computer. " +
                        "Ask your administrator to allow installer rollback (DisableRollback policy), then run setup again.");

                var sku = session["GoMapiSku"];
                if (sku != "system" && sku != "suite")
                    throw new InvalidDataException("Machine SKU is not fixed by the package");
                var foreign = RelatedMachineProducts(sku == "system" ? SuiteUpgradeCode : SystemUpgradeCode);
                var own = RelatedMachineProducts(sku == "system" ? SystemUpgradeCode : SuiteUpgradeCode);
                if (foreign.Count > 1 || own.Count > 1)
                    throw new InvalidOperationException("Ambiguous machine product inventory");

                // Windows Installer may set REMOVE=ALL only after InstallValidate.
                // A nested old-product removal is part of the outer transaction.
                var finalRemoval = string.Equals(session["REMOVE"], "ALL", StringComparison.OrdinalIgnoreCase);
                if (finalRemoval) return;

                if (!string.IsNullOrEmpty(session["Installed"]))
                {
                    if (foreign.Count != 0)
                        throw new InvalidOperationException("Repair cannot coexist with another machine SKU");
                    return;
                }
                var removalList = (session["GOMAPI_FOREIGN_PRODUCT"] ?? "").Split(new[] { ';' },
                    StringSplitOptions.RemoveEmptyEntries).Select(code => code.ToUpperInvariant()).ToArray();
                if (foreign.Count == 0)
                {
                    if (removalList.Length != 0)
                        throw new InvalidOperationException("Foreign removal list has no matching machine product");
                    return;
                }
                if (session["GOMAPI_MIGRATE_SKU"] != "1" || removalList.Length != 1 ||
                    !string.Equals(removalList[0], foreign[0], StringComparison.Ordinal))
                    throw new SetupBlockedException("Explicit SKU migration and exact foreign removal list are required",
                        "Another go-mapi machine package is installed. An administrator must explicitly authorize replacing it " +
                        "(GOMAPI_MIGRATE_SKU=1) or uninstall it first, then run setup again.");
            });
        }

        // MSI's rollback of ServiceInstall recreates the service, but does not
        // replay MsiServiceConfig or WiX Util's failure-action custom action.
        // The *old* product schedules this rollback before DeleteServices for
        // upgrade-driven removal, so it runs after its own service restoration.
        [CustomAction]
        public static ActionResult RollbackServiceConfiguration(Session session)
        {
            return Guard(session, "rollback-service-configuration", () =>
            {
                RunServiceControl("config go-mapi start= delayed-auto");
                RunServiceControl("sidtype go-mapi unrestricted");
                RunServiceControl("failure go-mapi reset= 86400 actions= restart/60000/restart/60000/none/0");
            });
        }

        private static void RunServiceControl(string arguments)
        {
            using (var process = new Process())
            {
                process.StartInfo = new ProcessStartInfo("sc.exe", arguments)
                {
                    UseShellExecute = false,
                    CreateNoWindow = true,
                };
                if (!process.Start())
                    throw new InvalidOperationException("Could not start service control: " + arguments);
                if (!process.WaitForExit(30000))
                {
                    process.Kill();
                    throw new TimeoutException("Service control timed out: " + arguments);
                }
                if (process.ExitCode != 0)
                    throw new InvalidOperationException("Service control failed (" + process.ExitCode + "): " + arguments);
            }
        }

        // Resolve before RemoveExistingProducts removes the old machine marker.
        // An explicit administrator property wins; repair and cross-SKU migration
        // otherwise preserve the existing valid DWORD.
        private static void ResolveAutoUpdate(Session session)
        {
            var choice = session["GOMAPI_AUTO_UPDATE"];
            if (string.IsNullOrEmpty(choice))
            {
                using (var root = RegistryKey.OpenBaseKey(RegistryHive.LocalMachine, RegistryView.Registry64))
                using (var key = root.OpenSubKey(@"SOFTWARE\go-mapi\MachineProduct"))
                {
                    if (key != null)
                    {
                        if (!Array.Exists(key.GetValueNames(), name => name == "AutoUpdateEnabled"))
                            throw new InvalidDataException("Existing machine product has no automatic update setting");
                        if (key.GetValueKind("AutoUpdateEnabled") != RegistryValueKind.DWord)
                            throw new InvalidDataException("Machine automatic update setting has an invalid type");
                        var value = (int)key.GetValue("AutoUpdateEnabled");
                        choice = value.ToString(CultureInfo.InvariantCulture);
                    }
                }
                if (string.IsNullOrEmpty(choice))
                    choice = "1";
            }
            if (choice != "0" && choice != "1")
                throw new SetupBlockedException("Machine automatic update setting must be 0 or 1",
                    "The GOMAPI_AUTO_UPDATE setting must be 0 or 1. Correct the setup command, then run setup again.");
            session["GOMAPI_AUTO_UPDATE"] = choice;
        }

        [CustomAction]
        public static ActionResult ResolveAutoUpdateChoice(Session session)
        {
            return Guard(session, "auto-update-choice", () => ResolveAutoUpdate(session));
        }

        // Immediate actions impersonate the installer caller. Under UAC/RDSH
        // that caller can be a filtered, non-elevated token, so this action only
        // reads and marshals fixed inputs. Every protected write happens in the
        // deferred SYSTEM snapshot, which is protected by the rollback queued
        // before it.
        [CustomAction]
        public static ActionResult PrepareAdminMigration(Session session)
        {
            return Guard(session, "prepare", () =>
            {
                ResolveAutoUpdate(session);
                var paths = Paths.Create();
                var machineRoot = Path.GetDirectoryName(paths.JournalDirectory);
                var data = new CustomActionData
                {
                    ["TransactionId"] = Guid.NewGuid().ToString("D"),
                    ["JournalPath"] = paths.JournalPath,
                    ["InstallRoot"] = paths.InstallRoot,
                    ["Version"] = session["GoMapiComponentVersion"],
                    ["RequiredAppMin"] = session["GoMapiRequiredAppMin"],
                    ["RequiredAppMax"] = session["GoMapiRequiredAppMax"],
                    ["FailurePoint"] = session["GOMAPI_TEST_FAILURE_POINT"] ?? "",
                    ["ExistingProduct"] = string.IsNullOrEmpty(session["Installed"]) ? "0" : "1",
                    ["MachineRootExisted"] = Directory.Exists(machineRoot) ? "1" : "0",
                    ["JournalDirectoryExisted"] = Directory.Exists(paths.JournalDirectory) ? "1" : "0",
                }.ToString();
                session["RollbackAdminMigration"] = data;
                session["SnapshotAdminMigration"] = data;
                session["ApplyAdminMigration"] = data;
                session["VerifyAdminRegistration"] = data;
            });
        }

        // Deferred, non-impersonated preparation. Values known only here live in
        // the protected journal owned by this transaction; nothing flows back to
        // Session properties. The previous journal and its backups stay valid
        // until the replacement journal is atomically written.
        [CustomAction]
        public static ActionResult SnapshotAdminMigration(Session session)
        {
            return Guard(session, "snapshot", () =>
            {
                var data = session.CustomActionData;
                var paths = RequireFixedPaths(data);
                var transactionId = data["TransactionId"];
                MaybeFail(data, "before-prepare");

                EnsureProtectedJournalDirectory(paths.JournalDirectory);
                var transactionDirectory = TransactionDirectory(paths, transactionId);
                Directory.CreateDirectory(transactionDirectory);
                RejectReparseTree(Path.Combine(paths.JournalDirectory, "backup"));

                var installedManifest = Path.Combine(paths.InstallRoot, "installed-component-v1.json");
                var manifestBackup = Path.Combine(transactionDirectory, "rollback-installed-component-v1.json");
                var hadInstalledManifest = File.Exists(installedManifest);
                string manifestBackupSha256 = null;
                if (hadInstalledManifest)
                {
                    RequireBoundedRegularFile(installedManifest, "Installed component manifest");
                    File.Copy(installedManifest, manifestBackup, true);
                    manifestBackupSha256 = Sha256(installedManifest);
                    if (Sha256(manifestBackup) != manifestBackupSha256)
                        throw new InvalidDataException("Installed component manifest backup hash mismatch");
                }

                var rollbackProviders = new[]
                {
                    CaptureProvider(RegistryView.Registry64, transactionDirectory, "rollback"),
                    CaptureProvider(RegistryView.Registry32, transactionDirectory, "rollback"),
                };
                MaybeFail(data, "after-partial-snapshot");

                MigrationJournal previous = null;
                string previousJournalBackup = null;
                string previousJournalSha256 = null;
                if (File.Exists(paths.JournalPath))
                {
                    RequireBoundedRegularFile(paths.JournalPath, "Migration journal");
                    previousJournalBackup = Path.Combine(transactionDirectory, "previous-journal.json");
                    File.Copy(paths.JournalPath, previousJournalBackup, true);
                    previousJournalSha256 = Sha256(previousJournalBackup);
                    try
                    {
                        previous = JsonConvert.DeserializeObject<MigrationJournal>(File.ReadAllText(previousJournalBackup));
                    }
                    catch (JsonException error)
                    {
                        // A malformed journal is stale state: preserve its bytes
                        // for rollback, but never reuse its snapshots.
                        session.Log("go-mapi admin migration ignores unreadable previous journal: {0}", error.Message);
                    }
                }
                var keepOriginal = previous != null
                    && previous.Schema == JournalSchema
                    && previous.State == "committed"
                    && IsGoMapiActive(RegistryView.Registry64)
                    && IsGoMapiActive(RegistryView.Registry32);

                var journal = new MigrationJournal
                {
                    Schema = JournalSchema,
                    TransactionId = transactionId,
                    ProductVersion = data["Version"],
                    CreatedAtUtc = DateTime.UtcNow.ToString("o", CultureInfo.InvariantCulture),
                    State = "prepared",
                    PreviousProviders = keepOriginal
                        ? previous.PreviousProviders
                        : new[]
                        {
                            CaptureProvider(RegistryView.Registry64, transactionDirectory, "original"),
                            CaptureProvider(RegistryView.Registry32, transactionDirectory, "original"),
                        },
                    RollbackProviders = rollbackProviders,
                    HadInstalledManifest = hadInstalledManifest,
                    ManifestBackup = hadInstalledManifest ? manifestBackup : null,
                    ManifestBackupSha256 = manifestBackupSha256,
                    PreviousJournalBackup = previousJournalBackup,
                    PreviousJournalSha256 = previousJournalSha256,
                    Operations = new List<JournalOperation>(),
                };
                foreach (var resource in LoadInventory().Resources)
                {
                    journal.Operations.Add(new JournalOperation
                    {
                        Id = resource.Id,
                        Kind = resource.Kind,
                        Target = resource.Path ?? resource.Name,
                        Status = "planned",
                    });
                }
                SaveJournal(paths.JournalPath, journal);
                MaybeFail(data, "after-snapshot");
                PruneTransactionBackups(session, paths, journal, previous, previousJournalBackup != null);
            });
        }

        [CustomAction]
        public static ActionResult ApplyAdminMigration(Session session)
        {
            return Guard(session, "cleanup", () =>
            {
                var data = session.CustomActionData;
                var paths = RequireFixedPaths(data);
                var journal = RequireTransactionJournal(paths.JournalPath, data["TransactionId"]);
                if (journal.State != "prepared")
                    throw new InvalidDataException("Migration journal is not prepared for this transaction");
                MaybeFail(data, "before-cleanup");
                var existingProduct = data["ExistingProduct"] == "1";
                foreach (var resource in LoadInventory().Resources)
                {
                    // Maintenance must not delete MSI-owned files or registration while
                    // the installed service is running. Retire the exact legacy task.
                    if (existingProduct && resource.Kind != "scheduled-task")
                        continue;
                    CleanupResource(resource, session);
                    var operation = journal.Operations.Single(item => item.Id == resource.Id);
                    operation.Status = "removed-or-absent";
                }
                journal.State = "cleaned";
                SaveJournal(paths.JournalPath, journal);
                MaybeFail(data, "after-cleanup");
            });
        }

        [CustomAction]
        public static ActionResult VerifyAdminRegistration(Session session)
        {
            return Guard(session, "verify-and-commit", () =>
            {
                var data = session.CustomActionData;
                var paths = RequireFixedPaths(data);
                var installRoot = paths.InstallRoot;
                var version = data["Version"];
                var requiredAppMin = data["RequiredAppMin"];
                var requiredAppMax = data["RequiredAppMax"];
                if (string.IsNullOrWhiteSpace(requiredAppMin))
                    throw new InvalidDataException("Required app minimum version is absent");
                if (string.IsNullOrWhiteSpace(requiredAppMax))
                    throw new InvalidDataException("Required app maximum version is absent");
                RequireTransactionJournal(paths.JournalPath, data["TransactionId"]);
                var x86 = Path.Combine(installRoot, "x86", "go-mapi.dll");
                var x64 = Path.Combine(installRoot, "AMD64", "go-mapi.dll");

                SetSharedRegistration();
                AssertSharedRegistration(x86, x64);
                MaybeFail(data, "after-registration");

                var manifest = new InstalledComponentManifest
                {
                    Schema = InstalledSchema,
                    Component = "interceptor",
                    Version = version,
                    QueueProtocol = QueueProtocol,
                    Requires = new ComponentRequirement
                    {
                        Component = "app",
                        MinInclusive = requiredAppMin,
                        MaxExclusive = requiredAppMax,
                    },
                    Artifacts = new[]
                    {
                        BuildArtifact("x86", @"x86\go-mapi.dll", x86, version),
                        BuildArtifact("x64", @"AMD64\go-mapi.dll", x64, version),
                    },
                };

                var manifestPath = Path.Combine(installRoot, "installed-component-v1.json");
                AtomicWriteJson(manifestPath, manifest);
                var journal = RequireTransactionJournal(paths.JournalPath, data["TransactionId"]);
                journal.State = "committed";
                journal.InstalledManifest = manifestPath;
                SaveJournal(paths.JournalPath, journal);
            });
        }

        private static void MaybeFail(CustomActionData data, string point)
        {
            if (data.ContainsKey("FailurePoint")
                && string.Equals(data["FailurePoint"], point, StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException("Requested validation failure point: " + point);
        }

        // Rollback owns only this transaction. With no journal, a partial
        // snapshot or another transaction's journal, nothing was changed
        // destructively; only this transaction's backup residue is removed and
        // the previous healthy journal is left untouched.
        [CustomAction]
        public static ActionResult RollbackAdminMigration(Session session)
        {
            return Guard(session, "rollback", () =>
            {
                var data = session.CustomActionData;
                var paths = RequireFixedPaths(data);
                var transactionId = data["TransactionId"];
                var transactionDirectory = TransactionDirectory(paths, transactionId);
                MigrationJournal journal = null;
                if (File.Exists(paths.JournalPath))
                {
                    try
                    {
                        journal = LoadJournal(paths.JournalPath);
                    }
                    catch (Exception error) when (error is JsonException || error is InvalidDataException)
                    {
                        session.Log("go-mapi admin migration rollback leaves unreadable journal untouched: {0}", error.Message);
                    }
                }
                if (journal == null || !string.Equals(journal.TransactionId, transactionId, StringComparison.OrdinalIgnoreCase))
                {
                    RemoveTransactionResidue(paths, transactionDirectory, data);
                    return;
                }

                RemoveOwnedClient(RegistryView.Registry64);
                RemoveOwnedClient(RegistryView.Registry32);
                RestoreProvider(journal.RollbackProviders, RegistryView.Registry64, true);
                RestoreProvider(journal.RollbackProviders, RegistryView.Registry32, true);
                var installedManifest = Path.Combine(paths.InstallRoot, "installed-component-v1.json");
                if (journal.HadInstalledManifest)
                {
                    var backup = RequireTransactionFile(transactionDirectory, journal.ManifestBackup, journal.ManifestBackupSha256,
                        "Rollback component manifest backup");
                    Directory.CreateDirectory(paths.InstallRoot);
                    File.Copy(backup, installedManifest, true);
                }
                else
                    DeleteFileIfExists(installedManifest);

                if (!string.IsNullOrEmpty(journal.PreviousJournalBackup))
                {
                    var backup = RequireTransactionFile(transactionDirectory, journal.PreviousJournalBackup, journal.PreviousJournalSha256,
                        "Previous migration journal backup");
                    AtomicWriteBytes(paths.JournalPath, File.ReadAllBytes(backup));
                    ProtectJournalFile(paths.JournalPath);
                }
                else
                    DeleteFileIfExists(paths.JournalPath);
                RemoveTransactionResidue(paths, transactionDirectory, data);
            });
        }

        private static Paths RequireFixedPaths(CustomActionData data)
        {
            var paths = Paths.Create();
            if (!string.Equals(data["JournalPath"], paths.JournalPath, StringComparison.OrdinalIgnoreCase) ||
                !string.Equals(data["InstallRoot"], paths.InstallRoot, StringComparison.OrdinalIgnoreCase))
                throw new InvalidDataException("Deferred machine paths do not match the fixed machine layout");
            Guid transaction;
            if (!data.ContainsKey("TransactionId") || !Guid.TryParseExact(data["TransactionId"], "D", out transaction))
                throw new InvalidDataException("Deferred machine transaction identity is invalid");
            return paths;
        }

        private static string TransactionDirectory(Paths paths, string transactionId)
        {
            return Path.Combine(paths.JournalDirectory, "backup", Guid.ParseExact(transactionId, "D").ToString("D"));
        }

        private static MigrationJournal RequireTransactionJournal(string path, string transactionId)
        {
            var journal = RequireJournal(path);
            if (!string.Equals(journal.TransactionId, transactionId, StringComparison.OrdinalIgnoreCase))
                throw new InvalidDataException("Migration journal belongs to another transaction");
            return journal;
        }

        private static string RequireTransactionFile(string transactionDirectory, string path, string sha256, string label)
        {
            if (string.IsNullOrEmpty(path) || string.IsNullOrEmpty(sha256) ||
                !string.Equals(Path.GetDirectoryName(Path.GetFullPath(path)), Path.GetFullPath(transactionDirectory), StringComparison.OrdinalIgnoreCase))
                throw new InvalidDataException(label + " is not owned by this transaction");
            if (!File.Exists(path))
                throw new InvalidDataException(label + " is absent");
            RequireBoundedRegularFile(path, label);
            if (Sha256(path) != sha256)
                throw new InvalidDataException(label + " hash mismatch");
            return path;
        }

        private static void RequireBoundedRegularFile(string path, string label)
        {
            var info = new FileInfo(path);
            if ((info.Attributes & System.IO.FileAttributes.ReparsePoint) != 0 || info.Length <= 0 || info.Length > 1024 * 1024)
                throw new InvalidDataException(label + " is not a bounded regular file");
        }

        private static void RemoveTransactionResidue(Paths paths, string transactionDirectory, CustomActionData data)
        {
            DeleteTransactionDirectory(paths, transactionDirectory);
            var backupRoot = Path.Combine(paths.JournalDirectory, "backup");
            if (data["JournalDirectoryExisted"] != "1")
            {
                DeleteDirectoryIfEmpty(backupRoot);
                DeleteDirectoryIfEmpty(paths.JournalDirectory);
                if (data["MachineRootExisted"] != "1")
                    DeleteDirectoryIfEmpty(Path.GetDirectoryName(paths.JournalDirectory));
            }
        }

        private static void DeleteTransactionDirectory(Paths paths, string directory)
        {
            if (!Directory.Exists(directory))
                return;
            var full = Path.GetFullPath(directory).TrimEnd(Path.DirectorySeparatorChar);
            var backupRoot = Path.GetFullPath(Path.Combine(paths.JournalDirectory, "backup")).TrimEnd(Path.DirectorySeparatorChar);
            Guid ignored;
            if (!string.Equals(Path.GetDirectoryName(full), backupRoot, StringComparison.OrdinalIgnoreCase) ||
                !Guid.TryParseExact(Path.GetFileName(full), "D", out ignored))
                throw new InvalidDataException("Refusing non-transaction directory: " + full);
            RejectReparseTree(full);
            Directory.Delete(full, true);
        }

        private static void DeleteDirectoryIfEmpty(string path)
        {
            if (!Directory.Exists(path))
                return;
            if ((File.GetAttributes(path) & System.IO.FileAttributes.ReparsePoint) != 0)
                return;
            if (!Directory.EnumerateFileSystemEntries(path).Any())
                Directory.Delete(path, false);
        }

        // Removes backups of earlier, finished transactions. The previous
        // journal's own transaction and every backup the new or previous journal
        // references are kept, so any later rollback consumer stays valid.
        // Legacy root-level backup files are left for final uninstall cleanup.
        private static void PruneTransactionBackups(Session session, Paths paths, MigrationJournal current,
            MigrationJournal previous, bool previousJournalExisted)
        {
            if (previousJournalExisted && previous == null)
                return;
            try
            {
                var keep = new HashSet<string>(StringComparer.OrdinalIgnoreCase) { current.TransactionId };
                foreach (var journal in new[] { current, previous })
                {
                    if (journal == null)
                        continue;
                    if (!string.IsNullOrEmpty(journal.TransactionId))
                        keep.Add(journal.TransactionId);
                    foreach (var snapshot in (journal.PreviousProviders ?? new ProviderSnapshot[0]).Concat(journal.RollbackProviders ?? new ProviderSnapshot[0]))
                    {
                        if (string.IsNullOrEmpty(snapshot?.OwnedDllBackup))
                            continue;
                        var parent = Path.GetFileName(Path.GetDirectoryName(Path.GetFullPath(snapshot.OwnedDllBackup)));
                        if (!string.IsNullOrEmpty(parent))
                            keep.Add(parent);
                    }
                }
                foreach (var directory in Directory.EnumerateDirectories(Path.Combine(paths.JournalDirectory, "backup")))
                {
                    Guid ignored;
                    var name = Path.GetFileName(directory);
                    if (Guid.TryParseExact(name, "D", out ignored) && !keep.Contains(name))
                        DeleteTransactionDirectory(paths, directory);
                }
            }
            catch (Exception error)
            {
                session.Log("go-mapi admin migration left earlier transaction backups in place: {0}", error.Message);
            }
        }

        [CustomAction]
        public static ActionResult PrepareAdminUninstall(Session session)
        {
            return Guard(session, "prepare-uninstall", () =>
            {
                var paths = Paths.Create();
                var data = new CustomActionData
                {
                    ["JournalPath"] = paths.JournalPath,
                    ["InstallRoot"] = paths.InstallRoot,
                    ["WasActive64"] = IsGoMapiActive(RegistryView.Registry64) ? "1" : "0",
                    ["WasActive32"] = IsGoMapiActive(RegistryView.Registry32) ? "1" : "0",
                    ["FailurePoint"] = session["GOMAPI_TEST_FAILURE_POINT"] ?? "",
                }.ToString();
                session["RollbackAdminUninstall"] = data;
                session["FinalizeAdminUninstall"] = data;
                session["CommitAdminUninstall"] = data;
            });
        }

        [CustomAction]
        public static ActionResult BeginResidentUninstallFence(Session session)
        {
            return Guard(session, "begin-resident-uninstall-fence", () => RunResidentFence("--begin-final-uninstall"));
        }

        [CustomAction]
        public static ActionResult RollbackResidentUninstallFence(Session session)
        {
            return Guard(session, "rollback-resident-uninstall-fence", () => RunResidentFence("--rollback-final-uninstall"));
        }

        private static void RunResidentFence(string argument)
        {
            var executable = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "go-mapi", "service", "go-mapi-service.exe");
            if (!File.Exists(executable))
                throw new FileNotFoundException("Installed resident service is required for the final uninstall fence", executable);
            using (var process = new Process())
            {
                process.StartInfo = new ProcessStartInfo(executable, argument) { UseShellExecute = false, CreateNoWindow = true };
                if (!process.Start())
                    throw new InvalidOperationException("Could not start resident uninstall fence");
                if (!process.WaitForExit(30000))
                {
                    process.Kill();
                    throw new TimeoutException("Resident uninstall fence timed out");
                }
                if (process.ExitCode != 0)
                    throw new InvalidOperationException("Resident uninstall fence refused the operation");
            }
        }

        [CustomAction]
        public static ActionResult FinalizeAdminUninstall(Session session)
        {
            return Guard(session, "finalize-uninstall", () =>
            {
                var data = session.CustomActionData;
                var journal = LoadJournal(data["JournalPath"]);
                if (journal != null)
                {
                    if (data["WasActive64"] == "1")
                        RestoreProvider(journal.PreviousProviders, RegistryView.Registry64, false);
                    if (data["WasActive32"] == "1")
                        RestoreProvider(journal.PreviousProviders, RegistryView.Registry32, false);
                    journal.State = "uninstalled";
                    SaveJournal(data["JournalPath"], journal);
                }
                MaybeFail(data, "after-uninstall-finalize");
            });
        }

        // Keep the installed manifest intact until MSI has completed its
        // script. A deferred deletion cannot be restored if a later action
        // rolls the uninstall back.
        [CustomAction]
        public static ActionResult CommitAdminUninstall(Session session)
        {
            try
            {
                var manifest = Path.Combine(session.CustomActionData["InstallRoot"], "installed-component-v1.json");
                DeleteFileIfExists(manifest);
                var machineRoot = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "go-mapi");
                SafeDeleteDirectory(Path.Combine(machineRoot, "updates"));
                SafeDeleteDirectory(Path.Combine(machineRoot, "status"));
                SafeDeleteDirectory(Path.Combine(machineRoot, "service"));
                // The migration journal and its backups have no consumer after
                // the final uninstall commits.
                SafeDeleteDirectory(Path.Combine(machineRoot, "installer-journal"));
                DeleteDirectoryIfEmpty(machineRoot);
                using (var root = RegistryKey.OpenBaseKey(RegistryHive.LocalMachine, RegistryView.Registry64))
                {
                    root.DeleteSubKeyTree(VolatileBootKey, false);
                    root.DeleteSubKeyTree(UninstallCleanupKey, false);
                }
                return ActionResult.Success;
            }
            catch (Exception error)
            {
                // Commit actions cannot safely undo a partially completed
                // cleanup. Leave the exact file for administrator retry.
                session.Log("go-mapi admin migration commit-uninstall cleanup incomplete: {0}", error);
                try
                {
                    using (var root = RegistryKey.OpenBaseKey(RegistryHive.LocalMachine, RegistryView.Registry64))
                    using (var marker = root.CreateSubKey(UninstallCleanupKey, true))
                        marker.SetValue("Result", "manifest-cleanup-incomplete", RegistryValueKind.String);
                }
                catch (Exception markerError)
                {
                    session.Log("go-mapi admin migration could not persist cleanup marker: {0}", markerError);
                }
                return ActionResult.Success;
            }
        }

        [CustomAction]
        public static ActionResult RollbackAdminUninstall(Session session)
        {
            return Guard(session, "rollback-uninstall", () =>
            {
                var data = session.CustomActionData;
                if (data["WasActive64"] == "1")
                    SetActiveProvider(RegistryView.Registry64, ProductName);
                if (data["WasActive32"] == "1")
                    SetActiveProvider(RegistryView.Registry32, ProductName);
                var journal = LoadJournal(data["JournalPath"]);
                if (journal != null && journal.State == "uninstalled")
                {
                    journal.State = "committed";
                    SaveJournal(data["JournalPath"], journal);
                }
            });
        }

        private static ActionResult Guard(Session session, string phase, Action action)
        {
            try
            {
                session.Log("go-mapi admin migration phase: {0}", phase);
                action();
                return ActionResult.Success;
            }
            catch (Exception error)
            {
                session.Log("go-mapi admin migration phase {0} failed: {1}", phase, error);
                ReportFailure(session, phase, error);
                return ActionResult.Failure;
            }
        }

        // Emits a sanitized, actionable reason through Windows Installer so the
        // installer UI level decides whether it is shown (/qn stays silent).
        // Exception details remain only in the verbose log. Rollback phases
        // log only: the user-facing failure was already reported.
        private static void ReportFailure(Session session, string phase, Exception error)
        {
            if (phase.StartsWith("rollback", StringComparison.Ordinal))
                return;
            var blocked = error as SetupBlockedException;
            var text = blocked != null
                ? blocked.UserMessage
                : "go-mapi setup could not complete the step \"" + PhaseDescription(phase) + "\". " +
                  "Windows Installer will undo the changes made by this setup. Run setup again; if the problem continues, " +
                  "create a verbose log (msiexec /i <package> /l*vx <log file>) and send it to your administrator or go-mapi support.";
            try
            {
                using (var record = new Record(1))
                {
                    record.FormatString = "[1]";
                    record.SetString(1, text);
                    session.Message(InstallMessage.Error | (InstallMessage)MessageButtons.OK | (InstallMessage)MessageIcon.Error, record);
                }
            }
            catch (Exception messageError)
            {
                session.Log("go-mapi admin migration could not report failure to the installer UI: {0}", messageError.Message);
            }
        }

        private static string PhaseDescription(string phase)
        {
            switch (phase)
            {
                case "validate-machine-transaction": return "check installed go-mapi machine products";
                case "auto-update-choice": return "resolve the automatic update setting";
                case "prepare": return "prepare the machine installation";
                case "snapshot": return "save the current mail provider state";
                case "cleanup": return "remove earlier go-mapi installations";
                case "verify-and-commit": return "register go-mapi as the mail provider";
                case "prepare-uninstall": return "prepare the uninstall";
                case "begin-resident-uninstall-fence": return "stop the go-mapi service for uninstall";
                case "finalize-uninstall": return "restore the previous mail provider";
                default: return "configure go-mapi";
            }
        }

        private sealed class SetupBlockedException : InvalidOperationException
        {
            public SetupBlockedException(string message, string userMessage) : base(message)
            {
                UserMessage = userMessage;
            }

            public string UserMessage { get; private set; }
        }

        private static void CleanupResource(InventoryResource resource, Session session)
        {
            switch (resource.Kind)
            {
                case "registry-key":
                    foreach (var view in ParseViews(resource.Views))
                        DeleteRegistryKey(view, resource.Path);
                    break;
                case "registry-value":
                    foreach (var view in ParseViews(resource.Views))
                        DeleteRegistryValue(view, resource.Path, resource.Name);
                    break;
                case "directory":
                    SafeDeleteDirectory(ExpandOwnedPath(resource.Path));
                    break;
                case "file":
                    DeleteFileIfExists(ExpandOwnedPath(resource.Path));
                    break;
                case "scheduled-task":
                    DeleteScheduledTask(resource.Name);
                    break;
                case "firewall-rule":
                    DeleteFirewallRule(resource.Name);
                    break;
                default:
                    throw new InvalidDataException("Unknown legacy inventory kind: " + resource.Kind);
            }
        }

        private static void DeleteScheduledTask(string name)
        {
            var type = Type.GetTypeFromProgID("Schedule.Service", true);
            dynamic service = Activator.CreateInstance(type);
            service.Connect();
            dynamic folder = service.GetFolder("\\");
            var exists = false;
            foreach (dynamic task in folder.GetTasks(0))
            {
                if (string.Equals((string)task.Name, name, StringComparison.OrdinalIgnoreCase))
                {
                    exists = true;
                    break;
                }
            }
            if (exists)
                folder.DeleteTask(name, 0);
            foreach (dynamic task in folder.GetTasks(0))
            {
                if (string.Equals((string)task.Name, name, StringComparison.OrdinalIgnoreCase))
                    throw new InvalidOperationException("Scheduled task cleanup did not remove exact owned task: " + name);
            }
        }

        private static void DeleteFirewallRule(string name)
        {
            var type = Type.GetTypeFromProgID("HNetCfg.FwPolicy2", true);
            dynamic policy = Activator.CreateInstance(type);
            var exists = false;
            foreach (dynamic rule in policy.Rules)
            {
                if (string.Equals((string)rule.Name, name, StringComparison.OrdinalIgnoreCase))
                {
                    exists = true;
                    break;
                }
            }
            if (exists)
                policy.Rules.Remove(name);
            foreach (dynamic rule in policy.Rules)
            {
                if (string.Equals((string)rule.Name, name, StringComparison.OrdinalIgnoreCase))
                    throw new InvalidOperationException("Firewall cleanup did not remove exact owned rule: " + name);
            }
        }

        private static Inventory LoadInventory()
        {
            const string suffix = ".legacy-inventory.json";
            var assembly = Assembly.GetExecutingAssembly();
            var name = assembly.GetManifestResourceNames().Single(item => item.EndsWith(suffix, StringComparison.Ordinal));
            using (var stream = assembly.GetManifestResourceStream(name))
            using (var reader = new StreamReader(stream ?? throw new InvalidDataException("Missing embedded legacy inventory")))
            {
                var inventory = JsonConvert.DeserializeObject<Inventory>(reader.ReadToEnd());
                if (inventory == null || inventory.Schema != "go-mapi-legacy-inventory-v1" || inventory.Resources == null)
                    throw new InvalidDataException("Invalid embedded legacy inventory");
                return inventory;
            }
        }

        private static RegistryView[] ParseViews(string[] views)
        {
            if (views == null || views.Length == 0)
                throw new InvalidDataException("Registry inventory item has no view");
            return views.Select(value => (RegistryView)Enum.Parse(typeof(RegistryView), value, false)).ToArray();
        }

        private static ProviderSnapshot CaptureProvider(RegistryView view, string backupDirectory, string backupPrefix)
        {
            using (var baseKey = RegistryKey.OpenBaseKey(RegistryHive.LocalMachine, view))
            using (var key = baseKey.OpenSubKey(MailRoot, false))
            {
                var value = key?.GetValue(null, null, RegistryValueOptions.DoNotExpandEnvironmentNames) as string;
                var snapshot = new ProviderSnapshot
                {
                    View = view.ToString(),
                    Existed = value != null,
                    Value = value,
                };
                if (string.Equals(value, ProductName, StringComparison.OrdinalIgnoreCase))
                {
                    using (var client = baseKey.OpenSubKey(ClientKey, false))
                    {
                        snapshot.OwnedClientExisted = client != null;
                        snapshot.OwnedClientDefault = client?.GetValue(null, null, RegistryValueOptions.DoNotExpandEnvironmentNames) as string;
                        snapshot.OwnedDllPath = client?.GetValue("DLLPath", null, RegistryValueOptions.DoNotExpandEnvironmentNames) as string;
                    }
                    if (!string.IsNullOrWhiteSpace(snapshot.OwnedDllPath)
                        && File.Exists(snapshot.OwnedDllPath)
                        && IsOwnedLegacyDllPath(snapshot.OwnedDllPath))
                    {
                        Directory.CreateDirectory(backupDirectory);
                        snapshot.OwnedDllBackup = Path.Combine(backupDirectory, backupPrefix + "-" + view + "-go-mapi.dll");
                        File.Copy(snapshot.OwnedDllPath, snapshot.OwnedDllBackup, true);
                        snapshot.OwnedDllBackupSha256 = Sha256(snapshot.OwnedDllBackup);
                    }
                }
                return snapshot;
            }
        }

        private static void RestoreProvider(IEnumerable<ProviderSnapshot> providers, RegistryView view, bool restoreOwnedGoMapi)
        {
            var snapshot = providers?.SingleOrDefault(item => item.View == view.ToString());
            if (snapshot == null)
                return;
            if (restoreOwnedGoMapi
                && string.Equals(snapshot.Value, ProductName, StringComparison.OrdinalIgnoreCase)
                && snapshot.OwnedClientExisted
                && !string.IsNullOrWhiteSpace(snapshot.OwnedDllPath)
                && !string.IsNullOrWhiteSpace(snapshot.OwnedDllBackup)
                && File.Exists(snapshot.OwnedDllBackup)
                && (File.GetAttributes(snapshot.OwnedDllBackup) & System.IO.FileAttributes.ReparsePoint) == 0
                && (snapshot.OwnedDllBackupSha256 == null || Sha256(snapshot.OwnedDllBackup) == snapshot.OwnedDllBackupSha256)
                && IsOwnedLegacyDllPath(snapshot.OwnedDllPath))
            {
                Directory.CreateDirectory(Path.GetDirectoryName(snapshot.OwnedDllPath));
                File.Copy(snapshot.OwnedDllBackup, snapshot.OwnedDllPath, true);
                using (var baseKey = RegistryKey.OpenBaseKey(RegistryHive.LocalMachine, view))
                using (var client = baseKey.CreateSubKey(ClientKey, true))
                {
                    client.SetValue(null, snapshot.OwnedClientDefault ?? ProductName, RegistryValueKind.String);
                    client.SetValue("DLLPath", snapshot.OwnedDllPath, RegistryValueKind.String);
                }
            }
            using (var baseKey = RegistryKey.OpenBaseKey(RegistryHive.LocalMachine, view))
            using (var key = baseKey.CreateSubKey(MailRoot, true))
            {
                if (snapshot.Existed && IsSafeProvider(snapshot.Value, view))
                    key.SetValue(null, snapshot.Value, RegistryValueKind.String);
                else
                    key.DeleteValue(null, false);
            }
        }

        private static bool IsSafeProvider(string value, RegistryView view)
        {
            if (string.IsNullOrWhiteSpace(value))
                return true;
            using (var baseKey = RegistryKey.OpenBaseKey(RegistryHive.LocalMachine, view))
            using (var key = baseKey.OpenSubKey(MailRoot + "\\" + value, false))
                return key != null;
        }

        private static bool IsOwnedLegacyDllPath(string path)
        {
            var full = Path.GetFullPath(path);
            if (!string.Equals(Path.GetFileName(full), "go-mapi.dll", StringComparison.OrdinalIgnoreCase))
                return false;
            var roots = new[]
            {
                Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "go-mapi"),
                Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86), "go-mapi"),
            };
            return roots.Any(root => full.StartsWith(Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase));
        }

        private static bool IsGoMapiActive(RegistryView view)
        {
            using (var baseKey = RegistryKey.OpenBaseKey(RegistryHive.LocalMachine, view))
            using (var key = baseKey.OpenSubKey(MailRoot, false))
                return string.Equals(key?.GetValue(null) as string, ProductName, StringComparison.OrdinalIgnoreCase);
        }

        private static void SetActiveProvider(RegistryView view, string value)
        {
            using (var baseKey = RegistryKey.OpenBaseKey(RegistryHive.LocalMachine, view))
            using (var key = baseKey.CreateSubKey(MailRoot, true))
                key.SetValue(null, value, RegistryValueKind.String);
        }

        private static void SetSharedRegistration()
        {
            using (var baseKey = RegistryKey.OpenBaseKey(RegistryHive.LocalMachine, RegistryView.Registry64))
            using (var root = baseKey.CreateSubKey(MailRoot, true))
            using (var client = baseKey.CreateSubKey(ClientKey, true))
            {
                root.SetValue(null, ProductName, RegistryValueKind.String);
                client.SetValue(null, ProductName, RegistryValueKind.String);
                client.SetValue("DLLPath", ActiveDllPath, RegistryValueKind.ExpandString);
            }
        }

        private static void AssertSharedRegistration(string x86Dll, string x64Dll)
        {
            foreach (var expectedDll in new[] { x86Dll, x64Dll })
            {
                if (!File.Exists(expectedDll))
                    throw new FileNotFoundException("Missing installed interceptor DLL", expectedDll);
            }
            foreach (var view in new[] { RegistryView.Registry32, RegistryView.Registry64 })
            {
                using (var baseKey = RegistryKey.OpenBaseKey(RegistryHive.LocalMachine, view))
                using (var root = baseKey.OpenSubKey(MailRoot, false))
                using (var client = baseKey.OpenSubKey(ClientKey, false))
                {
                    var active = root?.GetValue(null, null, RegistryValueOptions.DoNotExpandEnvironmentNames) as string;
                    var dllPath = client?.GetValue("DLLPath", null, RegistryValueOptions.DoNotExpandEnvironmentNames) as string;
                    if (!string.Equals(active, ProductName, StringComparison.OrdinalIgnoreCase))
                        throw new InvalidDataException(view + " active provider is not go-mapi");
                    if (!string.Equals(dllPath, ActiveDllPath, StringComparison.OrdinalIgnoreCase))
                        throw new InvalidDataException(view + " shared DLLPath is not caller-architecture aware; actual='" + dllPath + "'");
                }
            }
        }

        private static InstalledArtifact BuildArtifact(string architecture, string relativePath, string fullPath, string version)
        {
            var actualVersion = FileVersionInfo.GetVersionInfo(fullPath).ProductVersion;
            if (!string.Equals(actualVersion, version, StringComparison.OrdinalIgnoreCase))
                throw new InvalidDataException(architecture + " PE ProductVersion does not match component version");
            return new InstalledArtifact
            {
                Architecture = architecture,
                Path = relativePath,
                PeProductVersion = actualVersion,
                Sha256 = Sha256(fullPath),
            };
        }

        private static string Sha256(string path)
        {
            using (var stream = File.OpenRead(path))
            using (var hash = SHA256.Create())
                return string.Concat(hash.ComputeHash(stream).Select(item => item.ToString("x2", CultureInfo.InvariantCulture)));
        }

        private static void RemoveOwnedClient(RegistryView view)
        {
            DeleteRegistryKey(view, ClientKey);
            if (IsGoMapiActive(view))
            {
                using (var baseKey = RegistryKey.OpenBaseKey(RegistryHive.LocalMachine, view))
                using (var root = baseKey.OpenSubKey(MailRoot, true))
                    root?.DeleteValue(null, false);
            }
        }

        private static void DeleteRegistryKey(RegistryView view, string path)
        {
            ValidateRegistryOwnership(path);
            using (var baseKey = RegistryKey.OpenBaseKey(RegistryHive.LocalMachine, view))
                baseKey.DeleteSubKeyTree(path, false);
        }

        private static void DeleteRegistryValue(RegistryView view, string path, string name)
        {
            if (!string.Equals(name, ProductName, StringComparison.OrdinalIgnoreCase))
                throw new InvalidDataException("Refusing non-owned registry value: " + name);
            using (var baseKey = RegistryKey.OpenBaseKey(RegistryHive.LocalMachine, view))
            using (var key = baseKey.OpenSubKey(path, true))
                key?.DeleteValue(name, false);
        }

        private static void ValidateRegistryOwnership(string path)
        {
            var final = path.Split('\\').Last();
            if (!string.Equals(final, ProductName, StringComparison.OrdinalIgnoreCase)
                && !string.Equals(final, "go-mapi.exe", StringComparison.OrdinalIgnoreCase))
                throw new InvalidDataException("Refusing non-owned registry subtree: " + path);
        }

        private static string ExpandOwnedPath(string path)
        {
            var commonStart = Environment.GetFolderPath(Environment.SpecialFolder.CommonStartMenu);
            return path
                .Replace("%ProgramFiles(x86)%", Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86))
                .Replace("%ProgramFiles%", Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles))
                .Replace("%ProgramData%", Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData))
                .Replace("%CommonStartMenu%", commonStart);
        }

        private static void SafeDeleteDirectory(string path)
        {
            if (!Directory.Exists(path))
                return;
            var full = Path.GetFullPath(path).TrimEnd(Path.DirectorySeparatorChar);
            var allowed = new[]
            {
                Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "go-mapi"),
                Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86), "go-mapi"),
                Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "go-mapi", "updates"),
                Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "go-mapi", "service"),
                Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "go-mapi", "status"),
                Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "go-mapi", "uninst"),
                Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "go-mapi", "installer-journal"),
            }.Select(item => Path.GetFullPath(item).TrimEnd(Path.DirectorySeparatorChar));
            if (!allowed.Contains(full, StringComparer.OrdinalIgnoreCase))
                throw new InvalidDataException("Refusing non-owned directory: " + full);
            RejectReparseTree(full);
            Directory.Delete(full, true);
        }

        private static void RejectReparseTree(string path)
        {
            if ((File.GetAttributes(path) & System.IO.FileAttributes.ReparsePoint) != 0)
                throw new InvalidDataException("Refusing reparse point under owned directory: " + path);
            foreach (var entry in Directory.EnumerateFileSystemEntries(path))
            {
                var attributes = File.GetAttributes(entry);
                if ((attributes & System.IO.FileAttributes.ReparsePoint) != 0)
                    throw new InvalidDataException("Refusing reparse point under owned directory: " + entry);
                if ((attributes & System.IO.FileAttributes.Directory) != 0)
                    RejectReparseTree(entry);
            }
        }

        private static void DeleteFileIfExists(string path)
        {
            if (File.Exists(path))
                File.Delete(path);
        }

        private static MigrationJournal RequireJournal(string path)
        {
            return LoadJournal(path) ?? throw new InvalidDataException("Migration journal is absent");
        }

        private static MigrationJournal LoadJournal(string path)
        {
            if (!File.Exists(path))
                return null;
            RequireBoundedRegularFile(path, "Migration journal");
            return JsonConvert.DeserializeObject<MigrationJournal>(File.ReadAllText(path));
        }

        private static void SaveJournal(string path, MigrationJournal journal)
        {
            AtomicWriteJson(path, journal);
            ProtectJournalFile(path);
        }

        private static void EnsureProtectedJournalDirectory(string path)
        {
            Directory.CreateDirectory(path);
            var info = new DirectoryInfo(path);
            var parent = info.Parent;
            if ((info.Attributes & System.IO.FileAttributes.ReparsePoint) != 0 ||
                (parent != null && (parent.Attributes & System.IO.FileAttributes.ReparsePoint) != 0))
                throw new InvalidDataException("Installer journal directory is a reparse point");
            var security = new DirectorySecurity();
            security.SetAccessRuleProtection(true, false);
            security.SetOwner(new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null));
            foreach (var sid in new[] { WellKnownSidType.LocalSystemSid, WellKnownSidType.BuiltinAdministratorsSid })
                security.AddAccessRule(new FileSystemAccessRule(new SecurityIdentifier(sid, null),
                    FileSystemRights.FullControl, InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit,
                    PropagationFlags.None, AccessControlType.Allow));
            WithRestorePrivilege(() => Directory.SetAccessControl(path, security));
        }

        private static void ProtectJournalFile(string path)
        {
            var security = new FileSecurity();
            security.SetAccessRuleProtection(true, false);
            security.SetOwner(new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null));
            foreach (var sid in new[] { WellKnownSidType.LocalSystemSid, WellKnownSidType.BuiltinAdministratorsSid })
                security.AddAccessRule(new FileSystemAccessRule(new SecurityIdentifier(sid, null),
                    FileSystemRights.FullControl, AccessControlType.Allow));
            WithRestorePrivilege(() => File.SetAccessControl(path, security));
        }

        // Immediate MSI actions impersonate the installer caller. An elevated
        // administrator has SeRestorePrivilege, but it is normally disabled;
        // assigning SYSTEM as owner requires it even when the DACL grants access.
        private static void WithRestorePrivilege(Action action)
        {
            if (WindowsIdentity.GetCurrent().User.IsWellKnown(WellKnownSidType.LocalSystemSid))
            {
                action();
                return;
            }

            IntPtr token;
            if (!OpenThreadToken(GetCurrentThread(), TokenQuery | TokenAdjustPrivileges, true, out token))
            {
                var error = Marshal.GetLastWin32Error();
                if (error != ErrorNoToken)
                    throw new InvalidOperationException("Could not open installer thread token: " + error);
                if (!OpenProcessToken(GetCurrentProcess(), TokenQuery | TokenAdjustPrivileges, out token))
                    throw new InvalidOperationException("Could not open installer process token: " + Marshal.GetLastWin32Error());
            }
            try
            {
                Luid luid;
                if (!LookupPrivilegeValue(null, "SeRestorePrivilege", out luid))
                    throw new InvalidOperationException("Could not resolve SeRestorePrivilege: " + Marshal.GetLastWin32Error());
                var enabled = new TokenPrivileges { PrivilegeCount = 1, Luid = luid, Attributes = SePrivilegeEnabled };
                TokenPrivileges previous;
                uint returned;
                if (!AdjustTokenPrivileges(token, false, ref enabled, (uint)Marshal.SizeOf(typeof(TokenPrivileges)), out previous, out returned))
                    throw new InvalidOperationException("Could not enable SeRestorePrivilege: " + Marshal.GetLastWin32Error());
                if (Marshal.GetLastWin32Error() == ErrorNotAllAssigned)
                    throw new InvalidOperationException("SeRestorePrivilege is not assigned to the installer token");
                try
                {
                    action();
                }
                finally
                {
                    if (previous.PrivilegeCount != 0 &&
                        !RestoreTokenPrivileges(token, false, ref previous, 0, IntPtr.Zero, IntPtr.Zero))
                        throw new InvalidOperationException("Could not restore SeRestorePrivilege: " + Marshal.GetLastWin32Error());
                }
            }
            finally
            {
                CloseHandle(token);
            }
        }

        private static void AtomicWriteJson(string path, object value)
        {
            Directory.CreateDirectory(Path.GetDirectoryName(path) ?? throw new InvalidDataException("Path has no directory"));
            var temporary = path + ".tmp." + Guid.NewGuid().ToString("N");
            File.WriteAllText(temporary, JsonConvert.SerializeObject(value, Formatting.Indented));
            if (File.Exists(path))
                File.Replace(temporary, path, null);
            else
                File.Move(temporary, path);
        }

        private static void AtomicWriteBytes(string path, byte[] value)
        {
            Directory.CreateDirectory(Path.GetDirectoryName(path) ?? throw new InvalidDataException("Path has no directory"));
            var temporary = path + ".tmp." + Guid.NewGuid().ToString("N");
            File.WriteAllBytes(temporary, value);
            if (File.Exists(path))
                File.Replace(temporary, path, null);
            else
                File.Move(temporary, path);
        }

        private sealed class Paths
        {
            public string InstallRoot { get; private set; }
            public string JournalDirectory { get; private set; }
            public string JournalPath { get; private set; }

            public static Paths Create()
            {
                var programFiles = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
                var programData = Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData);
                var journalDirectory = Path.Combine(programData, "go-mapi", "installer-journal");
                return new Paths
                {
                    InstallRoot = Path.Combine(programFiles, "go-mapi", "interceptor"),
                    JournalDirectory = journalDirectory,
                    JournalPath = Path.Combine(journalDirectory, "admin-migration-v1.json"),
                };
            }
        }

        private sealed class Inventory
        {
            [JsonProperty("schema")]
            public string Schema { get; set; }
            [JsonProperty("resources")]
            public InventoryResource[] Resources { get; set; }
        }

        private sealed class InventoryResource
        {
            [JsonProperty("id")]
            public string Id { get; set; }
            [JsonProperty("kind")]
            public string Kind { get; set; }
            [JsonProperty("views")]
            public string[] Views { get; set; }
            [JsonProperty("path")]
            public string Path { get; set; }
            [JsonProperty("name")]
            public string Name { get; set; }
        }

        private sealed class MigrationJournal
        {
            [JsonProperty("schema")]
            public string Schema { get; set; }
            [JsonProperty("transactionId", NullValueHandling = NullValueHandling.Ignore)]
            public string TransactionId { get; set; }
            [JsonProperty("productVersion")]
            public string ProductVersion { get; set; }
            [JsonProperty("createdAtUtc")]
            public string CreatedAtUtc { get; set; }
            [JsonProperty("state")]
            public string State { get; set; }
            [JsonProperty("previousProviders")]
            public ProviderSnapshot[] PreviousProviders { get; set; }
            [JsonProperty("rollbackProviders")]
            public ProviderSnapshot[] RollbackProviders { get; set; }
            [JsonProperty("operations")]
            public List<JournalOperation> Operations { get; set; }
            [JsonProperty("installedManifest", NullValueHandling = NullValueHandling.Ignore)]
            public string InstalledManifest { get; set; }
            [JsonProperty("hadInstalledManifest")]
            public bool HadInstalledManifest { get; set; }
            [JsonProperty("manifestBackup", NullValueHandling = NullValueHandling.Ignore)]
            public string ManifestBackup { get; set; }
            [JsonProperty("manifestBackupSha256", NullValueHandling = NullValueHandling.Ignore)]
            public string ManifestBackupSha256 { get; set; }
            [JsonProperty("previousJournalBackup", NullValueHandling = NullValueHandling.Ignore)]
            public string PreviousJournalBackup { get; set; }
            [JsonProperty("previousJournalSha256", NullValueHandling = NullValueHandling.Ignore)]
            public string PreviousJournalSha256 { get; set; }
        }

        private sealed class ProviderSnapshot
        {
            [JsonProperty("view")]
            public string View { get; set; }
            [JsonProperty("existed")]
            public bool Existed { get; set; }
            [JsonProperty("value")]
            public string Value { get; set; }
            [JsonProperty("ownedClientExisted")]
            public bool OwnedClientExisted { get; set; }
            [JsonProperty("ownedClientDefault", NullValueHandling = NullValueHandling.Ignore)]
            public string OwnedClientDefault { get; set; }
            [JsonProperty("ownedDllPath", NullValueHandling = NullValueHandling.Ignore)]
            public string OwnedDllPath { get; set; }
            [JsonProperty("ownedDllBackup", NullValueHandling = NullValueHandling.Ignore)]
            public string OwnedDllBackup { get; set; }
            [JsonProperty("ownedDllBackupSha256", NullValueHandling = NullValueHandling.Ignore)]
            public string OwnedDllBackupSha256 { get; set; }
        }

        private sealed class JournalOperation
        {
            [JsonProperty("id")]
            public string Id { get; set; }
            [JsonProperty("kind")]
            public string Kind { get; set; }
            [JsonProperty("target")]
            public string Target { get; set; }
            [JsonProperty("status")]
            public string Status { get; set; }
        }

        private sealed class InstalledComponentManifest
        {
            [JsonProperty("schema")]
            public string Schema { get; set; }
            [JsonProperty("component")]
            public string Component { get; set; }
            [JsonProperty("version")]
            public string Version { get; set; }
            [JsonProperty("queueProtocol")]
            public string QueueProtocol { get; set; }
            [JsonProperty("requires")]
            public ComponentRequirement Requires { get; set; }
            [JsonProperty("artifacts")]
            public InstalledArtifact[] Artifacts { get; set; }
        }

        private sealed class ComponentRequirement
        {
            [JsonProperty("component")]
            public string Component { get; set; }
            [JsonProperty("minInclusive")]
            public string MinInclusive { get; set; }
            [JsonProperty("maxExclusive")]
            public string MaxExclusive { get; set; }
        }

        private sealed class InstalledArtifact
        {
            [JsonProperty("architecture")]
            public string Architecture { get; set; }
            [JsonProperty("path")]
            public string Path { get; set; }
            [JsonProperty("peProductVersion")]
            public string PeProductVersion { get; set; }
            [JsonProperty("sha256")]
            public string Sha256 { get; set; }
        }
    }
}
