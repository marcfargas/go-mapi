#include <windows.h>
#include <iostream>
#include <string>
#include <filesystem>
#include "../test_utils.h"

using namespace mapi_test;

// Test that ANSI codepage strings (Windows-1252) are properly converted to UTF-8.
// Windows "Send to → Mail recipient" calls MAPISendMail (ANSI) with strings in the
// system codepage, NOT UTF-8. The DLL must convert them.
int test_ansi_encoding() {
    std::cout << "\nTest: ANSI Codepage Encoding" << std::endl;

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

    const std::string queueDir = TestUtilities::GetGoMapiTempDir();
    const auto snapshot = TestUtilities::SnapshotQueue(queueDir);

    // Build a subject with ANSI codepage characters (Windows-1252).
    // "Enviando por correo electrónico:" — the ó is 0xF3 in Windows-1252.
    // We build the ANSI string by converting from a known UTF-16 source.
    const wchar_t* wideSubject = L"Enviando por correo electr\u00f3nico: PyG_BGBL_GLOBAL_SL";
    char ansiSubject[256] = {};
    WideCharToMultiByte(CP_ACP, 0, wideSubject, -1, ansiSubject, sizeof(ansiSubject), NULL, NULL);

    char body[] = "Test body";
    char toAddress[] = "test@example.com";
    char toName[] = "Test User";

    MapiRecipDesc recipient = {};
    recipient.ulRecipClass = MAPI_TO;
    recipient.lpszName = toName;
    recipient.lpszAddress = toAddress;

    MapiMessage message = {};
    message.lpszSubject = ansiSubject;
    message.lpszNoteText = body;
    message.nRecipCount = 1;
    message.lpRecips = &recipient;
    message.nFileCount = 0;
    message.lpFiles = nullptr;

    ULONG result = MAPISendMail(0, 0, &message, 0, 0);
    std::cout << "MAPISendMail returned: " << result << std::endl;

    if (result != 0) {
        std::cerr << "MAPISendMail failed" << std::endl;
        FreeLibrary(hDll);
        return 1;
    }

    // Read the JSON and verify the subject is valid UTF-8 with ó (not Ã³ or other mojibake)
    const std::string jsonFile = TestUtilities::FindNewJsonFile(snapshot, queueDir);
    std::string json = TestUtilities::ReadJsonContent(jsonFile);
    if (json.empty()) {
        std::cerr << "No JSON file found" << std::endl;
        TestUtilities::CleanupTestArtifacts(queueDir, jsonFile, snapshot);
        FreeLibrary(hDll);
        return 1;
    }

    // In UTF-8, ó is \xC3\xB3. The subject must contain "electrónico" in UTF-8.
    std::string expected_utf8 = "electr\xc3\xb3nico";
    bool found = json.find(expected_utf8) != std::string::npos;

    if (found) {
        std::cout << "  ANSI subject correctly converted to UTF-8" << std::endl;
    } else {
        std::cerr << "  ANSI subject NOT correctly converted! Mojibake detected." << std::endl;
        // Show what we got
        auto pos = json.find("subject");
        if (pos != std::string::npos) {
            std::cerr << "  JSON subject area: " << json.substr(pos, 80) << std::endl;
        }
    }

    TestUtilities::CleanupTestArtifacts(queueDir, jsonFile, snapshot);
    FreeLibrary(hDll);
    return found ? 0 : 1;
}
