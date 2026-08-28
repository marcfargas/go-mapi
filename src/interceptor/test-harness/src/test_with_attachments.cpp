#include <windows.h>
#include <iostream>
#include <string>
#include <filesystem>
#include "../test_utils.h"

using namespace mapi_test;

int test_with_attachments() {
    std::cout << "\nTest: With Attachments" << std::endl;

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

    // Create message with attachments
    char subject[] = "Test Email - With Attachments";
    char body[] = "This email has file attachments.";
    char toAddress[] = "test@example.com";
    char toName[] = "Test User";

    // Create an owned fixture; never rely on a machine-specific C:\\test.txt.
    const std::string fixturePath = TestUtilities::CreateAttachmentFixture(
        L"go-mapi-harness-ascii.txt", "harness attachment\n");
    if (fixturePath.empty()) {
        std::cerr << "Failed to create attachment fixture" << std::endl;
        FreeLibrary(hDll);
        return 1;
    }
    // MAPI's ABI declares this mutable even though the DLL treats it as input.
    std::string filePath = fixturePath;
    char fileName[] = "test.txt";

    MapiFileDesc attachment = {};
    attachment.nPosition = 0;
    attachment.lpszPathName = filePath.data();
    attachment.lpszFileName = fileName;

    MapiRecipDesc recipient = {};
    recipient.ulRecipClass = MAPI_TO;
    recipient.lpszName = toName;
    recipient.lpszAddress = toAddress;

    MapiMessage message = {};
    message.lpszSubject = subject;
    message.lpszNoteText = body;
    message.nRecipCount = 1;
    message.lpRecips = &recipient;
    message.nFileCount = 1;
    message.lpFiles = &attachment;

    const std::string queueDir = TestUtilities::GetGoMapiTempDir();
    const auto snapshot = TestUtilities::SnapshotQueue(queueDir);

    // Send the message
    ULONG result = MAPISendMail(0, 0, &message, 0, 0);

    std::cout << "MAPISendMail returned: " << result << std::endl;

    bool success = result == 0;
    if (!success) std::cerr << "MAPISendMail failed" << std::endl;
    const std::string jsonFile = TestUtilities::FindNewJsonFile(snapshot, queueDir);
    success = success && !jsonFile.empty() && TestUtilities::ValidateJsonFile(jsonFile);
    TestUtilities::CleanupTestArtifacts(queueDir, jsonFile, snapshot);
    TestUtilities::RemoveAttachmentFixture(fixturePath);

    FreeLibrary(hDll);
    return success ? 0 : 1;
}
