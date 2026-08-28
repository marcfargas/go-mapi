#include <windows.h>
#include <iostream>
#include <string>
#include <filesystem>
#include "../test_utils.h"

using namespace mapi_test;

// Test that when lpszFileName is NULL (common with "Send to → Mail recipient"),
// the DLL extracts the filename from lpszPathName.
int test_null_filename() {
    std::cout << "\nTest: Null Filename (extract from path)" << std::endl;

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

    char subject[] = "Test with null filename";
    char body[] = "Attachment has path but no filename";
    char toAddress[] = "test@example.com";
    char toName[] = "Test User";

    // Attachment with lpszPathName set but lpszFileName = NULL
    // This is what Windows "Send to → Mail recipient" does
    const std::string fixturePath = TestUtilities::CreateAttachmentFixture(
        L"PyG_BGBL_GLOBAL_SL.xlsx", "owned ASCII null-name fixture\n");
    if (fixturePath.empty()) {
        std::cerr << "Failed to create ANSI attachment fixture" << std::endl;
        FreeLibrary(hDll);
        return 1;
    }
    // MAPI's ABI declares this mutable even though the DLL treats it as input.
    std::string filePath = fixturePath;

    MapiFileDesc attachment = {};
    attachment.nPosition = static_cast<ULONG>(-1);
    attachment.lpszPathName = filePath.data();
    attachment.lpszFileName = nullptr;  // NULL — the bug case

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

    const auto ansiSnapshot = TestUtilities::SnapshotQueue(queueDir);
    ULONG result = MAPISendMail(0, 0, &message, 0, 0);
    std::cout << "MAPISendMail returned: " << result << std::endl;

    if (result != 0) {
        std::cerr << "MAPISendMail failed" << std::endl;
        TestUtilities::CleanupTestArtifacts(queueDir, "", ansiSnapshot);
        TestUtilities::RemoveAttachmentFixture(fixturePath);
        FreeLibrary(hDll);
        return 1;
    }

    // Read the JSON and verify the filename was extracted from the path
    const std::string ansiJsonFile = TestUtilities::FindNewJsonFile(ansiSnapshot, queueDir);
    std::string json = TestUtilities::ReadJsonContent(ansiJsonFile);
    if (json.empty() || !TestUtilities::ValidateJsonFile(ansiJsonFile)) {
        std::cerr << "No JSON file found" << std::endl;
        TestUtilities::CleanupTestArtifacts(queueDir, ansiJsonFile, ansiSnapshot);
        TestUtilities::RemoveAttachmentFixture(fixturePath);
        FreeLibrary(hDll);
        return 1;
    }

    bool hasFilename = json.find("\"filename\":\"PyG_BGBL_GLOBAL_SL.xlsx\"") != std::string::npos &&
                       json.find("PyG_BGBL_GLOBAL_SL.xlsx") != std::string::npos;

    if (hasFilename) {
        std::cout << "  Filename correctly extracted from path" << std::endl;
    } else {
        std::cerr << "  Filename NOT extracted from path!" << std::endl;
        auto pos = json.find("filename");
        if (pos != std::string::npos) {
            std::cerr << "  JSON filename area: " << json.substr(pos, 80) << std::endl;
        }
    }

    TestUtilities::CleanupTestArtifacts(queueDir, ansiJsonFile, ansiSnapshot);
    TestUtilities::RemoveAttachmentFixture(fixturePath);

    // Also test with MAPISendMailW (wide version), using an owned Unicode fixture.

    typedef ULONG (WINAPI *MAPISendMailWFunc)(
        LHANDLE, ULONG_PTR, void*, ULONG, ULONG
    );
    MAPISendMailWFunc MAPISendMailW = reinterpret_cast<MAPISendMailWFunc>(
        GetProcAddress(hDll, "MAPISendMailW")
    );

    bool hasFilenameW = false;
    if (!MAPISendMailW) {
        std::cerr << "Failed to get MAPISendMailW function" << std::endl;
    } else {
        wchar_t wSubject[] = L"Test wide null filename";
        wchar_t wBody[] = L"Wide attachment test";
        wchar_t wToAddr[] = L"test@example.com";
        wchar_t wToName[] = L"Test User";
        const std::string wideFixturePath = TestUtilities::CreateAttachmentFixture(
            L"Informe_año_2025.pdf", "owned Unicode null-name fixture\n");
        if (wideFixturePath.empty()) {
            std::cerr << "Failed to create wide attachment fixture" << std::endl;
            FreeLibrary(hDll);
            return 1;
        }
        const int widePathSize = MultiByteToWideChar(CP_UTF8, 0, wideFixturePath.c_str(), -1, nullptr, 0);
        std::wstring widePath(widePathSize, L'\0');
        MultiByteToWideChar(CP_UTF8, 0, wideFixturePath.c_str(), -1, widePath.data(), widePathSize);
        widePath.resize(widePathSize - 1);

        MapiRecipDescW recipW = {};
        recipW.ulRecipClass = MAPI_TO;
        recipW.lpszName = wToName;
        recipW.lpszAddress = wToAddr;

        MapiFileDescW fileW = {};
        fileW.nPosition = static_cast<ULONG>(-1);
        fileW.lpszPathName = widePath.data();
        fileW.lpszFileName = nullptr;  // NULL

        MapiMessageW msgW = {};
        msgW.lpszSubject = wSubject;
        msgW.lpszNoteText = wBody;
        msgW.nRecipCount = 1;
        msgW.lpRecips = &recipW;
        msgW.nFileCount = 1;
        msgW.lpFiles = &fileW;

        const auto wideSnapshot = TestUtilities::SnapshotQueue(queueDir);
        ULONG resultW = MAPISendMailW(0, 0, &msgW, 0, 0);
        std::cout << "MAPISendMailW returned: " << resultW << std::endl;

        const std::string wideJsonFile = TestUtilities::FindNewJsonFile(wideSnapshot, queueDir);
        std::string jsonW = TestUtilities::ReadJsonContent(wideJsonFile);
        // In UTF-8, ñ is \xC3\xB1, so "año" is "a\xC3\xB1o"
        hasFilenameW = !jsonW.empty() && TestUtilities::ValidateJsonFile(wideJsonFile) &&
                    jsonW.find("Informe_a") != std::string::npos
                    && jsonW.find("o_2025.pdf") != std::string::npos;

        if (hasFilenameW) {
            std::cout << "  Wide filename correctly extracted from path" << std::endl;
        } else {
            std::cerr << "  Wide filename NOT extracted!" << std::endl;
        }
        if (resultW != 0) {
            std::cerr << "MAPISendMailW failed" << std::endl;
            hasFilenameW = false;
        }
        TestUtilities::CleanupTestArtifacts(queueDir, wideJsonFile, wideSnapshot);
        TestUtilities::RemoveAttachmentFixture(wideFixturePath);
    }

    FreeLibrary(hDll);
    return (hasFilename && hasFilenameW) ? 0 : 1;
}
