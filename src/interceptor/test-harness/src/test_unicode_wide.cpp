#include <windows.h>
#include <iostream>
#include <string>
#include "../test_utils.h"
#include "../../mapi_types.h"

using namespace mapi_test;

typedef ULONG (WINAPI *MAPISendMailWFunc)(LHANDLE, ULONG_PTR, LPMapiMessageW, ULONG, ULONG);

namespace {
std::wstring Utf8ToWide(const std::string& text) {
    const int size = MultiByteToWideChar(CP_UTF8, 0, text.c_str(), -1, nullptr, 0);
    if (size <= 1) return L"";
    std::wstring result(size, L'\0');
    MultiByteToWideChar(CP_UTF8, 0, text.c_str(), -1, result.data(), size);
    result.resize(size - 1);
    return result;
}
}  // namespace

int test_unicode_wide() {
    std::cout << "\nTest: MAPISendMailW (Wide/Unicode)" << std::endl;
    HMODULE hDll = TestUtilities::LoadGoMapiDll();
    if (!hDll) return 1;
    const auto MAPISendMailW = reinterpret_cast<MAPISendMailWFunc>(GetProcAddress(hDll, "MAPISendMailW"));
    if (!MAPISendMailW) {
        std::cerr << "Failed to get MAPISendMailW function" << std::endl;
        FreeLibrary(hDll);
        return 1;
    }

    const std::string fixturePath = TestUtilities::CreateAttachmentFixture(
        L"informe_año_2026.pdf", "owned wide attachment fixture\n");
    std::wstring attachPath = Utf8ToWide(fixturePath);
    if (fixturePath.empty() || attachPath.empty()) {
        std::cerr << "Failed to create Unicode attachment fixture" << std::endl;
        TestUtilities::RemoveAttachmentFixture(fixturePath);
        FreeLibrary(hDll);
        return 1;
    }

    wchar_t subject[] = L"Informe económico — año 2026";
    wchar_t body[] = L"Estimado señor Müller,\n\nAdjunto el informe.\n\nSaludos cordiales.";
    wchar_t toName[] = L"René Müller";
    wchar_t toAddress[] = L"SMTP:rene.mueller@example.com";
    wchar_t ccName[] = L"Åke Ström";
    wchar_t ccAddress[] = L"SMTP:ake.strom@example.com";
    wchar_t attachName[] = L"informe_año_2026.pdf";
    MapiRecipDescW recipients[2] = {};
    recipients[0].ulRecipClass = MAPI_TO;
    recipients[0].lpszName = toName;
    recipients[0].lpszAddress = toAddress;
    recipients[1].ulRecipClass = MAPI_CC;
    recipients[1].lpszName = ccName;
    recipients[1].lpszAddress = ccAddress;
    MapiFileDescW attachment = {};
    attachment.lpszPathName = attachPath.data();
    attachment.lpszFileName = attachName;
    MapiMessageW message = {};
    message.lpszSubject = subject;
    message.lpszNoteText = body;
    message.nRecipCount = 2;
    message.lpRecips = recipients;
    message.nFileCount = 1;
    message.lpFiles = &attachment;

    const std::string queueDir = TestUtilities::GetGoMapiTempDir();
    const auto snapshot = TestUtilities::SnapshotQueue(queueDir);
    const ULONG result = MAPISendMailW(0, 0, &message, 0, 0);
    std::cout << "MAPISendMailW returned: " << result << std::endl;
    const std::string jsonFile = TestUtilities::FindNewJsonFile(snapshot, queueDir);
    bool success = result == 0 && !jsonFile.empty() && TestUtilities::ValidateJsonFile(jsonFile);
    const std::string json = TestUtilities::ReadJsonContent(jsonFile);
    if (json.empty()) {
        std::cerr << "JSON output was empty" << std::endl;
        success = false;
    } else if (json.find("Informe") == std::string::npos ||
               json.find("Ren") == std::string::npos ||
               json.find("ller") == std::string::npos) {
        std::cerr << "Wide text was missing from JSON output" << std::endl;
        success = false;
    }
    TestUtilities::CleanupTestArtifacts(queueDir, jsonFile, snapshot);
    TestUtilities::RemoveAttachmentFixture(fixturePath);
    FreeLibrary(hDll);
    return success ? 0 : 1;
}
