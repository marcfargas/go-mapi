// TODO: cover GetQueueDirectory + EnsureOutputDirectory in a future C++ unit harness.

#include "fs_utils.h"
#include <shlobj.h>
#include <ctime>
#include <random>
#include <iomanip>
#include <sstream>
#include <atomic>
#include <algorithm>
#include <cstdio>

namespace go_mapi {

namespace {
std::atomic<FsUtils::AtomicWriteFault> atomicWriteFault{FsUtils::AtomicWriteFault::None};

constexpr char kAppPresenceToken[] = "go-mapi-app-presence-v1\n";
constexpr ULONGLONG kPresenceStaleAfter100ns = 5ULL * 60ULL * 10000000ULL;
constexpr size_t kMaxComponentStateBytes = 4096;

ULONGLONG FileTimeTicks(FILETIME value) {
    ULARGE_INTEGER ticks{};
    ticks.LowPart = value.dwLowDateTime;
    ticks.HighPart = value.dwHighDateTime;
    return ticks.QuadPart;
}

const char* PresenceReason(FsUtils::AppPresenceStatus status) {
    switch (status) {
    case FsUtils::AppPresenceStatus::Missing: return "missing";
    case FsUtils::AppPresenceStatus::Unreadable: return "unreadable";
    case FsUtils::AppPresenceStatus::Malformed: return "malformed";
    case FsUtils::AppPresenceStatus::Stale: return "stale";
    case FsUtils::AppPresenceStatus::Future: return "future";
    case FsUtils::AppPresenceStatus::Available: return "available";
    }
    return "unknown";
}

bool ReadSmallFile(HANDLE file, std::string& contents) {
    LARGE_INTEGER size{};
    if (!GetFileSizeEx(file, &size) || size.QuadPart < 0 ||
        static_cast<ULONGLONG>(size.QuadPart) > kMaxComponentStateBytes) return false;
    contents.resize(static_cast<size_t>(size.QuadPart));
    DWORD bytesRead = 0;
    return (contents.empty() || ReadFile(file, contents.data(), static_cast<DWORD>(contents.size()), &bytesRead, nullptr)) &&
           bytesRead == static_cast<DWORD>(contents.size());
}

bool ExtractJsonString(const std::string& json, const std::string& key, std::string& output) {
    const std::string marker = "\"" + key + "\"";
    size_t pos = json.find(marker);
    if (pos == std::string::npos || json.find(marker, pos + marker.size()) != std::string::npos) return false;
    pos = json.find(':', pos + marker.size());
    if (pos == std::string::npos) return false;
    pos = json.find_first_not_of(" \t\r\n", pos + 1);
    if (pos == std::string::npos || json[pos] != '"') return false;
    const size_t end = json.find('"', pos + 1);
    if (end == std::string::npos || json.find('\\', pos + 1) < end) return false;
    output = json.substr(pos + 1, end - pos - 1);
    return true;
}

std::string UtcNowIso8601() {
    SYSTEMTIME value{};
    GetSystemTime(&value);
    char buffer[32]{};
    std::snprintf(buffer, sizeof(buffer), "%04u-%02u-%02uT%02u:%02u:%02uZ",
                  value.wYear, value.wMonth, value.wDay,
                  value.wHour, value.wMinute, value.wSecond);
    return buffer;
}

bool WriteFileAtomicallyReplacing(const std::wstring& filePath, const std::string& content) {
    if (filePath.empty() || content.size() > MAXDWORD) return false;
    const std::wstring tempPath = filePath + L"." + FsUtils::GenerateUniqueStem() + L".tmp";
    HANDLE file = CreateFileW(tempPath.c_str(), GENERIC_WRITE, 0, nullptr,
                              CREATE_NEW, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE) return false;
    DWORD written = 0;
    const BOOL wrote = ::WriteFile(file, content.data(), static_cast<DWORD>(content.size()), &written, nullptr);
    const BOOL flushed = wrote && written == content.size() && FlushFileBuffers(file);
    const BOOL closed = CloseHandle(file);
    if (!flushed || !closed || !MoveFileExW(tempPath.c_str(), filePath.c_str(),
                                            MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)) {
        DeleteFileW(tempPath.c_str());
        return false;
    }
    return true;
}
}

void FsUtils::SetAtomicWriteFaultForTesting(AtomicWriteFault fault) {
    atomicWriteFault.store(fault);
}

std::wstring FsUtils::GetBaseQueueDir() {
    // CSIDL_LOCAL_APPDATA resolves to %LOCALAPPDATA% (e.g., C:\Users\<user>\AppData\Local).
    // Unlike GetTempPathW (which reads TMP/TEMP/USERPROFILE per-process), this is
    // session-scoped and NOT influenced by per-process TEMP/TMP env overrides —
    // fixes the legacy-app-overrides-TEMP bug where the DLL and the Wails watcher
    // disagreed on the queue location (quick/260423-msq).
    wchar_t path[MAX_PATH];
    HRESULT hr = SHGetFolderPathW(nullptr, CSIDL_LOCAL_APPDATA, nullptr, SHGFP_TYPE_CURRENT, path);
    if (FAILED(hr)) {
        return L"";
    }
    std::wstring result(path);
    if (!result.empty() && result.back() != L'\\') {
        result += L'\\';
    }
    result += L"go-mapi\\queue";
    return result;
}

std::wstring FsUtils::GetQueueDirectory() {
    std::wstring basePath = GetBaseQueueDir();
    if (!basePath.empty() && basePath.back() != L'\\') {
        basePath += L'\\';
    }
    return basePath;
}

std::wstring FsUtils::GetAppPresencePath() {
    wchar_t path[MAX_PATH];
    HRESULT hr = SHGetFolderPathW(nullptr, CSIDL_APPDATA, nullptr, SHGFP_TYPE_CURRENT, path);
    if (FAILED(hr)) return L"";
    std::wstring result(path);
    if (!result.empty() && result.back() != L'\\') result += L'\\';
    return result + L"go-mapi\\app-presence-v1";
}

FsUtils::AppPresenceStatus FsUtils::CheckAppPresence() {
    const std::wstring path = GetAppPresencePath();
    if (path.empty()) return AppPresenceStatus::Unreadable;
    FILETIME now{};
    GetSystemTimeAsFileTime(&now);
    return CheckAppPresenceFile(path, now);
}

FsUtils::AppPresenceStatus FsUtils::CheckAppPresenceFile(const std::wstring& path, FILETIME now) {
    HANDLE file = CreateFileW(path.c_str(), GENERIC_READ,
                              FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                              nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE) {
        return GetLastError() == ERROR_FILE_NOT_FOUND || GetLastError() == ERROR_PATH_NOT_FOUND
            ? AppPresenceStatus::Missing : AppPresenceStatus::Unreadable;
    }
    FILETIME writeTime{};
    const BOOL gotTime = GetFileTime(file, nullptr, nullptr, &writeTime);
    char contents[sizeof(kAppPresenceToken)] = {};
    DWORD bytesRead = 0;
    const BOOL read = ReadFile(file, contents, sizeof(contents), &bytesRead, nullptr);
    CloseHandle(file);
    if (!gotTime || !read) return AppPresenceStatus::Unreadable;
    if (bytesRead != sizeof(kAppPresenceToken) - 1 ||
        std::string(contents, bytesRead) != kAppPresenceToken) {
        return AppPresenceStatus::Malformed;
    }
    const ULONGLONG nowTicks = FileTimeTicks(now);
    const ULONGLONG writeTicks = FileTimeTicks(writeTime);
    if (writeTicks > nowTicks) return AppPresenceStatus::Future;
    if (nowTicks - writeTicks > kPresenceStaleAfter100ns) return AppPresenceStatus::Stale;
    return AppPresenceStatus::Available;
}

std::wstring FsUtils::GetAppComponentStatePath() {
    wchar_t path[MAX_PATH];
    HRESULT hr = SHGetFolderPathW(nullptr, CSIDL_APPDATA, nullptr, SHGFP_TYPE_CURRENT, path);
    if (FAILED(hr)) return L"";
    std::wstring result(path);
    if (!result.empty() && result.back() != L'\\') result += L'\\';
    return result + L"go-mapi\\app-component-state-v1.json";
}

FsUtils::AppComponentState FsUtils::CheckAppComponentState() {
    const std::wstring path = GetAppComponentStatePath();
    if (path.empty()) return {AppComponentStateStatus::Unreadable, ""};
    FILETIME now{};
    GetSystemTimeAsFileTime(&now);
    return CheckAppComponentStateFile(path, now);
}

FsUtils::AppComponentState FsUtils::CheckAppComponentStateFile(const std::wstring& path, FILETIME now) {
    HANDLE file = CreateFileW(path.c_str(), GENERIC_READ,
                              FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                              nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE) {
        const DWORD error = GetLastError();
        return {error == ERROR_FILE_NOT_FOUND || error == ERROR_PATH_NOT_FOUND
                    ? AppComponentStateStatus::Missing : AppComponentStateStatus::Unreadable, ""};
    }
    FILETIME writeTime{};
    std::string json;
    const bool ok = GetFileTime(file, nullptr, nullptr, &writeTime) && ReadSmallFile(file, json);
    CloseHandle(file);
    if (!ok) return {AppComponentStateStatus::Unreadable, ""};
    std::string schema, version, protocol, refreshed;
    if (!ExtractJsonString(json, "schema", schema) || schema != "go-mapi-app-component-state-v1" ||
        !ExtractJsonString(json, "version", version) ||
        !ExtractJsonString(json, "queueProtocol", protocol) || protocol != "queue-v1" ||
        !ExtractJsonString(json, "refreshedAt", refreshed)) {
        return {AppComponentStateStatus::Malformed, ""};
    }
    const ULONGLONG nowTicks = FileTimeTicks(now), writeTicks = FileTimeTicks(writeTime);
    if (writeTicks > nowTicks) return {AppComponentStateStatus::Future, version};
    if (nowTicks - writeTicks > kPresenceStaleAfter100ns) return {AppComponentStateStatus::Stale, version};
    return {AppComponentStateStatus::Available, version};
}

bool FsUtils::EnsureOutputDirectory() {
    std::wstring queueDir = GetBaseQueueDir();
    if (queueDir.empty()) {
        return false;
    }

    // SHCreateDirectoryExW handles nested creation (creates the parent
    // %LOCALAPPDATA%\go-mapi too if needed).
    // ERROR_ALREADY_EXISTS / ERROR_FILE_EXISTS are success cases.
    int rc = SHCreateDirectoryExW(nullptr, queueDir.c_str(), nullptr);
    if (rc != ERROR_SUCCESS && rc != ERROR_ALREADY_EXISTS && rc != ERROR_FILE_EXISTS) {
        return false;
    }

    std::wstring errorsDir = queueDir + L"\\errors";
    rc = SHCreateDirectoryExW(nullptr, errorsDir.c_str(), nullptr);
    if (rc != ERROR_SUCCESS && rc != ERROR_ALREADY_EXISTS && rc != ERROR_FILE_EXISTS) return false;
    std::wstring warningsDir = queueDir + L"\\warnings";
    rc = SHCreateDirectoryExW(nullptr, warningsDir.c_str(), nullptr);
    return rc == ERROR_SUCCESS || rc == ERROR_ALREADY_EXISTS || rc == ERROR_FILE_EXISTS;
}

bool FsUtils::WriteMissingAppWarning(AppPresenceStatus status) {
    if (status == AppPresenceStatus::Available || !EnsureOutputDirectory()) return false;
    const std::wstring path = GetBaseQueueDir() + L"\\warnings\\missing-wails-app.warning";
    const std::string content = std::string("go-mapi: Wails app unavailable (") +
        PresenceReason(status) + "). Start or install go-mapi.\n";
    // This is deliberately create-only: the stable name is the cross-process rate limiter.
    return WriteFileAtomically(path, content);
}

bool FsUtils::RemoveMissingAppWarning() {
    const std::wstring base = GetBaseQueueDir();
    if (base.empty()) return false;
    const std::wstring path = base + L"\\warnings\\missing-wails-app.warning";
    return DeleteFileW(path.c_str()) != FALSE || GetLastError() == ERROR_FILE_NOT_FOUND;
}

std::wstring FsUtils::GetComponentMismatchWarningPath() {
    const std::wstring base = GetBaseQueueDir();
    return base.empty() ? L"" : base + L"\\warnings\\component-version-mismatch-v1.json";
}

bool FsUtils::WriteComponentMismatchWarning(const std::string& interceptorVersion,
                                            const std::string& architecture,
                                            const std::string& minInclusive,
                                            const std::string& maxExclusive,
                                            const std::string& observedStatus,
                                            const std::string& observedVersion) {
    if (!EnsureOutputDirectory()) return false;
    std::ostringstream json;
    json << "{\"schema\":\"go-mapi-component-version-mismatch-v1\","
         << "\"interceptor\":{\"version\":\"" << interceptorVersion
         << "\",\"architecture\":\"" << architecture
         << "\",\"requires\":{\"component\":\"app\",\"minInclusive\":\""
         << minInclusive << "\"";
    if (!maxExclusive.empty()) json << ",\"maxExclusive\":\"" << maxExclusive << "\"";
    json << "}},\"app\":{\"observedStatus\":\"" << observedStatus << "\"";
    if (!observedVersion.empty()) json << ",\"observedVersion\":\"" << observedVersion << "\"";
    json << "},\"action\":\"update-app\",\"createdAt\":\"" << UtcNowIso8601() << "\"}";
    return WriteFileAtomicallyReplacing(GetComponentMismatchWarningPath(), json.str());
}

bool FsUtils::RemoveComponentMismatchWarning() {
    const std::wstring path = GetComponentMismatchWarningPath();
    if (path.empty()) return false;
    return DeleteFileW(path.c_str()) != FALSE || GetLastError() == ERROR_FILE_NOT_FOUND;
}

std::string FsUtils::GetRandomSuffix() {
    thread_local std::random_device rd;
    thread_local std::mt19937 gen(rd());
    std::uniform_int_distribution<> dis(0, 15);

    std::ostringstream oss;
    for (int i = 0; i < 6; ++i) {
        oss << std::hex << dis(gen);
    }
    return oss.str();
}

std::wstring FsUtils::GenerateUniqueStem() {
    // Get current time
    auto now = std::time(nullptr);
    struct tm tm_buf;
    localtime_s(&tm_buf, &now);

    std::ostringstream oss;
    oss << std::put_time(&tm_buf, "%Y%m%d_%H%M%S");
    std::string timestamp = oss.str();

    // Add random suffix
    std::string randomSuffix = GetRandomSuffix();
    std::string stem = "msg_" + timestamp + "_" + randomSuffix;

    // Convert to wide string (ASCII input, so length conversion is trivial).
    int size_needed = MultiByteToWideChar(CP_UTF8, 0, stem.c_str(), (int)stem.length(), NULL, 0);
    std::wstring wstem(size_needed, 0);
    MultiByteToWideChar(CP_UTF8, 0, stem.c_str(), (int)stem.length(), &wstem[0], size_needed);

    return wstem;
}

std::wstring FsUtils::GenerateUniqueFilename() {
    return GenerateUniqueStem() + L".json";
}

std::wstring FsUtils::GetAttachmentsDirForStem(const std::wstring& stem) {
    // Sibling of the JSON file: %LOCALAPPDATA%\go-mapi\queue\<stem>
    // (no trailing separator — callers append the basename themselves).
    std::wstring base = GetBaseQueueDir();
    if (base.empty()) return L"";
    return base + L"\\" + stem;
}

bool FsUtils::EnsureDirExists(const std::wstring& path) {
    if (path.empty()) return false;
    int rc = SHCreateDirectoryExW(nullptr, path.c_str(), nullptr);
    return rc == ERROR_SUCCESS || rc == ERROR_ALREADY_EXISTS || rc == ERROR_FILE_EXISTS;
}

// Helper: UTF-8 → UTF-16 for a source path argument.
static std::wstring Utf8ToWide(const std::string& s) {
    if (s.empty()) return L"";
    int n = MultiByteToWideChar(CP_UTF8, 0, s.c_str(), (int)s.length(), nullptr, 0);
    if (n <= 0) return L"";
    std::wstring out(n, 0);
    MultiByteToWideChar(CP_UTF8, 0, s.c_str(), (int)s.length(), &out[0], n);
    return out;
}

bool FsUtils::CopyFileToDir(const std::string& srcUtf8,
                            const std::wstring& destDir,
                            const std::string& destBasenameUtf8,
                            std::wstring& outNewPath,
                            uint32_t& outSize) {
    if (srcUtf8.empty() || destDir.empty() || destBasenameUtf8.empty()) {
        return false;
    }

    std::wstring srcWide = Utf8ToWide(srcUtf8);
    std::wstring destBasenameWide = Utf8ToWide(destBasenameUtf8);
    if (srcWide.empty() || destBasenameWide.empty()) {
        return false;
    }

    std::wstring destPath = destDir;
    if (destPath.back() != L'\\') destPath += L'\\';
    destPath += destBasenameWide;

    // bFailIfExists = TRUE: we never overwrite. The stem's timestamp+suffix
    // already makes the destination dir unique per message, so collisions
    // here mean something is wrong (caller should bail).
    if (!CopyFileW(srcWide.c_str(), destPath.c_str(), TRUE)) {
        return false;
    }

    // Read back the file size so the JSON's attach.size is populated accurately.
    WIN32_FILE_ATTRIBUTE_DATA attr{};
    if (!GetFileAttributesExW(destPath.c_str(), GetFileExInfoStandard, &attr)) {
        // Copy succeeded but we can't stat — treat as failure so the caller
        // rolls back; we'd rather write nothing than write a half-valid JSON.
        DeleteFileW(destPath.c_str());
        return false;
    }

    outNewPath = destPath;
    // nFileSizeHigh should be 0 for anything below ~4GB; clamp defensively.
    if (attr.nFileSizeHigh != 0) {
        outSize = 0xFFFFFFFFu;
    } else {
        outSize = static_cast<uint32_t>(attr.nFileSizeLow);
    }
    return true;
}

bool FsUtils::WriteErrorForStem(const std::wstring& stem,
                                const std::string& reason) {
    if (stem.empty()) return false;
    if (!EnsureOutputDirectory()) return false;
    std::wstring errPath = GetBaseQueueDir() + L"\\errors\\" + stem + L".error";
    return WriteFile(errPath, reason);
}

bool FsUtils::WriteFile(const std::wstring& filePath, const std::string& content) {
    HANDLE hFile = CreateFileW(
        filePath.c_str(),
        GENERIC_WRITE,
        0,
        nullptr,
        CREATE_NEW,
        FILE_ATTRIBUTE_NORMAL,
        nullptr
    );

    if (hFile == INVALID_HANDLE_VALUE) {
        return false;
    }

    DWORD bytesWritten;
    BOOL result = ::WriteFile(  // Use global namespace to call Windows API
        hFile,
        content.c_str(),
        (DWORD)content.length(),
        &bytesWritten,
        nullptr
    );

    CloseHandle(hFile);
    return result && bytesWritten == content.length();
}

bool FsUtils::WriteFileAtomically(const std::wstring& filePath,
                                  const std::string& content) {
    if (filePath.empty() || content.size() > MAXDWORD) return false;

    // The staging file must be a sibling of the final path: MoveFileExW is
    // atomic only when both names are on the same volume.
    std::wstring tempPath = filePath + L"." + GenerateUniqueStem() + L".tmp";
    HANDLE hFile = CreateFileW(
        tempPath.c_str(),
        GENERIC_WRITE,
        0,
        nullptr,
        CREATE_NEW,
        FILE_ATTRIBUTE_NORMAL,
        nullptr
    );
    if (hFile == INVALID_HANDLE_VALUE) return false;

    DWORD bytesWritten = 0;
    const BOOL wrote = atomicWriteFault.load() == AtomicWriteFault::Write
        ? FALSE
        : ::WriteFile(hFile, content.data(), static_cast<DWORD>(content.size()),
                      &bytesWritten, nullptr);
    const BOOL flushed = wrote && bytesWritten == static_cast<DWORD>(content.size()) &&
                         (atomicWriteFault.load() == AtomicWriteFault::Flush
                              ? FALSE
                              : FlushFileBuffers(hFile));
    const BOOL closed = CloseHandle(hFile);
    if (!flushed || !closed) {
        DeleteFileW(tempPath.c_str());
        return false;
    }

    // Do not replace an existing message. A unique stem should make that
    // impossible; preserving an existing final file is safer on collision.
    if (atomicWriteFault.load() == AtomicWriteFault::Rename ||
        !MoveFileExW(tempPath.c_str(), filePath.c_str(), MOVEFILE_WRITE_THROUGH)) {
        DeleteFileW(tempPath.c_str());
        return false;
    }
    return true;
}

bool FsUtils::RemoveAttachmentsDirForStem(const std::wstring& stem) {
    const std::wstring dir = GetAttachmentsDirForStem(stem);
    if (dir.empty()) return false;

    WIN32_FIND_DATAW entry{};
    HANDLE find = FindFirstFileW((dir + L"\\*").c_str(), &entry);
    if (find == INVALID_HANDLE_VALUE) {
        const DWORD error = GetLastError();
        if (error == ERROR_PATH_NOT_FOUND) {
            // The directory never existed (e.g. a message had no
            // attachments), which is already the desired postcondition.
            return true;
        }
        if (error == ERROR_FILE_NOT_FOUND) {
            // FindFirstFile reports FILE_NOT_FOUND for an empty directory;
            // remove that directory instead of silently leaving it behind.
            return RemoveDirectoryW(dir.c_str()) != FALSE;
        }
        return false;
    }

    bool removed = true;
    do {
        if (wcscmp(entry.cFileName, L".") == 0 || wcscmp(entry.cFileName, L"..") == 0) {
            continue;
        }
        const std::wstring child = dir + L"\\" + entry.cFileName;
        if (entry.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) {
            // Attachment copies are flat. Do not recursively remove an
            // unexpected directory; leave it in place and report failure.
            removed = false;
        } else if (!DeleteFileW(child.c_str())) {
            removed = false;
        }
    } while (FindNextFileW(find, &entry));
    FindClose(find);

    return removed && RemoveDirectoryW(dir.c_str());
}

} // namespace go_mapi
