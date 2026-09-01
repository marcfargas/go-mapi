#include "mapi_impl.h"
#include "message_converter.h"
#include "fs_utils.h"
#include "json_writer.h"
#include "component_compat.h"
#include <windows.h>
#include <psapi.h>
#include <cstdint>
#include <string>
#include <vector>

#ifndef GO_MAPI_VERSION
#define GO_MAPI_VERSION "0.0.0-dev"
#endif
#ifndef GO_MAPI_REQUIRED_APP_MIN
#define GO_MAPI_REQUIRED_APP_MIN "4.0.0"
#endif
#ifndef GO_MAPI_REQUIRED_APP_MAX
#define GO_MAPI_REQUIRED_APP_MAX ""
#endif
#ifndef GO_MAPI_ARCH
#define GO_MAPI_ARCH "unknown"
#endif

#pragma comment(lib, "psapi.lib")

namespace go_mapi {

// QUICK-260423-tk6: copy attachments into a stable sibling dir keyed off the
// supplied stem. On success, mutates msg.attachments in-place so each entry's
// `path` points at the new copy and `size` reflects the copied byte count.
// On any failure, best-effort removes partial files and writes the reason to
// errors\<stem>.error so the Wails app surfaces it. Returns true iff every
// attachment landed (or there were none).
//
// Rationale: the legacy Spanish MAPI app deletes its own TEMP dir as soon as
// MAPISendMail returns, so if we leave the original paths in the JSON the
// Wails app later hits "attachment not found" on draft creation.
static bool CopyAttachmentsForStem(MailMessage& msg, const std::wstring& stem) {
    if (msg.attachments.empty()) return true;

    std::wstring attachDir = FsUtils::GetAttachmentsDirForStem(stem);
    if (attachDir.empty()) return false;
    if (!FsUtils::EnsureDirExists(attachDir)) {
        FsUtils::WriteErrorForStem(stem,
            "failed to create attachments directory");
        return false;
    }

    std::vector<std::wstring> landed;  // for rollback on partial failure
    for (auto it = msg.attachments.begin(); it != msg.attachments.end();) {
        auto& att = *it;
        if (att.path.empty()) {
            // A descriptor without a source cannot be made queue-owned.
            // Omit it rather than publishing a message that the consumer must
            // reject after MAPISendMail has reported success.
            it = msg.attachments.erase(it);
            continue;
        }
        // Basename fallback: prefer explicit filename, else message_converter
        // already derived it from the path via FilenameFromPath.
        std::string basename = !att.filename.empty() ? att.filename : att.path;
        const size_t separator = basename.find_last_of("\\/");
        if (separator != std::string::npos) {
            basename = basename.substr(separator + 1);
        }
        if (basename.empty() || basename == "." || basename == "..") {
            FsUtils::RemoveAttachmentsDirForStem(stem);
            FsUtils::WriteErrorForStem(stem, "invalid attachment filename");
            return false;
        }

        std::wstring newPath;
        uint32_t newSize = 0;
        if (!FsUtils::CopyFileToDir(att.path, attachDir, basename,
                                    newPath, newSize)) {
            // Roll back any files we already copied this message to keep the
            // queue clean — half-a-message would be worse than nothing.
            for (const auto& p : landed) {
                DeleteFileW(p.c_str());
            }
            RemoveDirectoryW(attachDir.c_str());
            FsUtils::WriteErrorForStem(stem,
                "failed to copy attachment to queue");
            return false;
        }
        landed.push_back(newPath);

        // Keep JSON descriptors complete even when MAPI supplied only a path.
        att.filename = basename;

        // Rewrite attachment path/size so the Gmail client reads from the
        // stable copy instead of the caller's about-to-be-deleted TEMP.
        int n = WideCharToMultiByte(CP_UTF8, 0, newPath.c_str(), -1,
                                    nullptr, 0, nullptr, nullptr);
        if (n <= 1) {
            FsUtils::RemoveAttachmentsDirForStem(stem);
            FsUtils::WriteErrorForStem(stem, "failed to encode queued attachment path");
            return false;
        }
        std::string newPathUtf8(static_cast<size_t>(n), '\0');
        if (WideCharToMultiByte(CP_UTF8, 0, newPath.c_str(), -1,
                                newPathUtf8.data(), n, nullptr, nullptr) != n) {
            FsUtils::RemoveAttachmentsDirForStem(stem);
            FsUtils::WriteErrorForStem(stem, "failed to encode queued attachment path");
            return false;
        }
        newPathUtf8.pop_back();
        att.path = newPathUtf8;
        att.size = newSize;
        ++it;
    }
    if (msg.attachments.empty()) {
        FsUtils::RemoveAttachmentsDirForStem(stem);
    }
    return true;
}

// This is only a diagnostic safety signal. The machine-wide interceptor must
// never change MAPI success/failure based on whether a user's Wails app runs.
static void WarnIfWailsAppUnavailable() {
    const auto presence = FsUtils::CheckAppPresence();
    if (presence == FsUtils::AppPresenceStatus::Available) {
        (void)FsUtils::RemoveMissingAppWarning();
    } else {
        (void)FsUtils::WriteMissingAppWarning(presence);
    }
}

static const char* ComponentStateReason(FsUtils::AppComponentStateStatus status) {
    switch (status) {
    case FsUtils::AppComponentStateStatus::Available: return "available";
    case FsUtils::AppComponentStateStatus::Missing: return "missing";
    case FsUtils::AppComponentStateStatus::Unreadable: return "unreadable";
    case FsUtils::AppComponentStateStatus::Malformed: return "malformed";
    case FsUtils::AppComponentStateStatus::Stale: return "stale";
    case FsUtils::AppComponentStateStatus::Future: return "future";
    }
    return "invalid";
}

// A truly absent/stale app retains the established best-effort warning and
// success behavior. Once a fresh presence marker says the app is running, its
// version state becomes mandatory and a known/invalid mismatch fails before
// attachment staging or descriptor publication.
static bool AppCounterpartAllowsPublication() {
    if (FsUtils::CheckAppPresence() != FsUtils::AppPresenceStatus::Available) return true;
    const auto state = FsUtils::CheckAppComponentState();
    const CounterpartRequirement required{"app", GO_MAPI_REQUIRED_APP_MIN, GO_MAPI_REQUIRED_APP_MAX};
    if (state.status != FsUtils::AppComponentStateStatus::Available) {
        (void)FsUtils::WriteComponentMismatchWarning(
            GO_MAPI_VERSION, GO_MAPI_ARCH, required.minInclusive, required.maxExclusive,
            ComponentStateReason(state.status), state.version);
        return false;
    }
    const auto result = EvaluateCompatibility(state.version, required, "update-app");
    if (result.status == CompatibilityStatus::Compatible) {
        (void)FsUtils::RemoveComponentMismatchWarning();
        return true;
    }
    (void)FsUtils::WriteComponentMismatchWarning(
        GO_MAPI_VERSION, GO_MAPI_ARCH, required.minInclusive, required.maxExclusive,
        CompatibilityStatusName(result.status), state.version);
    return false;
}

std::string MapiImpl::GetOriginApplicationName() {
    wchar_t processPath[MAX_PATH];
    HANDLE hProcess = GetCurrentProcess();

    if (GetModuleFileNameExW(hProcess, nullptr, processPath, MAX_PATH)) {
        // Get just the filename from the full path
        wchar_t* filename = wcsrchr(processPath, L'\\');
        if (filename) {
            filename++;  // Move past the backslash
        } else {
            filename = processPath;
        }

        // Convert to UTF-8
        int size_needed = WideCharToMultiByte(CP_UTF8, 0, filename, -1, NULL, 0, NULL, NULL);
        std::string result(size_needed - 1, 0);
        WideCharToMultiByte(CP_UTF8, 0, filename, -1, &result[0], size_needed, NULL, NULL);
        return result;
    }

    return "unknown.exe";
}

ULONG MapiImpl::MAPISendMailA(
    LHANDLE lhSession,
    ULONG_PTR ulUIParam,
    LPMapiMessage lpMessage,
    FLAGS flFlags,
    ULONG ulReserved
) {
    if (!lpMessage) {
        return MAPI_E_INVALID_MESSAGE;
    }
    if (!AppCounterpartAllowsPublication()) return MAPI_E_FAILURE;

    std::wstring stem;
    try {
        MailMessage msg = message_converter::ConvertAnsiMessage(*lpMessage);
        // originApp populated here because it requires live process context
        // (out of scope for the pure message_converter module).
        msg.originApp = GetOriginApplicationName();

        // QUICK-260423-tk6: copy attachments into a queue-owned sibling dir
        // BEFORE writing the JSON. The legacy Spanish MAPI caller deletes its
        // own TEMP directory as soon as this function returns, so the Wails
        // app would otherwise see "attachment not found" on draft creation.
        stem = FsUtils::GenerateUniqueStem();
        if (!CopyAttachmentsForStem(msg, stem)) {
            // Error file already written by CopyAttachmentsForStem; do NOT
            // write the JSON — half-a-message would silently drop attachments.
            FsUtils::RemoveAttachmentsDirForStem(stem);
            return MAPI_E_FAILURE;
        }
        std::wstring filePath = JsonWriter::WriteMailToFileWithStem(msg, stem);

        if (filePath.empty()) {
            FsUtils::RemoveAttachmentsDirForStem(stem);
            FsUtils::WriteErrorForStem(stem, "failed to publish queue message");
            return MAPI_E_FAILURE;
        }
        WarnIfWailsAppUnavailable();
        return SUCCESS_SUCCESS;
    } catch (...) {
        // Serialization and filesystem calls can throw too. Never strand
        // queue-owned attachments when that prevents the JSON publication.
        if (!stem.empty()) {
            FsUtils::RemoveAttachmentsDirForStem(stem);
            FsUtils::WriteErrorForStem(stem, "failed to publish queue message");
        }
        return MAPI_E_FAILURE;
    }
}

ULONG MapiImpl::MAPISendMailW(
    LHANDLE lhSession,
    ULONG_PTR ulUIParam,
    LPMapiMessageW lpMessage,
    FLAGS flFlags,
    ULONG ulReserved
) {
    if (!lpMessage) {
        return MAPI_E_INVALID_MESSAGE;
    }
    if (!AppCounterpartAllowsPublication()) return MAPI_E_FAILURE;

    std::wstring stem;
    try {
        MailMessage msg = message_converter::ConvertWideMessage(*lpMessage);
        // originApp populated here because it requires live process context
        // (out of scope for the pure message_converter module).
        msg.originApp = GetOriginApplicationName();

        // QUICK-260423-tk6: same lifetime fix as the ANSI path — copy
        // attachments into %LOCALAPPDATA%\go-mapi\queue\<stem>\ before the
        // caller's TEMP dir disappears on return.
        stem = FsUtils::GenerateUniqueStem();
        if (!CopyAttachmentsForStem(msg, stem)) {
            FsUtils::RemoveAttachmentsDirForStem(stem);
            return MAPI_E_FAILURE;
        }
        std::wstring filePath = JsonWriter::WriteMailToFileWithStem(msg, stem);

        if (filePath.empty()) {
            FsUtils::RemoveAttachmentsDirForStem(stem);
            FsUtils::WriteErrorForStem(stem, "failed to publish queue message");
            return MAPI_E_FAILURE;
        }
        WarnIfWailsAppUnavailable();
        return SUCCESS_SUCCESS;
    } catch (...) {
        if (!stem.empty()) {
            FsUtils::RemoveAttachmentsDirForStem(stem);
            FsUtils::WriteErrorForStem(stem, "failed to publish queue message");
        }
        return MAPI_E_FAILURE;
    }
}

ULONG MapiImpl::MAPILogon(
    ULONG_PTR ulUIParam,
    LPSTR lpszProfileName,
    LPSTR lpszPassword,
    FLAGS flFlags,
    ULONG ulReserved,
    LPLHANDLE lphSession
) {
    // Stub: just return success
    if (lphSession) {
        *lphSession = 1;  // Return a dummy session handle
    }
    return SUCCESS_SUCCESS;
}

ULONG MapiImpl::MAPILogoff(
    LHANDLE lhSession,
    ULONG_PTR ulUIParam,
    FLAGS flFlags,
    ULONG ulReserved
) {
    // Stub: just return success
    return SUCCESS_SUCCESS;
}

ULONG MapiImpl::MAPIFreeBuffer(LPVOID pv) {
    // Stub: nothing to free in our implementation
    return SUCCESS_SUCCESS;
}

ULONG MapiImpl::MAPISendDocuments(
    ULONG_PTR ulUIParam,
    LPSTR lpszDelimChar,
    LPSTR lpszFilePaths,
    LPSTR lpszFileNames,
    ULONG ulReserved
) {
    // The interceptor intentionally has no compose UI.  Preserve its legacy
    // documented no-op for no attachments instead of emitting an empty queue
    // descriptor or trying to reproduce Simple MAPI's cover-note dialog.
    if (!lpszFilePaths || !lpszFilePaths[0]) return SUCCESS_SUCCESS;
    if (!AppCounterpartAllowsPublication()) return MAPI_E_FAILURE;

    std::wstring stem;
    try {
        MailMessage msg;
        msg.bodyFormat = "plain";
        msg.originApp = GetOriginApplicationName();
        if (!message_converter::ConvertSendDocumentsAttachments(
                lpszDelimChar, lpszFilePaths, lpszFileNames, msg.attachments)) {
            return MAPI_E_FAILURE;
        }

        stem = FsUtils::GenerateUniqueStem();
        if (!CopyAttachmentsForStem(msg, stem)) {
            FsUtils::RemoveAttachmentsDirForStem(stem);
            return MAPI_E_FAILURE;
        }
        if (JsonWriter::WriteMailToFileWithStem(msg, stem).empty()) {
            FsUtils::RemoveAttachmentsDirForStem(stem);
            FsUtils::WriteErrorForStem(stem, "failed to publish queue message");
            return MAPI_E_FAILURE;
        }
        WarnIfWailsAppUnavailable();
        return SUCCESS_SUCCESS;
    } catch (...) {
        if (!stem.empty()) {
            FsUtils::RemoveAttachmentsDirForStem(stem);
            FsUtils::WriteErrorForStem(stem, "failed to publish queue message");
        }
        return MAPI_E_FAILURE;
    }
}

} // namespace go_mapi
