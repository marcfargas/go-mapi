#include "fs_utils.h"
#include <shlobj.h>
#include <aclapi.h>
#include <cstring>
#include <cwctype>

namespace go_mapi {
namespace {
struct ScopedHandle {
    HANDLE value{INVALID_HANDLE_VALUE};
    explicit ScopedHandle(HANDLE handle = INVALID_HANDLE_VALUE) : value(handle) {}
    ~ScopedHandle() { if (value != INVALID_HANDLE_VALUE && value != nullptr) CloseHandle(value); }
    ScopedHandle(const ScopedHandle&) = delete;
    ScopedHandle& operator=(const ScopedHandle&) = delete;
};

bool TrustedWriterSid(PSID sid) {
    if (IsWellKnownSid(sid, WinLocalSystemSid) || IsWellKnownSid(sid, WinBuiltinAdministratorsSid)) return true;
    const SID_IDENTIFIER_AUTHORITY ntAuthority = SECURITY_NT_AUTHORITY;
    return IsValidSid(sid) &&
        memcmp(GetSidIdentifierAuthority(sid), &ntAuthority, sizeof(ntAuthority)) == 0 &&
        *GetSidSubAuthorityCount(sid) > 0 && *GetSidSubAuthority(sid, 0) == 80;
}

bool TrustedObjectACL(HANDLE handle, SE_OBJECT_TYPE kind) {
    PSID owner = nullptr;
    PACL dacl = nullptr;
    PSECURITY_DESCRIPTOR descriptor = nullptr;
    const DWORD result = GetSecurityInfo(handle, kind,
        OWNER_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION,
        &owner, nullptr, &dacl, nullptr, &descriptor);
    if (result != ERROR_SUCCESS) return false;
    const bool trustedOwner = owner && (IsWellKnownSid(owner, WinLocalSystemSid) ||
                                       IsWellKnownSid(owner, WinBuiltinAdministratorsSid));
    bool trusted = trustedOwner && dacl != nullptr;
    const DWORD fileWrite = FILE_WRITE_DATA | FILE_APPEND_DATA | FILE_WRITE_EA | FILE_WRITE_ATTRIBUTES |
        DELETE | WRITE_DAC | WRITE_OWNER | GENERIC_WRITE | GENERIC_ALL;
    const DWORD keyWrite = KEY_SET_VALUE | KEY_CREATE_SUB_KEY | KEY_CREATE_LINK |
        DELETE | WRITE_DAC | WRITE_OWNER | GENERIC_WRITE | GENERIC_ALL;
    for (DWORD i = 0; trusted && i < dacl->AceCount; ++i) {
        void* ace = nullptr;
        if (!GetAce(dacl, i, &ace)) { trusted = false; break; }
        const auto* header = static_cast<ACE_HEADER*>(ace);
        if (header->AceType == ACCESS_DENIED_ACE_TYPE) continue;
        if (header->AceType != ACCESS_ALLOWED_ACE_TYPE) { trusted = false; break; }
        const auto* allowed = static_cast<ACCESS_ALLOWED_ACE*>(ace);
        PSID sid = const_cast<DWORD*>(&allowed->SidStart);
        if (allowed->Mask & (kind == SE_REGISTRY_KEY ? keyWrite : fileWrite)) {
            trusted = TrustedWriterSid(sid);
        }
    }
    LocalFree(descriptor);
    return trusted;
}

std::wstring KnownFolder(REFKNOWNFOLDERID folder) {
    PWSTR raw = nullptr;
    if (FAILED(SHGetKnownFolderPath(folder, 0, nullptr, &raw)) || !raw) return L"";
    std::wstring path(raw);
    CoTaskMemFree(raw);
    return path;
}

// FOLDERID_ProgramFilesX64 fails for a WOW64 caller. Read the native
// ProgramFilesDir from the 64-bit HKLM view instead; never use the caller's
// environment or the redirected 32-bit Program Files folder.
std::wstring NativeProgramFiles() {
    if (sizeof(void*) == 8) return KnownFolder(FOLDERID_ProgramFilesX64);
    HKEY key = nullptr;
    if (RegOpenKeyExW(HKEY_LOCAL_MACHINE,
        L"SOFTWARE\\Microsoft\\Windows\\CurrentVersion", 0,
        KEY_QUERY_VALUE | KEY_WOW64_64KEY, &key) != ERROR_SUCCESS) return L"";
    wchar_t value[MAX_PATH]{};
    DWORD type = 0, bytes = sizeof(value);
    const bool found = RegQueryValueExW(key, L"ProgramFilesDir", nullptr,
        &type, reinterpret_cast<BYTE*>(value), &bytes) == ERROR_SUCCESS;
    RegCloseKey(key);
    if (!found || type != REG_SZ || bytes < 4 * sizeof(wchar_t) ||
        bytes > sizeof(value) || bytes % sizeof(wchar_t) != 0 ||
        value[bytes / sizeof(wchar_t) - 1] != L'\0') return L"";
    const std::wstring path(value, bytes / sizeof(wchar_t) - 1);
    // Reject relative, device, expanded, and noncanonical values before
    // appending the fixed product path. The installed-file checks below still
    // validate each protected object and the exact DLL location.
    if (path.size() < 3 || !std::iswalpha(path[0]) || path[1] != L':' ||
        path[2] != L'\\' || path.back() == L'\\' ||
        path.find(L'\0') != std::wstring::npos ||
        path.find(L"\\..\\") != std::wstring::npos ||
        path.find(L"\\.\\") != std::wstring::npos ||
        path.compare(path.size() - 3, 3, L"\\..") == 0 ||
        path.compare(path.size() - 2, 2, L"\\.") == 0) return L"";
    return path;
}

bool OrdinaryKnownFolder(const std::wstring& path) {
    const DWORD attributes = GetFileAttributesW(path.c_str());
    return attributes != INVALID_FILE_ATTRIBUTES &&
        (attributes & FILE_ATTRIBUTE_DIRECTORY) &&
        !(attributes & FILE_ATTRIBUTE_REPARSE_POINT);
}

bool ProtectedFileSystemObject(const std::wstring& path, bool directory) {
    const DWORD attributes = GetFileAttributesW(path.c_str());
    if (attributes == INVALID_FILE_ATTRIBUTES || (attributes & FILE_ATTRIBUTE_REPARSE_POINT) ||
        ((attributes & FILE_ATTRIBUTE_DIRECTORY) != 0) != directory) return false;
    const DWORD access = READ_CONTROL | FILE_READ_ATTRIBUTES | (directory ? 0 : FILE_READ_DATA);
    ScopedHandle handle(CreateFileW(path.c_str(), access, FILE_SHARE_READ | FILE_SHARE_WRITE,
        nullptr, OPEN_EXISTING, FILE_FLAG_OPEN_REPARSE_POINT |
        (directory ? FILE_FLAG_BACKUP_SEMANTICS : 0), nullptr));
    if (handle.value == INVALID_HANDLE_VALUE) return false;
    BY_HANDLE_FILE_INFORMATION info{};
    return GetFileInformationByHandle(handle.value, &info) &&
        !(info.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) &&
        ((info.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0) == directory &&
        TrustedObjectACL(handle.value, SE_FILE_OBJECT);
}

void ModuleAnchor() {}

bool IsInstalledSuiteDll(const std::wstring& files) {
    HMODULE module = nullptr;
    if (!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS |
        GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
        reinterpret_cast<LPCWSTR>(&ModuleAnchor), &module)) return false;
    wchar_t actual[MAX_PATH]{};
    const DWORD length = GetModuleFileNameW(module, actual, MAX_PATH);
    if (!length || length >= MAX_PATH) return false;
    const std::wstring root = files + L"\\go-mapi";
    const std::wstring interceptor = root + L"\\interceptor";
    const std::wstring arch = interceptor + (sizeof(void*) == 8 ? L"\\AMD64" : L"\\x86");
    const std::wstring expected = arch + L"\\go-mapi.dll";
    return _wcsicmp(actual, expected.c_str()) == 0 &&
        ProtectedFileSystemObject(root, true) &&
        ProtectedFileSystemObject(interceptor, true) &&
        ProtectedFileSystemObject(arch, true) &&
        ProtectedFileSystemObject(expected, false);
}

bool SuiteMarker() {
    HKEY raw = nullptr;
    if (RegOpenKeyExW(HKEY_LOCAL_MACHINE, L"SOFTWARE\\go-mapi\\MachineProduct", 0,
        KEY_READ | KEY_WOW64_64KEY, &raw) != ERROR_SUCCESS) return false;
    const bool trusted = TrustedObjectACL(reinterpret_cast<HANDLE>(raw), SE_REGISTRY_KEY);
    wchar_t sku[32]{};
    DWORD type = 0, size = sizeof(sku);
    const bool suite = trusted && RegQueryValueExW(raw, L"SKU", nullptr, &type,
        reinterpret_cast<BYTE*>(sku), &size) == ERROR_SUCCESS &&
        type == REG_SZ && size == 6 * sizeof(wchar_t) &&
        sku[size / sizeof(wchar_t) - 1] == L'\0' && wcscmp(sku, L"suite") == 0;
    RegCloseKey(raw);
    return suite;
}

bool LaunchUnderAdmission(const std::wstring& gate, const std::wstring& exe) {
    ScopedHandle file(CreateFileW(gate.c_str(), GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE,
        nullptr, OPEN_EXISTING, FILE_FLAG_OPEN_REPARSE_POINT, nullptr));
    BY_HANDLE_FILE_INFORMATION info{};
    if (file.value == INVALID_HANDLE_VALUE || !GetFileInformationByHandle(file.value, &info) ||
        (info.dwFileAttributes & (FILE_ATTRIBUTE_REPARSE_POINT | FILE_ATTRIBUTE_DIRECTORY)) ||
        !TrustedObjectACL(file.value, SE_FILE_OBJECT) ||
        !ProtectedFileSystemObject(gate, false)) return false;
    OVERLAPPED overlap{};
    const ULONGLONG deadline = GetTickCount64() + 250;
    for (;;) {
        if (LockFileEx(file.value, LOCKFILE_FAIL_IMMEDIATELY, 0, 1, 0, &overlap)) break;
        if (GetLastError() != ERROR_LOCK_VIOLATION || GetTickCount64() >= deadline) return false;
        Sleep(10);
    }
    bool launched = false;
    LARGE_INTEGER size{};
    char byte = 0;
    DWORD read = 0;
    if (ProtectedFileSystemObject(gate, false) && GetFileSizeEx(file.value, &size) &&
        size.QuadPart == 1 && ReadFile(file.value, &byte, 1, &read, nullptr) &&
        read == 1 && byte == 'O') {
        std::wstring command = L"\"" + exe + L"\"";
        STARTUPINFOW startup{};
        startup.cb = sizeof(startup);
        startup.dwFlags = STARTF_USESHOWWINDOW;
        startup.wShowWindow = SW_HIDE;
        PROCESS_INFORMATION process{};
        if (CreateProcessW(exe.c_str(), command.data(), nullptr, nullptr, FALSE,
            0, nullptr, nullptr, &startup, &process)) {
            ScopedHandle child(process.hProcess), thread(process.hThread);
            launched = true;
        }
    }
    UnlockFileEx(file.value, 0, 1, 0, &overlap);
    return launched;
}
}

bool FsUtils::ActivateSuiteAppAfterPublication() {
    const std::wstring files = NativeProgramFiles();
    const std::wstring data = KnownFolder(FOLDERID_ProgramData);
    if (files.empty() || data.empty() || !OrdinaryKnownFolder(files) ||
        !OrdinaryKnownFolder(data) || !IsInstalledSuiteDll(files) || !SuiteMarker()) return false;
    const std::wstring appDir = files + L"\\go-mapi\\user";
    const std::wstring exe = appDir + L"\\go-mapi.exe";
    const std::wstring base = data + L"\\go-mapi";
    const std::wstring status = base + L"\\status";
    const std::wstring gate = status + L"\\suite-admission-v1";
    if (!ProtectedFileSystemObject(appDir, true) || !ProtectedFileSystemObject(exe, false) ||
        !ProtectedFileSystemObject(base, true) || !ProtectedFileSystemObject(status, true)) return false;
    const bool launched = LaunchUnderAdmission(gate, exe);
    const std::wstring queue = GetQueueDirectory();
    if (!queue.empty()) {
        const std::wstring warning = queue + L"warnings\\suite-admission-unavailable.warning";
        if (launched) {
            DeleteFileW(warning.c_str());
        } else if (FsUtils::EnsureOutputDirectory()) {
            (void)FsUtils::WriteFileAtomically(warning,
                "go-mapi: shared app startup is unavailable. Queued mail is retained.\n");
        }
    }
    return launched;
}
} // namespace go_mapi
