# scripts/register-dev-aumid.ps1
# Registers a HKCU Start Menu shortcut for go-mapi dev builds with AUMID
# "com.marcfargas.gomapi.dev" so toast notifications during `wails dev` persist
# in Windows Action Center.
#
# Idempotent: running twice is a no-op (skip-if-exists). Safe to re-run after
# every git pull. Re-run with -Force to recreate the shortcut.
#
# Phase 10 (INST-04) will ship the prod equivalent via the NSIS installer with:
#   - AUMID: com.marcfargas.gomapi (no .dev suffix)
#   - Shortcut path: %ProgramFiles%\go-mapi\go-mapi.lnk
#   - Registration: NSIS installer (not PowerShell).
#
# Usage:
#   .\scripts\register-dev-aumid.ps1
#   .\scripts\register-dev-aumid.ps1 -ExePath 'C:\path\to\go-mapi.exe'
#   .\scripts\register-dev-aumid.ps1 -Force  # recreate even if shortcut exists

[CmdletBinding()]
param(
    [string]$Aumid   = 'com.marcfargas.gomapi.dev',
    [string]$Name    = 'go-mapi (dev)',
    [string]$ExePath,                  # absolute path to go-mapi.exe; defaults below
    [switch]$Force                     # recreate shortcut even if it already exists
)

$ErrorActionPreference = 'Stop'

if (-not $ExePath) {
    # Default: src/app/build/bin/go-mapi.exe relative to repo root.
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
    $ExePath  = Join-Path $repoRoot 'src\app\build\bin\go-mapi.exe'
}
if (-not (Test-Path -LiteralPath $ExePath)) {
    Write-Warning "go-mapi.exe not found at $ExePath"
    Write-Warning 'Run `wails build` first, or pass -ExePath explicitly.'
    # Still proceed: the shortcut can point to a not-yet-existing path;
    # wails build will place the binary there before the next dev session.
}

$startMenu = [Environment]::GetFolderPath('Programs')  # %APPDATA%\Microsoft\Windows\Start Menu\Programs
$lnkPath   = Join-Path $startMenu "$Name.lnk"

# ---- Idempotency check: skip if shortcut already exists (unless -Force).
if ((Test-Path -LiteralPath $lnkPath) -and -not $Force) {
    Write-Host "AUMID shortcut already exists at $lnkPath — skipping." -ForegroundColor Green
    Write-Host "Pass -Force to recreate it."
    return
}

# ---- Create the .lnk via WScript.Shell (sets TargetPath + metadata).
$wsh = New-Object -ComObject WScript.Shell
$sc  = $wsh.CreateShortcut($lnkPath)
$sc.TargetPath       = $ExePath
$sc.WorkingDirectory = Split-Path $ExePath -Parent
$sc.Description      = 'go-mapi (dev) — MAPI-to-Gmail bridge'
$sc.Save()
[System.Runtime.InteropServices.Marshal]::ReleaseComObject($wsh) | Out-Null

# ---- Stamp PKEY_AppUserModel_ID on the .lnk via inline C# + IShellLink + IPropertyStore.
# Reference: https://learn.microsoft.com/en-us/windows/win32/properties/props-system-appusermodel-id
# The Add-Type call is idempotent within a PowerShell session (already-defined type is silently reused).
if (-not ([System.Management.Automation.PSTypeName]'GoMapi.AumidShortcut').Type) {
    Add-Type -Namespace GoMapi -Name AumidShortcut -MemberDefinition @'
        using System;
        using System.Runtime.InteropServices;

        [ComImport, Guid("000214F9-0000-0000-C000-000000000046"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        public interface IShellLinkW {
            void GetPath(out IntPtr a, int b, out IntPtr c, int d);
            void GetIDList(out IntPtr ppidl);
            void SetIDList(IntPtr pidl);
            void GetDescription([MarshalAs(UnmanagedType.LPWStr)] out string pszName, int cch);
            void SetDescription([MarshalAs(UnmanagedType.LPWStr)] string pszName);
            void GetWorkingDirectory([MarshalAs(UnmanagedType.LPWStr)] out string pszDir, int cch);
            void SetWorkingDirectory([MarshalAs(UnmanagedType.LPWStr)] string pszDir);
            void GetArguments([MarshalAs(UnmanagedType.LPWStr)] out string pszArgs, int cch);
            void SetArguments([MarshalAs(UnmanagedType.LPWStr)] string pszArgs);
            void GetHotkey(out short pwHotkey);
            void SetHotkey(short wHotkey);
            void GetShowCmd(out int piShowCmd);
            void SetShowCmd(int iShowCmd);
            void GetIconLocation([MarshalAs(UnmanagedType.LPWStr)] out string pszIconPath, int cch, out int piIcon);
            void SetIconLocation([MarshalAs(UnmanagedType.LPWStr)] string pszIconPath, int iIcon);
            void SetRelativePath([MarshalAs(UnmanagedType.LPWStr)] string pszPathRel, uint dwReserved);
            void Resolve(IntPtr hwnd, uint fFlags);
            void SetPath([MarshalAs(UnmanagedType.LPWStr)] string pszFile);
        }

        [ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        public interface IPropertyStore {
            void GetCount(out uint count);
            void GetAt(uint iProp, out PROPERTYKEY pkey);
            void GetValue(ref PROPERTYKEY key, out PROPVARIANT pv);
            void SetValue(ref PROPERTYKEY key, ref PROPVARIANT pv);
            void Commit();
        }

        [StructLayout(LayoutKind.Sequential, Pack = 4)]
        public struct PROPERTYKEY {
            public Guid fmtid;
            public uint pid;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct PROPVARIANT {
            public ushort vt;
            public ushort reserved1;
            public ushort reserved2;
            public ushort reserved3;
            public IntPtr union1;
            public IntPtr union2;
        }

        [ComImport, Guid("0000010B-0000-0000-C000-000000000046"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        public interface IPersistFile {
            void GetClassID(out Guid pClassID);
            [PreserveSig] int IsDirty();
            void Load([MarshalAs(UnmanagedType.LPWStr)] string pszFileName, uint dwMode);
            void Save([MarshalAs(UnmanagedType.LPWStr)] string pszFileName, bool fRemember);
            void SaveCompleted([MarshalAs(UnmanagedType.LPWStr)] string pszFileName);
            void GetCurFile([MarshalAs(UnmanagedType.LPWStr)] out string ppszFileName);
        }

        public static class Native {
            [DllImport("ole32.dll", PreserveSig = false)]
            public static extern void CoCreateInstance(
                [MarshalAs(UnmanagedType.LPStruct)] Guid rclsid,
                IntPtr pUnkOuter,
                uint dwClsContext,
                [MarshalAs(UnmanagedType.LPStruct)] Guid riid,
                [MarshalAs(UnmanagedType.IUnknown)] out object ppv);

            [DllImport("propsys.dll", CharSet = CharSet.Unicode, PreserveSig = false)]
            public static extern void InitPropVariantFromString(
                [MarshalAs(UnmanagedType.LPWStr)] string psz,
                out PROPVARIANT ppropvar);
        }

        public static class SetAumid {
            // ShellLink CLSID  = {00021401-0000-0000-C000-000000000046}
            // PKEY_AppUserModel_ID = {9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3}, pid = 5
            public static void Apply(string lnkPath, string aumid) {
                Guid clsidShellLink = new Guid("00021401-0000-0000-C000-000000000046");
                Guid iidIShellLinkW = new Guid("000214F9-0000-0000-C000-000000000046");
                Native.CoCreateInstance(clsidShellLink, IntPtr.Zero, 1 /*CLSCTX_INPROC_SERVER*/, iidIShellLinkW, out object obj);

                IPersistFile pf = (IPersistFile)obj;
                pf.Load(lnkPath, 2 /*STGM_READWRITE*/);

                IPropertyStore ps = (IPropertyStore)obj;
                PROPERTYKEY key = new PROPERTYKEY {
                    fmtid = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3"),
                    pid   = 5
                };
                Native.InitPropVariantFromString(aumid, out PROPVARIANT pv);
                ps.SetValue(ref key, ref pv);
                ps.Commit();

                pf.Save(lnkPath, true);

                System.Runtime.InteropServices.Marshal.ReleaseComObject(obj);
            }
        }
'@
}

[GoMapi.AumidShortcut+SetAumid]::Apply($lnkPath, $Aumid)

Write-Host "Registered AUMID '$Aumid' on shortcut '$lnkPath'" -ForegroundColor Green
Write-Host "Target: $ExePath"
Write-Host
Write-Host "NOTE: log out and back in (or run 'Stop-Process -Name explorer && Start-Process explorer')"
Write-Host "      if the first toast from 'wails dev' does not persist in Action Center."
