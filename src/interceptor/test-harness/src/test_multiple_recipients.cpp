#include <windows.h>
#include <iostream>
#include <string>
#include <filesystem>
#include "../test_utils.h"

using namespace mapi_test;

int test_multiple_recipients() {
    std::cout << "\nTest: Multiple Recipients (TO, CC, BCC)" << std::endl;

    // Load the DLL
    HMODULE hDll = TestUtilities::LoadGoMapiDll();
    if (!hDll) {
        std::cerr << "Failed to load go-mapi.dll" << std::endl;
        return 1;
    }

    MAPISendMailFunc MAPISendMail = reinterpret_cast<MAPISendMailFunc>(
        GetProcAddress(hDll, "MAPISendMail")
    );

    if (!MAPISendMail) {
        std::cerr << "Failed to get MAPISendMail function" << std::endl;
        FreeLibrary(hDll);
        return 1;
    }

    // Create message with multiple recipients
    char subject[] = "Test Email - Multiple Recipients";
    char body[] = "This email goes to multiple recipients.";

    // TO recipient
    char toName[] = "John Doe";
    char toAddress[] = "john@example.com";

    // CC recipient
    char ccName[] = "Jane Smith";
    char ccAddress[] = "jane@example.com";

    // BCC recipient
    char bccName[] = "Admin";
    char bccAddress[] = "admin@example.com";

    MapiRecipDesc recipients[3] = {};

    recipients[0].ulRecipClass = MAPI_TO;
    recipients[0].lpszName = toName;
    recipients[0].lpszAddress = toAddress;

    recipients[1].ulRecipClass = MAPI_CC;
    recipients[1].lpszName = ccName;
    recipients[1].lpszAddress = ccAddress;

    recipients[2].ulRecipClass = MAPI_BCC;
    recipients[2].lpszName = bccName;
    recipients[2].lpszAddress = bccAddress;

    MapiMessage message = {};
    message.lpszSubject = subject;
    message.lpszNoteText = body;
    message.nRecipCount = 3;
    message.lpRecips = recipients;
    message.nFileCount = 0;
    message.lpFiles = nullptr;

    const std::string queueDir = TestUtilities::GetGoMapiTempDir();
    const auto snapshot = TestUtilities::SnapshotQueue(queueDir);

    // Send the message
    ULONG result = MAPISendMail(0, 0, &message, 0, 0);

    std::cout << "MAPISendMail returned: " << result << std::endl;

    if (result != 0) {
        std::cerr << "MAPISendMail failed" << std::endl;
        TestUtilities::CleanupTestArtifacts(queueDir, "", snapshot);
        FreeLibrary(hDll);
        return 1;
    }
    const std::string jsonFile = TestUtilities::FindNewJsonFile(snapshot, queueDir);
    const bool success = !jsonFile.empty() && TestUtilities::ValidateJsonFile(jsonFile);
    TestUtilities::CleanupTestArtifacts(queueDir, jsonFile, snapshot);

    FreeLibrary(hDll);
    return success ? 0 : 1;
}
