#pragma once

#include "mapi_types.h"
#include "json_writer.h"

namespace go_mapi {

class MapiImpl {
public:
    // ANSI version of MAPISendMail
    static ULONG MAPISendMailA(
        LHANDLE lhSession,
        ULONG_PTR ulUIParam,
        LPMapiMessage lpMessage,
        FLAGS flFlags,
        ULONG ulReserved
    );

    // Unicode version of MAPISendMail
    static ULONG MAPISendMailW(
        LHANDLE lhSession,
        ULONG_PTR ulUIParam,
        LPMapiMessageW lpMessage,
        FLAGS flFlags,
        ULONG ulReserved
    );

    // Stub implementations
    static ULONG MAPILogon(
        ULONG_PTR ulUIParam,
        LPSTR lpszProfileName,
        LPSTR lpszPassword,
        FLAGS flFlags,
        ULONG ulReserved,
        LPLHANDLE lphSession
    );

    static ULONG MAPILogoff(
        LHANDLE lhSession,
        ULONG_PTR ulUIParam,
        FLAGS flFlags,
        ULONG ulReserved
    );

    static ULONG MAPIFreeBuffer(LPVOID pv);

    static ULONG MAPISendDocuments(
        ULONG_PTR ulUIParam,
        LPSTR lpszDelimChar,
        LPSTR lpszFilePaths,
        LPSTR lpszFileNames,
        ULONG ulReserved
    );

private:
    // Get application name (for originApp field).
    // Kept in MapiImpl because it queries the live process via Windows APIs
    // (GetModuleFileNameExW) — not pure conversion, so excluded from message_converter.
    static std::string GetOriginApplicationName();
};

} // namespace go_mapi
