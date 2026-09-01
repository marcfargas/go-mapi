#include <windows.h>

#include <filesystem>
#include <fstream>
#include <iostream>
#include <string>

#include "../test_utils.h"

using namespace mapi_test;
namespace fs = std::filesystem;

namespace {

using MAPISendDocumentsFunc = ULONG (WINAPI *)(ULONG_PTR, LPSTR, LPSTR, LPSTR, ULONG);

bool CopiedFileEquals(const fs::path& path, const std::string& expected) {
    std::ifstream file(path, std::ios::binary);
    std::string actual((std::istreambuf_iterator<char>(file)), {});
    return actual == expected;
}

}  // namespace

int test_send_documents() {
    std::cout << "\nTest: Send Documents Attachment Continuity" << std::endl;
    HMODULE dll = TestUtilities::LoadGoMapiDll();
    if (!dll) return 1;
    const auto sendDocuments = reinterpret_cast<MAPISendDocumentsFunc>(
        GetProcAddress(dll, "MAPISendDocuments"));
    if (!sendDocuments) {
        FreeLibrary(dll);
        return 1;
    }

    const std::string queueDir = TestUtilities::GetGoMapiTempDir();
    const auto noPathSnapshot = TestUtilities::SnapshotQueue(queueDir);
    bool success = sendDocuments(0, nullptr, nullptr, nullptr, 0) == SUCCESS_SUCCESS &&
        TestUtilities::FindNewJsonFile(noPathSnapshot, queueDir).empty() &&
        TestUtilities::SnapshotQueue(queueDir).errorFiles == noPathSnapshot.errorFiles;

    const std::string first = TestUtilities::CreateAttachmentFixture(
        L"go-mapi-send-documents-first.txt", "first send-documents fixture\n");
    const std::string second = TestUtilities::CreateAttachmentFixture(
        L"go-mapi-send-documents-second.txt", "second send-documents fixture\n");
    if (first.empty() || second.empty()) success = false;

    std::string paths = first + "|" + second;
    char delimiter[] = "|";
    char names[] = "display-one.txt|display-two.txt";
    const auto snapshot = TestUtilities::SnapshotQueue(queueDir);
    if (success) success = sendDocuments(0, delimiter, paths.data(), names, 0) == SUCCESS_SUCCESS;
    const std::string jsonFile = TestUtilities::FindNewJsonFile(snapshot, queueDir);
    success = success && !jsonFile.empty() && TestUtilities::ValidateJsonFile(jsonFile);
    if (success) {
        const fs::path attachmentDir = fs::path(jsonFile).parent_path() / fs::path(jsonFile).stem();
        success = CopiedFileEquals(attachmentDir / "display-one.txt", "first send-documents fixture\n") &&
            CopiedFileEquals(attachmentDir / "display-two.txt", "second send-documents fixture\n");
        const std::string descriptor = TestUtilities::ReadJsonContent(jsonFile);
        success = success && descriptor.find("\"bodyFormat\":\"plain\"") != std::string::npos &&
            descriptor.find("\"filename\":\"display-one.txt\"") != std::string::npos &&
            descriptor.find("\"filename\":\"display-two.txt\"") != std::string::npos;
    }
    TestUtilities::CleanupTestArtifacts(queueDir, jsonFile, snapshot);
    TestUtilities::RemoveAttachmentFixture(first);
    TestUtilities::RemoveAttachmentFixture(second);

    const auto missingSnapshot = TestUtilities::SnapshotQueue(queueDir);
    char missing[] = "C:\\go-mapi-send-documents-missing\\missing.txt";
    char missingName[] = "missing.txt";
    success = success && sendDocuments(0, delimiter, missing, missingName, 0) != SUCCESS_SUCCESS &&
        TestUtilities::FindNewJsonFile(missingSnapshot, queueDir).empty();
    TestUtilities::CleanupTestArtifacts(queueDir, "", missingSnapshot);

    FreeLibrary(dll);
    return success ? 0 : 1;
}
