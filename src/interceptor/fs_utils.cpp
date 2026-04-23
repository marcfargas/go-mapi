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

std::wstring FsUtils::GenerateUniqueFilename() {
    // Get current time
    auto now = std::time(nullptr);
    struct tm tm_buf;
    localtime_s(&tm_buf, &now);

    std::ostringstream oss;
    oss << std::put_time(&tm_buf, "%Y%m%d_%H%M%S");
    std::string timestamp = oss.str();

    // Add random suffix
    std::string randomSuffix = GetRandomSuffix();
    std::string filename = "msg_" + timestamp + "_" + randomSuffix + ".json";

    // Convert to wide string
    int size_needed = MultiByteToWideChar(CP_UTF8, 0, filename.c_str(), (int)filename.length(), NULL, 0);
    std::wstring wfilename(size_needed, 0);
    MultiByteToWideChar(CP_UTF8, 0, filename.c_str(), (int)filename.length(), &wfilename[0], size_needed);

    return wfilename;
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
