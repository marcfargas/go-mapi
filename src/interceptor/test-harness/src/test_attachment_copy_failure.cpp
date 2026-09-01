#include <windows.h>

#include <filesystem>
#include <iostream>
#include <set>
#include <string>

#include "../test_utils.h"

using namespace mapi_test;
namespace fs = std::filesystem;

namespace {

std::set<fs::path> AttachmentDirectories(const fs::path& queue) {
    std::set<fs::path> result;
    std::error_code error;
    for (const auto& entry : fs::directory_iterator(queue, error)) {
        if (!error && entry.is_directory(error) && entry.path().filename() != "errors") {
            result.insert(entry.path());
        }
    }
    return result;
}

}  // namespace

// A failed copy must be all-or-nothing: MAPISendMail returns an error, no
// queue JSON appears, and its per-message staging directory is removed.
int test_attachment_copy_failure() {
    std::cout << "\nTest: Attachment Copy Failure Cleanup" << std::endl;
    HMODULE dll = TestUtilities::LoadGoMapiDll();
    if (!dll) return 1;
    MAPISendMailFunc sendMail = reinterpret_cast<MAPISendMailFunc>(
        GetProcAddress(dll, "MAPISendMail"));
    if (!sendMail) {
        FreeLibrary(dll);
        return 1;
    }

    const std::string queueDir = TestUtilities::GetGoMapiTempDir();
    const auto queueSnapshot = TestUtilities::SnapshotQueue(queueDir);
    const auto attachmentSnapshot = AttachmentDirectories(fs::path(queueDir));

    char subject[] = "copy failure must not publish";
    char body[] = "missing source fixture";
    char recipientAddress[] = "test@example.com";
    char missingPath[] = "C:\\go-mapi-harness-does-not-exist\\missing.txt";
    char filename[] = "missing.txt";
    MapiRecipDesc recipient{};
    recipient.ulRecipClass = MAPI_TO;
    recipient.lpszAddress = recipientAddress;
    MapiFileDesc attachment{};
    attachment.nPosition = static_cast<ULONG>(-1);
    attachment.lpszPathName = missingPath;
    attachment.lpszFileName = filename;
    MapiMessage message{};
    message.lpszSubject = subject;
    message.lpszNoteText = body;
    message.nRecipCount = 1;
    message.lpRecips = &recipient;
    message.nFileCount = 1;
    message.lpFiles = &attachment;

    const ULONG result = sendMail(0, 0, &message, 0, 0);
    const auto attachmentAfter = AttachmentDirectories(fs::path(queueDir));
    bool clean = result != SUCCESS_SUCCESS &&
                 TestUtilities::FindNewJsonFile(queueSnapshot, queueDir).empty() &&
                 attachmentAfter == attachmentSnapshot;
    if (!clean) {
        std::cerr << "copy failure exposed a queue artifact" << std::endl;
    }

    TestUtilities::CleanupTestArtifacts(queueDir, "", queueSnapshot);
    FreeLibrary(dll);
    return clean ? 0 : 1;
}
