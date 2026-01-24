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

int test_unicode() {
    std::cout << "\nTest: Unicode Content" << std::endl;

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

    // Create message with unicode content
    // Using UTF-8 encoded strings (note: real MAPI would need proper encoding)
    char subject[] = "Test Email - Unicode \xc3\xa9\xc3\xa0\xc3\xbc";  // éàü in UTF-8
    char body[] = "Body with special chars: \xc4\x85\xc4\x99\xc5\x9b";  // ąęś in UTF-8
    char toAddress[] = "test@example.com";
    char toName[] = "User \xc3\x85ke";  // Åke in UTF-8

    MapiRecipDesc recipient = {};
    recipient.ulRecipClass = 1;  // MAPI_TO
    recipient.lpszName = toName;
    recipient.lpszAddress = toAddress;

    MapiMessage message = {};
    message.lpszSubject = subject;
    message.lpszNoteText = body;
    message.nRecipCount = 1;
    message.lpRecips = &recipient;
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
