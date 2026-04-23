// TODO: cover GetQueueDirectory + EnsureOutputDirectory in a future C++ unit harness.

#include "fs_utils.h"
#include <shlobj.h>
#include <ctime>
#include <random>
#include <iomanip>
#include <sstream>

namespace go_mapi {

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
    return rc == ERROR_SUCCESS || rc == ERROR_ALREADY_EXISTS || rc == ERROR_FILE_EXISTS;
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

} // namespace go_mapi
