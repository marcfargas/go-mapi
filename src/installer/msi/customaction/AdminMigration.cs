using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Security.Cryptography;
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

        [CustomAction]
        public static ActionResult PrepareAdminMigration(Session session)
        {
            return Guard(session, "prepare", () =>
            {
                var paths = Paths.Create();
                Directory.CreateDirectory(paths.JournalDirectory);

                var previous = LoadJournal(paths.JournalPath);
                var keepOriginal = previous != null
                    && previous.Schema == JournalSchema
                    && previous.State == "committed"
                    && IsGoMapiActive(RegistryView.Registry64)
                    && IsGoMapiActive(RegistryView.Registry32);

                var rollbackProviders = new[]
                {
                    CaptureProvider(RegistryView.Registry64, paths.JournalDirectory, "rollback"),
                    CaptureProvider(RegistryView.Registry32, paths.JournalDirectory, "rollback"),
                };
                var journal = new MigrationJournal
                {
                    Schema = JournalSchema,
                    ProductVersion = session["ProductVersion"],
                    CreatedAtUtc = DateTime.UtcNow.ToString("o", CultureInfo.InvariantCulture),
                    State = "prepared",
                    PreviousProviders = keepOriginal
                        ? previous.PreviousProviders
                        : new[]
                        {
                            CaptureProvider(RegistryView.Registry64, paths.JournalDirectory, "original"),
                            CaptureProvider(RegistryView.Registry32, paths.JournalDirectory, "original"),
                        },
                    RollbackProviders = rollbackProviders,
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
                var data = new CustomActionData
                {
                    ["JournalPath"] = paths.JournalPath,
                    ["InstallRoot"] = paths.InstallRoot,
                    ["Version"] = session["ProductVersion"],
                    ["RequiredAppMin"] = session["GOMAPI_REQUIRED_APP_MIN"],
                    ["FailurePoint"] = session["GOMAPI_TEST_FAILURE_POINT"] ?? "",
                }.ToString();
                session["RollbackAdminMigration"] = data;
                session["ApplyAdminMigration"] = data;
                session["VerifyAdminRegistration"] = data;
            });
        }

        [CustomAction]
        public static ActionResult ApplyAdminMigration(Session session)
        {
            return Guard(session, "cleanup", () =>
            {
                var journalPath = session.CustomActionData["JournalPath"];
                var journal = RequireJournal(journalPath);
                MaybeFail(session.CustomActionData, "before-cleanup");
                foreach (var resource in LoadInventory().Resources)
                {
                    CleanupResource(resource, session);
                    var operation = journal.Operations.Single(item => item.Id == resource.Id);
                    operation.Status = "removed-or-absent";
                }
                journal.State = "cleaned";
                SaveJournal(journalPath, journal);
                MaybeFail(session.CustomActionData, "after-cleanup");
            });
        }

        [CustomAction]
        public static ActionResult VerifyAdminRegistration(Session session)
        {
            return Guard(session, "verify-and-commit", () =>
            {
                var data = session.CustomActionData;
                var journalPath = data["JournalPath"];
                var installRoot = data["InstallRoot"];
                var version = data["Version"];
                var requiredAppMin = data["RequiredAppMin"];
                if (string.IsNullOrWhiteSpace(requiredAppMin))
                    throw new InvalidDataException("Required app minimum version is absent");
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
                    },
                    Artifacts = new[]
                    {
                        BuildArtifact("x86", @"x86\go-mapi.dll", x86, version),
                        BuildArtifact("x64", @"AMD64\go-mapi.dll", x64, version),
                    },
                };

                var manifestPath = Path.Combine(installRoot, "installed-component-v1.json");
                AtomicWriteJson(manifestPath, manifest);
                var journal = RequireJournal(journalPath);
                journal.State = "committed";
                journal.InstalledManifest = manifestPath;
                SaveJournal(journalPath, journal);
            });
        }

        private static void MaybeFail(CustomActionData data, string point)
        {
            if (data.ContainsKey("FailurePoint")
                && string.Equals(data["FailurePoint"], point, StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException("Requested validation failure point: " + point);
        }

        [CustomAction]
        public static ActionResult RollbackAdminMigration(Session session)
        {
            return Guard(session, "rollback", () =>
            {
                var data = session.CustomActionData;
                var journalPath = data["JournalPath"];
                var journal = LoadJournal(journalPath);
                if (journal == null)
                    return;

                RemoveOwnedClient(RegistryView.Registry64);
                RemoveOwnedClient(RegistryView.Registry32);
                RestoreProvider(journal.RollbackProviders, RegistryView.Registry64, true);
                RestoreProvider(journal.RollbackProviders, RegistryView.Registry32, true);
                DeleteFileIfExists(Path.Combine(data["InstallRoot"], "installed-component-v1.json"));
                journal.State = "rolled-back";
                SaveJournal(journalPath, journal);
            });
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
                }.ToString();
                session["RollbackAdminUninstall"] = data;
                session["FinalizeAdminUninstall"] = data;
            });
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
                DeleteFileIfExists(Path.Combine(data["InstallRoot"], "installed-component-v1.json"));
            });
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
                return ActionResult.Failure;
            }
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

        private static ProviderSnapshot CaptureProvider(RegistryView view, string journalDirectory, string backupPrefix)
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
                        var backupDirectory = Path.Combine(journalDirectory, "backup");
                        Directory.CreateDirectory(backupDirectory);
                        snapshot.OwnedDllBackup = Path.Combine(backupDirectory, backupPrefix + "-" + view + "-go-mapi.dll");
                        File.Copy(snapshot.OwnedDllPath, snapshot.OwnedDllBackup, true);
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
                throw new InvalidDataException(architecture + " PE ProductVersion does not match MSI version");
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
                Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "go-mapi", "uninst"),
            }.Select(item => Path.GetFullPath(item).TrimEnd(Path.DirectorySeparatorChar));
            if (!allowed.Contains(full, StringComparer.OrdinalIgnoreCase))
                throw new InvalidDataException("Refusing non-owned directory: " + full);
            Directory.Delete(full, true);
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
            return JsonConvert.DeserializeObject<MigrationJournal>(File.ReadAllText(path));
        }

        private static void SaveJournal(string path, MigrationJournal journal)
        {
            AtomicWriteJson(path, journal);
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
