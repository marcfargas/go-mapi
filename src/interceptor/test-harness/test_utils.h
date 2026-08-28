#pragma once

#include <windows.h>
#include <set>
#include <string>
#include <vector>
#include "../mapi_types.h"  // For LHANDLE and other MAPI types

namespace mapi_test {

// Test utilities for loading and testing the go-mapi DLL

// Function pointer type for MAPISendMail
typedef ULONG (WINAPI *MAPISendMailFunc)(
    LHANDLE lhSession,
    ULONG_PTR ulUIParam,
    void* lpMessage,
    ULONG flFlags,
    ULONG ulReserved
);

class TestUtilities {
public:
    struct QueueSnapshot {
        std::set<std::string> jsonFiles;
        std::set<std::string> errorFiles;
    };

    // The executable receives the exact DLL target from CTest.  Tests must
    // load only this path, never whichever go-mapi.dll happens to be on PATH.
    static void SetDllPath(const std::string& dllPath);
    static HMODULE LoadGoMapiDll();

    // Snapshot the production queue before one test invocation.  This lets
    // tests inspect and remove only their own output, preserving real queue
    // entries that existed before the harness started.
    static QueueSnapshot SnapshotQueue(const std::string& queueDir);
    static std::string FindNewJsonFile(const QueueSnapshot& snapshot,
                                       const std::string& queueDir);
    static void CleanupTestArtifacts(const std::string& queueDir,
                                     const std::string& jsonFile,
                                     const QueueSnapshot& snapshot);

    // Parse and validate a JSON file
    static bool ValidateJsonFile(const std::string& filePath);

    // Get the production queue directory (%LOCALAPPDATA%\go-mapi\queue).
    static std::string GetGoMapiTempDir();

    // Print test result
    static void PrintTestResult(const std::string& testName, bool passed);

    // Get count of JSON files in directory
    static int GetJsonFileCount(const std::string& tempDir);

    // Read JSON content. Returns an empty string for a missing or empty file.
    static std::string ReadJsonContent(const std::string& filePath);

    // Create and remove a harness-owned attachment fixture. The path is UTF-8
    // so it can be assigned directly to MapiFileDescA.
    static std::string CreateAttachmentFixture(const std::wstring& fileName,
                                               const std::string& contents);
    static void RemoveAttachmentFixture(const std::string& filePath);
};

}  // namespace mapi_test
