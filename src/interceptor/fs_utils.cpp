#include "fs_utils.h"
#include <shlwapi.h>
#include <ctime>
#include <random>
#include <iomanip>
#include <sstream>

#pragma comment(lib, "shlwapi.lib")

namespace go_mapi {

std::wstring FsUtils::GetBaseTempDir() {
    wchar_t tempPath[MAX_PATH];
    if (GetTempPathW(MAX_PATH, tempPath) == 0) {
        return L"";
    }
    std::wstring result(tempPath);
    if (result.back() != L'\\') {
        result += L'\\';
    }
    result += L"go-mapi";
    return result;
}

std::wstring FsUtils::GetTempPath() {
    std::wstring basePath = GetBaseTempDir();
    if (!basePath.empty() && basePath.back() != L'\\') {
        basePath += L'\\';
    }
    return basePath;
}

bool FsUtils::EnsureOutputDirectory() {
    std::wstring dirPath = GetBaseTempDir();
    if (dirPath.empty()) {
        return false;
    }

    // Try to create the directory (CreateDirectoryW doesn't fail if it exists)
    BOOL result = CreateDirectoryW(dirPath.c_str(), nullptr);
    // Either it was created successfully, or it already exists
    return result || GetLastError() == ERROR_ALREADY_EXISTS;
}

std::string FsUtils::GetRandomSuffix() {
    static std::random_device rd;
    static std::mt19937 gen(rd());
    static std::uniform_int_distribution<> dis(0, 15);

    std::ostringstream oss;
    for (int i = 0; i < 6; ++i) {
        oss << std::hex << dis(gen);
    }
    return oss.str();
}

std::wstring FsUtils::GenerateUniqueFilename() {
    // Get current time
    auto now = std::time(nullptr);
    auto tm = std::localtime(&now);

    std::ostringstream oss;
    oss << std::put_time(tm, "%Y%m%d_%H%M%S");
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
    BOOL result = ::WriteFile(
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
