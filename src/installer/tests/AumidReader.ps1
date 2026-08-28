# src/installer/tests/AumidReader.ps1
# Inline-C# IPropertyStore reader for PKEY_AppUserModel_ID on .lnk files.
# Used by installer.Tests.ps1 D-21 item 5 verification.
#
# Why not Get-StartApps:
#   Freshly-installed shortcuts have an indexing delay before Get-StartApps
#   lists them. Tests would flake. Inline C# + IShellLink + IPropertyStore
#   is the stable primitive (verified RESEARCH 2026; matches
#   scripts/register-dev-aumid.ps1 on the stamp side).
#
# Why the type definition lives in a dot-sourced file:
#   Add-Type with the same Namespace/Name is idempotent in the same PS session
#   but noisy if repeated; isolating to a helper keeps the Pester file clean.

# IN-06: guard on PublicReader (the actual entry point used by Get-ShortcutAumid
# below) rather than Reader. Add-Type -Name Reader compiles all inline types into
# a single assembly; if a previous definition was loaded into the session,
# checking the symbol that is actually called catches stale-definition scenarios
# that checking `Reader` would miss.
if (-not ('GoMapi.AumidReader.PublicReader' -as [type])) {
    # -MemberDefinition is wrapped by Add-Type in the class named by -Name;
    # this source declares multiple top-level interfaces/types, so wrapping it
    # makes the leading using directives invalid C#. Compile the complete type
    # definition instead.
    Add-Type -TypeDefinition @'
        using System;
        using System.Runtime.InteropServices;
        using System.Text;

        namespace GoMapi.AumidReader {

        [ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        internal interface IPropertyStore {
            void GetCount(out uint count);
            void GetAt(uint iProp, out PROPERTYKEY pkey);
            void GetValue(ref PROPERTYKEY key, out PROPVARIANT pv);
            void SetValue(ref PROPERTYKEY key, ref PROPVARIANT pv);
            void Commit();
        }

        [StructLayout(LayoutKind.Sequential, Pack = 4)]
        internal struct PROPERTYKEY { public Guid fmtid; public uint pid; }

        [StructLayout(LayoutKind.Sequential)]
        internal struct PROPVARIANT {
            public ushort vt;
            public ushort reserved1;
            public ushort reserved2;
            public ushort reserved3;
            public IntPtr union1;
            public IntPtr union2;
        }

        [ComImport, Guid("0000010B-0000-0000-C000-000000000046"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        internal interface IPersistFile {
            void GetClassID(out Guid pClassID);
            [PreserveSig] int IsDirty();
            void Load([MarshalAs(UnmanagedType.LPWStr)] string pszFileName, uint dwMode);
            void Save([MarshalAs(UnmanagedType.LPWStr)] string pszFileName, bool fRemember);
            void SaveCompleted([MarshalAs(UnmanagedType.LPWStr)] string pszFileName);
            void GetCurFile([MarshalAs(UnmanagedType.LPWStr)] out string ppszFileName);
        }

        internal static class Native {
            [DllImport("ole32.dll", PreserveSig = false)]
            public static extern void CoCreateInstance(
                [MarshalAs(UnmanagedType.LPStruct)] Guid rclsid,
                IntPtr pUnkOuter, uint dwClsContext,
                [MarshalAs(UnmanagedType.LPStruct)] Guid riid,
                [MarshalAs(UnmanagedType.IUnknown)] out object ppv);

            [DllImport("propsys.dll", CharSet = CharSet.Unicode, PreserveSig = false)]
            public static extern void PropVariantToString(ref PROPVARIANT pv, StringBuilder psz, int cch);

            [DllImport("ole32.dll")]
            public static extern int PropVariantClear(ref PROPVARIANT pvar);
        }

        public static class PublicReader {
            // PKEY_AppUserModel_ID = {9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3}, PID 5
            // Reference: https://learn.microsoft.com/en-us/windows/win32/properties/props-system-appusermodel-id
            public static string GetAumid(string lnkPath) {
                Guid clsidShellLink = new Guid("00021401-0000-0000-C000-000000000046");
                Guid iidIPersistFile = new Guid("0000010B-0000-0000-C000-000000000046");
                Native.CoCreateInstance(clsidShellLink, IntPtr.Zero, 1 /*CLSCTX_INPROC_SERVER*/, iidIPersistFile, out object obj);

                try {
                    IPersistFile pf = (IPersistFile)obj;
                    pf.Load(lnkPath, 0 /*STGM_READ*/);

                    IPropertyStore ps = (IPropertyStore)obj;
                    PROPERTYKEY key = new PROPERTYKEY {
                        fmtid = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3"),
                        pid   = 5
                    };
                    PROPVARIANT pv;
                    ps.GetValue(ref key, out pv);
                    try {
                        var sb = new StringBuilder(260);
                        Native.PropVariantToString(ref pv, sb, sb.Capacity);
                        return sb.ToString();
                    } finally {
                        Native.PropVariantClear(ref pv);
                    }
                } finally {
                    Marshal.ReleaseComObject(obj);
                }
            }
        }
        }
'@
}

function Get-ShortcutAumid {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateScript({ Test-Path $_ -PathType Leaf })]
        [string]$Path
    )
    $absPath = (Resolve-Path -LiteralPath $Path).ProviderPath
    return [GoMapi.AumidReader.PublicReader]::GetAumid($absPath)
}

if ($ExecutionContext.SessionState.Module) {
    Export-ModuleMember -Function Get-ShortcutAumid
}
