#include "mapi_impl.h"
#include "message_converter.h"
#include <windows.h>
#include <psapi.h>
#include <string>

#pragma comment(lib, "psapi.lib")

namespace go_mapi {

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

    try {
        MailMessage msg = message_converter::ConvertAnsiMessage(*lpMessage);
        // originApp populated here because it requires live process context
        // (out of scope for the pure message_converter module).
        msg.originApp = GetOriginApplicationName();
        std::wstring filePath = JsonWriter::WriteMailToFile(msg);

        if (filePath.empty()) {
            return MAPI_E_FAILURE;
        }

        return SUCCESS_SUCCESS;
    } catch (...) {
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

    try {
        MailMessage msg = message_converter::ConvertWideMessage(*lpMessage);
        // originApp populated here because it requires live process context
        // (out of scope for the pure message_converter module).
        msg.originApp = GetOriginApplicationName();
        std::wstring filePath = JsonWriter::WriteMailToFile(msg);

        if (filePath.empty()) {
            return MAPI_E_FAILURE;
        }

        return SUCCESS_SUCCESS;
    } catch (...) {
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
    // Stub: not implemented yet
    return SUCCESS_SUCCESS;
}

} // namespace go_mapi
