#include <iostream>
#include <filesystem>
#include <string>
#include <vector>
#include <tlhelp32.h>
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

// Native integration probe: report real process identities around an installed
// DLL call. The caller supplies the service gate state and checks the observed
// PID/session/path/creation identity; this probe never claims a launch on its
// own. Ordinary CTest runs continue to use their build-tree DLL and cleanup.
static void printAppProcesses(const char* phase) {
    HANDLE snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snapshot == INVALID_HANDLE_VALUE) return;
    PROCESSENTRY32W entry{};
    entry.dwSize = sizeof(entry);
    for (BOOL found = Process32FirstW(snapshot, &entry); found; found = Process32NextW(snapshot, &entry)) {
        if (_wcsicmp(entry.szExeFile, L"go-mapi.exe") != 0) continue;
        HANDLE process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, entry.th32ProcessID);
        if (!process) continue;
        wchar_t image[32768]{};
        DWORD imageLength = 32768;
        FILETIME created{}, exited{}, kernel{}, user{};
        DWORD session = 0;
        if (QueryFullProcessImageNameW(process, 0, image, &imageLength) &&
            GetProcessTimes(process, &created, &exited, &kernel, &user) &&
            ProcessIdToSessionId(entry.th32ProcessID, &session)) {
            const ULONGLONG creation = (static_cast<ULONGLONG>(created.dwHighDateTime) << 32) | created.dwLowDateTime;
            std::cout << "APP_PROCESS phase=" << phase << " pid=" << entry.th32ProcessID
                      << " session=" << session << " created=" << creation
                      << " image=" << std::filesystem::path(image).u8string() << std::endl;
        }
        CloseHandle(process);
    }
    CloseHandle(snapshot);
}

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

    std::string selectedCase;
    const bool activationProbe = argc == 4 && std::string(argv[2]) == "--activation-probe";
    if (argc == 4 && (std::string(argv[2]) == "--case" || activationProbe)) selectedCase = argv[3];
    if (argc > 2 && selectedCase.empty()) {
        std::cerr << "Usage: go-mapi-test-harness.exe [dll-path] [--case case-name|--activation-probe case-name]" << std::endl;
        return 2;
    }
    if (activationProbe) {
        if (selectedCase != "Simple Send" && selectedCase != "Unicode (Wide/MAPISendMailW)" &&
            selectedCase != "Send Documents Attachment Continuity") {
            std::cerr << "Activation probe requires one publishing MAPI entrypoint" << std::endl;
            return 2;
        }
        SetEnvironmentVariableA("GO_MAPI_TEST_RETAIN_OUTPUT", "1");
        printAppProcesses("before");
    }

    bool selectedCaseFound = selectedCase.empty();

    for (const auto& test : tests) {
        if (!selectedCase.empty() && test.first != selectedCase) continue;
        selectedCaseFound = true;
        int result = test.second();
        if (activationProbe) printAppProcesses("after");
        if (result == 0) {
            testsPassed++;
            TestUtilities::PrintTestResult(test.first, true);
        } else {
            testsFailed++;
            TestUtilities::PrintTestResult(test.first, false);
        }
    }

    if (!selectedCaseFound) {
        std::cerr << "Unknown test case: " << selectedCase << std::endl;
        return 2;
    }

    std::cout << std::endl;
    std::cout << "=================================" << std::endl;
    std::cout << "Results: " << testsPassed << " passed, " << testsFailed << " failed" << std::endl;
    std::cout << "=================================" << std::endl;

    return (testsFailed > 0) ? 1 : 0;
}
