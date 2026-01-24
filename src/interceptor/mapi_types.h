#pragma once

#include <windows.h>
#include <cstdint>

// MAPI Types and Structures
// Reference: https://learn.microsoft.com/en-us/windows/win32/api/mapi/ns-mapi-mapimessage

// Define MAPI types if not already defined
#ifndef LHANDLE
typedef ULONG_PTR LHANDLE;
typedef LHANDLE* LPLHANDLE;
#endif

#ifndef FLAGS
typedef ULONG FLAGS;
#endif

// Recipient types
#define MAPI_TO       1
#define MAPI_CC       2
#define MAPI_BCC      3

// Message flags
#define MAPI_LOGON_UI        0x00000001
#define MAPI_PASSWORD_UI     0x00020000

// Return codes
#define SUCCESS_SUCCESS      0
#define MAPI_E_FAILURE       2
#define MAPI_E_LOGON_FAILURE 3
#define MAPI_E_DISK_FULL     4
#define MAPI_E_INSUFFICIENT_MEMORY 5
#define MAPI_E_ACCESS_DENIED 6
#define MAPI_E_INVALID_MESSAGE 7

#ifdef __cplusplus
extern "C" {
#endif

// File descriptor for attachments
typedef struct
{
    ULONG ulReserved;
    ULONG flFlags;
    ULONG nPosition;
    LPSTR lpszPathName;
    LPSTR lpszFileName;
    LPVOID lpFileType;
} MapiFileDesc, *LPMapiFileDesc;

// Recipient descriptor
typedef struct
{
    ULONG ulReserved;
    ULONG ulRecipClass;
    LPSTR lpszName;
    LPSTR lpszAddress;
    ULONG ulEIDSize;
    LPVOID lpEntryID;
} MapiRecipDesc, *LPMapiRecipDesc;

// Main message structure
typedef struct
{
    ULONG ulReserved;
    LPSTR lpszSubject;
    LPSTR lpszNoteText;
    LPSTR lpszMessageType;
    LPSTR lpszDateReceived;
    LPSTR lpszConversationID;
    FLAGS flFlags;
    LPMapiRecipDesc lpOriginator;
    ULONG nRecipCount;
    LPMapiRecipDesc lpRecips;
    ULONG nFileCount;
    LPMapiFileDesc lpFiles;
} MapiMessage, *LPMapiMessage;

#ifdef __cplusplus
}
#endif
