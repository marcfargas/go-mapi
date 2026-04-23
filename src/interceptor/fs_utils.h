#pragma once

#include <windows.h>
#include <cstdint>
#include <string>

namespace go_mapi {

class FsUtils {
public:
    // Get the queue directory path (e.g., %LOCALAPPDATA%\go-mapi\queue\) — invariant
    // regardless of the calling process's TEMP/TMP environment.
    static std::wstring GetQueueDirectory();

    // Ensure the queue directory and the queue/errors subdirectory both exist
    // (create if needed).
    static bool EnsureOutputDirectory();

    // Generate a unique stem ("msg_<ts>_<sfx>", no extension). Used as the
    // shared identity between the JSON file and its sibling attachments dir.
    static std::wstring GenerateUniqueStem();

    // Generate a unique filename: stem + L".json".
    static std::wstring GenerateUniqueFilename();

    // Write UTF-8 encoded content to a file
    static bool WriteFile(const std::wstring& filePath, const std::string& content);

    // QUICK-260423-tk6 — attachment-copy helpers.
    //
    // The legacy Spanish MAPI app deletes its own TEMP dir (C:\TEMP\<user>\<pid>\)
    // as soon as MAPISendMail returns, so by the time the Wails app processes
    // the queue the attachment is gone. Fix: the DLL copies attachments into
    // a stable, queue-owned sibling dir (%LOCALAPPDATA%\go-mapi\queue\<stem>\)
    // *before* writing the JSON. See plan 260423-tk6 for the full design.

    // Sibling dir for a given JSON stem (no trailing separator).
    static std::wstring GetAttachmentsDirForStem(const std::wstring& stem);

    // Create the directory (and any missing parents). Success if it already
    // exists. Returns false on real filesystem failure.
    static bool EnsureDirExists(const std::wstring& path);

    // Copy a file from srcUtf8 into destDir under destBasenameUtf8. On success
    // sets outNewPath (the wide full path) and outSize (byte count of the copy).
    // destDir must already exist (use EnsureDirExists). Never overwrites an
    // existing destination file.
    static bool CopyFileToDir(const std::string& srcUtf8,
                              const std::wstring& destDir,
                              const std::string& destBasenameUtf8,
                              std::wstring& outNewPath,
                              uint32_t& outSize);

    // Write a short, UTF-8 reason string to %LOCALAPPDATA%\go-mapi\queue\errors\<stem>.error.
    // Used when the DLL cannot land an attachment copy and must abort before
    // writing the JSON (see mapi_impl.cpp MAPISendMailA/W orchestration).
    static bool WriteErrorForStem(const std::wstring& stem,
                                  const std::string& reason);

private:
    // Get base queue directory (%LOCALAPPDATA%\go-mapi\queue) without trailing separator.
    static std::wstring GetBaseQueueDir();

    // Get 6 random hex characters
    static std::string GetRandomSuffix();
};

} // namespace go_mapi
