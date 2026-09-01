#include <iostream>
#include <filesystem>
#include <string>
#include <vector>
#include "../test_utils.h"

// Forward declarations of test functions
extern int test_simple_send();
extern int test_with_attachments();
extern int test_unicode();
extern int test_multiple_recipients();
extern int test_unicode_wide();
extern int test_ansi_encoding();
extern int test_null_filename();
extern int test_attachment_copy_failure();
extern int test_send_documents();

using namespace mapi_test;

int main(int argc, char* argv[]) {
    std::cout << "=================================" << std::endl;
    std::cout << "  go-mapi MAPI Test Harness" << std::endl;
    std::cout << "=================================" << std::endl;
    std::cout << std::endl;

    // Determine DLL path
    char executablePath[MAX_PATH] = {};
    const DWORD executableLength = GetModuleFileNameA(nullptr, executablePath, MAX_PATH);
    if (executableLength == 0 || executableLength == MAX_PATH) {
        std::cerr << "Failed to determine test harness executable path" << std::endl;
        return 1;
    }
    // Default to the DLL adjacent to the harness executable. CTest overrides
    // this with the exact go-mapi target path below.
    std::string dllPath = (std::filesystem::path(executablePath).parent_path() / "go-mapi.dll").string();
    if (argc > 1) {
        dllPath = argv[1];
    }
    TestUtilities::SetDllPath(dllPath);

    std::cout << "Using DLL: " << dllPath << std::endl;
    std::cout << std::endl;

    // Get the temp directory
    std::string tempDir = TestUtilities::GetGoMapiTempDir();
    if (tempDir.empty()) {
        std::cerr << "Failed to get temp directory" << std::endl;
        return 1;
    }

    std::cout << "Monitoring: " << tempDir << std::endl;
    std::cout << std::endl;

    // Run tests
    int testsPassed = 0;
    int testsFailed = 0;

    std::vector<std::pair<std::string, int(*)()>> tests = {
        { "Simple Send", test_simple_send },
        { "With Attachments", test_with_attachments },
        { "Unicode (ANSI)", test_unicode },
        { "Unicode (Wide/MAPISendMailW)", test_unicode_wide },
        { "Multiple Recipients", test_multiple_recipients },
        { "ANSI Codepage Encoding", test_ansi_encoding },
        { "Null Filename (path fallback)", test_null_filename },
        { "Attachment Copy Failure Cleanup", test_attachment_copy_failure },
        { "Send Documents Attachment Continuity", test_send_documents },
    };

    for (const auto& test : tests) {
        int result = test.second();
        if (result == 0) {
            testsPassed++;
            TestUtilities::PrintTestResult(test.first, true);
        } else {
            testsFailed++;
            TestUtilities::PrintTestResult(test.first, false);
        }
    }

    std::cout << std::endl;
    std::cout << "=================================" << std::endl;
    std::cout << "Results: " << testsPassed << " passed, " << testsFailed << " failed" << std::endl;
    std::cout << "=================================" << std::endl;

    return (testsFailed > 0) ? 1 : 0;
}
