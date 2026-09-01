#pragma once

#include <string>
#include "mapi_types.h"
#include "json_writer.h"

namespace go_mapi {
namespace message_converter {

// Convert an ANSI MAPI message to the internal MailMessage representation.
// Pure conversion — no file I/O, no DLL entry points, no global state.
// Callable from tests via the FOUND-05 OBJECT library target.
MailMessage ConvertAnsiMessage(const MapiMessage& msg);

// Convert a Unicode (wide) MAPI message to the internal MailMessage representation.
// Pure conversion — no file I/O, no DLL entry points, no global state.
MailMessage ConvertWideMessage(const MapiMessageW& msg);

// Convert a wide (UTF-16) C string to UTF-8.
// Returns empty string for nullptr input.
std::string WideToUtf8(const wchar_t* wide);

// Convert an ANSI C string to UTF-8 (passthrough if already ASCII).
// Returns empty string for nullptr input.
std::string AnsiToUtf8(const char* ansi);

// Extract the filename portion of a path (basename).
// Pure string manipulation — handles both forward and backward slashes.
std::string FilenameFromPath(const std::string& path);

// Convert the ANSI Simple MAPI MAPISendDocuments string arguments into queue
// attachments.  Returns false for malformed non-empty lists (such as empty
// path tokens or duplicate effective destination names).  A null/empty path
// list is valid and produces no attachments; the DLL entry point owns the
// documented no-op behavior for that case.
bool ConvertSendDocumentsAttachments(const char* delimiter,
                                     const char* filePaths,
                                     const char* fileNames,
                                     std::vector<Attachment>& attachments);

} // namespace message_converter
} // namespace go_mapi
