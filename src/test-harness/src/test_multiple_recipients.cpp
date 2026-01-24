#include <windows.h>
#include <iostream>
#include <string>
#include <filesystem>
#include "../test_utils.h"

// Define MAPI structures (simplified versions)
struct MapiRecipDesc {
    unsigned long ulReserved;
    unsigned long ulRecipClass;
    char* lpszName;
    char* lpszAddress;
    unsigned long ulEIDSize;
    void* lpEntryID;
};

struct MapiFileDesc {
    unsigned long ulReserved;
    unsigned long flFlags;
    unsigned long nPosition;
    char* lpszPathName;
    char* lpszFileName;
    void* lpFileType;
};

struct MapiMessage {
    unsigned long ulReserved;
    char* lpszSubject;
    char* lpszNoteText;
    char* lpszMessageType;
    char* lpszDateReceived;
    char* lpszConversationID;
    unsigned long flFlags;
    MapiRecipDesc* lpOriginator;
    unsigned long nRecipCount;
    MapiRecipDesc* lpRecips;
    unsigned long nFileCount;
    MapiFileDesc* lpFiles;
};

using namespace mapi_test;

int test_multiple_recipients() {
    std::cout << "\nTest: Multiple Recipients (TO, CC, BCC)" << std::endl;

    // Load the DLL
    HMODULE hDll = LoadLibraryA("go-mapi.dll");
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

    recipients[0].ulRecipClass = 1;  // MAPI_TO
    recipients[0].lpszName = toName;
    recipients[0].lpszAddress = toAddress;

    recipients[1].ulRecipClass = 2;  // MAPI_CC
    recipients[1].lpszName = ccName;
    recipients[1].lpszAddress = ccAddress;

    recipients[2].ulRecipClass = 3;  // MAPI_BCC
    recipients[2].lpszName = bccName;
    recipients[2].lpszAddress = bccAddress;

    MapiMessage message = {};
    message.lpszSubject = subject;
    message.lpszNoteText = body;
    message.nRecipCount = 3;
    message.lpRecips = recipients;
    message.nFileCount = 0;
    message.lpFiles = nullptr;

    // Send the message
    unsigned long result = MAPISendMail(0, 0, &message, 0, 0);

    std::cout << "MAPISendMail returned: " << result << std::endl;

    // Verify JSON file was created
    std::string tempDir = TestUtilities::GetGoMapiTempDir();
    bool success = TestUtilities::VerifyJsonFileCreated(tempDir);

    if (success) {
        // Find and validate the JSON file
        for (const auto& entry : std::filesystem::directory_iterator(tempDir)) {
            if (entry.path().extension() == ".json") {
                success = TestUtilities::ValidateJsonFile(entry.path().string());
                break;
            }
        }
    }

    FreeLibrary(hDll);
    return success ? 0 : 1;
}
