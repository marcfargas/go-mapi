#pragma once

#include <windows.h>
#include <string>
#include <vector>
#include "mapi_types.h"

namespace mapi_test {

// Test utilities for loading and testing the go-mapi DLL

typedef unsigned long (__stdcall *MAPISendMailFunc)(
    LHANDLE lhSession,
    ULONG_PTR ulUIParam,
    void* lpMessage,
    unsigned long flFlags,
    unsigned long ulReserved
);

class TestUtilities {
public:
    // Load the go-mapi.dll and get the function pointer
    static MAPISendMailFunc LoadMAPISendMail(const std::string& dllPath);

    // Verify a JSON file was created in the temp directory
    static bool VerifyJsonFileCreated(const std::string& tempDir);

    // Parse and validate a JSON file
    static bool ValidateJsonFile(const std::string& filePath);

    // Clean up test files
    static void CleanupTestFiles(const std::string& tempDir);

    // Get the go-mapi temp directory
    static std::string GetGoMapiTempDir();

    // Print test result
    static void PrintTestResult(const std::string& testName, bool passed);

    // Get count of JSON files in directory
    static int GetJsonFileCount(const std::string& tempDir);
};

}  // namespace mapi_test
