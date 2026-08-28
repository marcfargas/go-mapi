#include "test_utils.h"
#include "../fs_utils.h"
#include <iostream>
#include <fstream>
#include <sstream>
#include <filesystem>
#include <algorithm>
#include <iterator>

namespace fs = std::filesystem;

namespace mapi_test {

namespace {

std::string g_dllPath;

std::string WideToUtf8(const std::wstring& wide) {
    if (wide.empty()) return "";
    const int size = WideCharToMultiByte(CP_UTF8, 0, wide.c_str(), -1, nullptr, 0, nullptr, nullptr);
    if (size <= 1) return "";
    std::string utf8(size, '\0');
    WideCharToMultiByte(CP_UTF8, 0, wide.c_str(), -1, utf8.data(), size, nullptr, nullptr);
    utf8.resize(size - 1);
    return utf8;
}

std::set<std::string> ListFiles(const fs::path& directory, const std::string& extension) {
    std::set<std::string> files;
    std::error_code error;
    if (!fs::exists(directory, error)) return files;
    for (const auto& entry : fs::directory_iterator(directory, error)) {
        if (!error && entry.is_regular_file(error) && entry.path().extension() == extension) {
            files.insert(entry.path().string());
        }
    }
    return files;
}

}  // namespace

void TestUtilities::SetDllPath(const std::string& dllPath) {
    g_dllPath = dllPath;
}

HMODULE TestUtilities::LoadGoMapiDll() {
    if (g_dllPath.empty()) {
        std::cerr << "No go-mapi DLL path was configured" << std::endl;
        return nullptr;
    }
    HMODULE hDll = LoadLibraryA(g_dllPath.c_str());
    if (!hDll) {
        std::cerr << "Failed to load DLL: " << g_dllPath << std::endl;
    }
    return hDll;
}

TestUtilities::QueueSnapshot TestUtilities::SnapshotQueue(const std::string& queueDir) {
    QueueSnapshot snapshot;
    const fs::path queue(queueDir);
    snapshot.jsonFiles = ListFiles(queue, ".json");
    snapshot.errorFiles = ListFiles(queue / "errors", ".error");
    return snapshot;
}

std::string TestUtilities::FindNewJsonFile(const QueueSnapshot& snapshot,
                                           const std::string& queueDir) {
    const std::set<std::string> current = ListFiles(fs::path(queueDir), ".json");
    std::vector<std::string> newFiles;
    std::set_difference(current.begin(), current.end(), snapshot.jsonFiles.begin(), snapshot.jsonFiles.end(),
                        std::back_inserter(newFiles));
    if (newFiles.size() != 1) {
        std::cerr << "Expected exactly one new JSON file, found " << newFiles.size() << std::endl;
        return "";
    }
    std::cout << "Found new JSON file: " << fs::path(newFiles.front()).filename().string() << std::endl;
    return newFiles.front();
}

bool TestUtilities::ValidateJsonFile(const std::string& filePath) {
    try {
        std::ifstream file(filePath);
        if (!file.is_open()) {
            std::cerr << "Failed to open file: " << filePath << std::endl;
            return false;
        }

        std::stringstream buffer;
        buffer << file.rdbuf();
        std::string content = buffer.str();

        // Check for required fields
        std::vector<std::string> requiredFields = {
            "\"version\"",
            "\"timestamp\"",
            "\"subject\"",
            "\"body\"",
            "\"bodyFormat\"",
            "\"recipients\"",
            "\"attachments\"",
            "\"originApp\""
        };

        for (const auto& field : requiredFields) {
            if (content.find(field) == std::string::npos) {
                std::cerr << "Missing required field: " << field << std::endl;
                return false;
            }
        }

        // Check for valid JSON structure. Guard empty content before front/back.
        if (content.empty() || content.front() != '{' || content.back() != '}') {
            std::cerr << "Invalid JSON structure" << std::endl;
            return false;
        }

        std::cout << "JSON file valid: " << filePath << std::endl;
        return true;
    } catch (const std::exception& e) {
        std::cerr << "Error validating JSON: " << e.what() << std::endl;
        return false;
    }
}

void TestUtilities::CleanupTestArtifacts(const std::string& queueDir,
                                         const std::string& jsonFile,
                                         const QueueSnapshot& snapshot) {
    if (!jsonFile.empty() && snapshot.jsonFiles.count(jsonFile) == 0) {
        std::error_code error;
        const fs::path json(jsonFile);
        fs::remove(json, error);
        fs::remove_all(json.parent_path() / json.stem(), error);
    }

    const fs::path errors = fs::path(queueDir) / "errors";
    for (const auto& errorFile : ListFiles(errors, ".error")) {
        if (snapshot.errorFiles.count(errorFile) == 0) {
            std::error_code error;
            fs::remove(errorFile, error);
        }
    }
}

std::string TestUtilities::GetGoMapiTempDir() {
    return WideToUtf8(go_mapi::FsUtils::GetQueueDirectory());
}

void TestUtilities::PrintTestResult(const std::string& testName, bool passed) {
    if (passed) {
        std::cout << "\n✓ [PASS] " << testName << std::endl;
    } else {
        std::cerr << "\n✗ [FAIL] " << testName << std::endl;
    }
}

int TestUtilities::GetJsonFileCount(const std::string& tempDir) {
    return static_cast<int>(ListFiles(fs::path(tempDir), ".json").size());
}

std::string TestUtilities::ReadJsonContent(const std::string& filePath) {
    std::ifstream file(filePath, std::ios::binary);
    if (!file.is_open()) return "";
    std::stringstream buf;
    buf << file.rdbuf();
    return buf.str();
}

std::string TestUtilities::CreateAttachmentFixture(const std::wstring& fileName,
                                                   const std::string& contents) {
    wchar_t tempPath[MAX_PATH];
    if (GetTempPathW(MAX_PATH, tempPath) == 0) return "";
    const std::wstring root = std::wstring(tempPath) + L"go-mapi-test-harness";
    if (!CreateDirectoryW(root.c_str(), nullptr) && GetLastError() != ERROR_ALREADY_EXISTS) return "";
    // A process-specific directory prevents a stale fixture from one harness
    // process colliding with another while retaining the expected basename.
    const std::wstring directory = root + L"\\" + std::to_wstring(GetCurrentProcessId());
    if (!CreateDirectoryW(directory.c_str(), nullptr) && GetLastError() != ERROR_ALREADY_EXISTS) return "";
    const std::wstring path = directory + L"\\" + fileName;
    HANDLE file = CreateFileW(path.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE) return "";
    DWORD written = 0;
    const BOOL ok = WriteFile(file, contents.data(), static_cast<DWORD>(contents.size()), &written, nullptr);
    CloseHandle(file);
    if (!ok || written != contents.size()) {
        DeleteFileW(path.c_str());
        return "";
    }
    return WideToUtf8(path);
}

void TestUtilities::RemoveAttachmentFixture(const std::string& filePath) {
    if (filePath.empty()) return;
    const int size = MultiByteToWideChar(CP_UTF8, 0, filePath.c_str(), -1, nullptr, 0);
    if (size <= 1) return;
    std::wstring path(size, L'\0');
    MultiByteToWideChar(CP_UTF8, 0, filePath.c_str(), -1, path.data(), size);
    path.resize(size - 1);
    DeleteFileW(path.c_str());
}

}  // namespace mapi_test
