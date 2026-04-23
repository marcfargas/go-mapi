#include "message_converter.h"
#include <windows.h>
#include <string>

namespace go_mapi {
namespace message_converter {

std::string WideToUtf8(const wchar_t* wide) {
    if (!wide || !wide[0]) return "";
    int size = WideCharToMultiByte(CP_UTF8, 0, wide, -1, NULL, 0, NULL, NULL);
    if (size <= 0) return "";
    std::string result(size - 1, 0);
    WideCharToMultiByte(CP_UTF8, 0, wide, -1, &result[0], size, NULL, NULL);
    return result;
}

std::string AnsiToUtf8(const char* ansi) {
    if (!ansi || !ansi[0]) return "";
    // Step 1: ANSI (system codepage) → UTF-16
    int wideLen = MultiByteToWideChar(CP_ACP, 0, ansi, -1, NULL, 0);
    if (wideLen <= 0) return ansi;  // fallback: return raw bytes
    std::wstring wide(wideLen - 1, 0);
    MultiByteToWideChar(CP_ACP, 0, ansi, -1, &wide[0], wideLen);
    // Step 2: UTF-16 → UTF-8
    return WideToUtf8(wide.c_str());
}

std::string FilenameFromPath(const std::string& path) {
    // Extract filename from a Windows path (backslash or forward slash)
    auto pos = path.find_last_of("\\/");
    if (pos != std::string::npos && pos + 1 < path.size()) {
        return path.substr(pos + 1);
    }
    return path;
}

// QUICK-260423-qpx: many legacy Simple MAPI callers (Spanish SendEmail-style
// apps, older accounting software, Win32 utilities that predate the modern
// lpszName/lpszAddress split) populate only lpszName with a bare email and
// leave lpszAddress NULL. Promote when the name looks like an email so the
// Go validator can accept the message. Only considers '@' as the signal --
// the Go side (normalizeAddress) handles further cleanup.
static void PromoteEmailShapedNameToAddress(Recipient& r) {
    if (!r.address.empty()) return;
    if (r.name.empty()) return;
    if (r.name.find('@') == std::string::npos) return;
    r.address = r.name;
    r.name.clear();
}

MailMessage ConvertAnsiMessage(const MapiMessage& msg) {
    MailMessage result;
    // originApp is populated by the DLL glue layer (MapiImpl::GetOriginApplicationName),
    // which requires a live process context and stays outside this pure module.
    result.bodyFormat = "plain";

    // Subject — ANSI codepage → UTF-8
    if (msg.lpszSubject) {
        result.subject = AnsiToUtf8(msg.lpszSubject);
    }

    // Body — ANSI codepage → UTF-8
    if (msg.lpszNoteText) {
        result.body = AnsiToUtf8(msg.lpszNoteText);
    }

    // Recipients
    if (msg.lpRecips && msg.nRecipCount > 0) {
        for (ULONG i = 0; i < msg.nRecipCount; ++i) {
            const MapiRecipDesc& recip = msg.lpRecips[i];
            Recipient r;
            if (recip.lpszName) {
                r.name = AnsiToUtf8(recip.lpszName);
            }
            if (recip.lpszAddress) {
                r.address = AnsiToUtf8(recip.lpszAddress);
            }
            PromoteEmailShapedNameToAddress(r);

            switch (recip.ulRecipClass) {
            case MAPI_TO:
                result.toRecipients.push_back(r);
                break;
            case MAPI_CC:
                result.ccRecipients.push_back(r);
                break;
            case MAPI_BCC:
                result.bccRecipients.push_back(r);
                break;
            default:
                result.toRecipients.push_back(r);
                break;
            }
        }
    }

    // Attachments
    if (msg.lpFiles && msg.nFileCount > 0) {
        for (ULONG i = 0; i < msg.nFileCount; ++i) {
            const MapiFileDesc& file = msg.lpFiles[i];
            Attachment attach;
            if (file.lpszPathName) {
                attach.path = AnsiToUtf8(file.lpszPathName);
            }
            if (file.lpszFileName) {
                attach.filename = AnsiToUtf8(file.lpszFileName);
            } else if (!attach.path.empty()) {
                // Windows often leaves lpszFileName NULL — extract from path
                attach.filename = FilenameFromPath(attach.path);
            }
            attach.size = 0;

            result.attachments.push_back(attach);
        }
    }

    return result;
}

MailMessage ConvertWideMessage(const MapiMessageW& msg) {
    MailMessage result;
    // originApp is populated by the DLL glue layer (MapiImpl::GetOriginApplicationName),
    // which requires a live process context and stays outside this pure module.
    result.bodyFormat = "plain";

    // Subject
    if (msg.lpszSubject) {
        result.subject = WideToUtf8(msg.lpszSubject);
    }

    // Body
    if (msg.lpszNoteText) {
        result.body = WideToUtf8(msg.lpszNoteText);
    }

    // Recipients
    if (msg.lpRecips && msg.nRecipCount > 0) {
        for (ULONG i = 0; i < msg.nRecipCount; ++i) {
            const MapiRecipDescW& recip = msg.lpRecips[i];
            Recipient r;
            if (recip.lpszName) {
                r.name = WideToUtf8(recip.lpszName);
            }
            if (recip.lpszAddress) {
                r.address = WideToUtf8(recip.lpszAddress);
            }
            PromoteEmailShapedNameToAddress(r);

            switch (recip.ulRecipClass) {
            case MAPI_TO:
                result.toRecipients.push_back(r);
                break;
            case MAPI_CC:
                result.ccRecipients.push_back(r);
                break;
            case MAPI_BCC:
                result.bccRecipients.push_back(r);
                break;
            default:
                result.toRecipients.push_back(r);
                break;
            }
        }
    }

    // Attachments
    if (msg.lpFiles && msg.nFileCount > 0) {
        for (ULONG i = 0; i < msg.nFileCount; ++i) {
            const MapiFileDescW& file = msg.lpFiles[i];
            Attachment attach;
            if (file.lpszPathName) {
                attach.path = WideToUtf8(file.lpszPathName);
            }
            if (file.lpszFileName) {
                attach.filename = WideToUtf8(file.lpszFileName);
            } else if (!attach.path.empty()) {
                // Windows often leaves lpszFileName NULL — extract from path
                attach.filename = FilenameFromPath(attach.path);
            }
            attach.size = 0;

            result.attachments.push_back(attach);
        }
    }

    return result;
}

} // namespace message_converter
} // namespace go_mapi
