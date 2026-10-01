#include <windows.h>
#include <filesystem>
#include <iostream>
#include <string>
#include "../../mapi_types.h"

using SendMail = ULONG (WINAPI *)(LHANDLE, ULONG_PTR, LPMapiMessage, ULONG, ULONG);
constexpr ULONG kComposeDialog = 0x00000008; // MAPI_DIALOG, test-only safety flag.

int main(int argc, char* argv[]) {
    if (argc != 3) {
        std::cerr << "Usage: installed_mapi_probe <owned-attachment-path> <unique-subject-marker>\n";
        return 2;
    }
    const std::filesystem::path attachmentPath(argv[1]);
    if (!std::filesystem::is_regular_file(attachmentPath) || argv[2][0] == '\0') {
        std::cerr << "Attachment must exist and subject marker must be nonempty\n";
        return 2;
    }

    char systemDir[MAX_PATH] = {};
    const UINT length = GetSystemDirectoryA(systemDir, MAX_PATH);
    if (length == 0 || length >= MAX_PATH) {
        std::cerr << "Cannot locate Windows system directory\n";
        return 2;
    }
    const std::string dllPath = std::string(systemDir) + "\\mapi32.dll";
    HMODULE dll = LoadLibraryA(dllPath.c_str());
    if (!dll) {
        std::cerr << "Cannot load system mapi32.dll\n";
        return 2;
    }
    auto sendMail = reinterpret_cast<SendMail>(GetProcAddress(dll, "MAPISendMail"));
    if (!sendMail) {
        std::cerr << "System mapi32.dll has no MAPISendMail export\n";
        FreeLibrary(dll);
        return 2;
    }

    std::string subject = std::string("go-mapi installed probe: ") + argv[2];
    std::string path = attachmentPath.string();
    std::string filename = attachmentPath.filename().string();
    char body[] = "Installed Simple MAPI dispatch test body. Review draft only.";
    char recipientName[] = "Probe Recipient";
    char recipientAddress[] = "SMTP:probe@example.invalid";
    MapiRecipDesc recipient = {};
    recipient.ulRecipClass = MAPI_TO;
    recipient.lpszName = recipientName;
    recipient.lpszAddress = recipientAddress;
    MapiFileDesc file = {};
    file.nPosition = static_cast<ULONG>(-1);
    file.lpszPathName = path.data();
    file.lpszFileName = filename.data();
    MapiMessage message = {};
    message.lpszSubject = subject.data();
    message.lpszNoteText = body;
    message.nRecipCount = 1;
    message.lpRecips = &recipient;
    message.nFileCount = 1;
    message.lpFiles = &file;

    std::cout << "Architecture: " << (sizeof(void*) == 8 ? "x64" : "x86")
              << "; subject: " << subject << "; recipient: " << recipientAddress
              << "; body: " << body << "; attachment: " << path << '\n';
    std::cout << "MAPI_DIALOG requested. Cancel any unexpected other-client compose window; never send.\n";
    const ULONG status = sendMail(0, 0, &message, kComposeDialog, 0);
    std::cout << "MAPISendMail status: " << status << '\n';
    FreeLibrary(dll);
    return status == SUCCESS_SUCCESS ? 0 : 1;
}
