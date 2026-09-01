#pragma once

#include <windows.h>
#include <cstdint>
#include <string>

namespace go_mapi {

class FsUtils {
public:
    enum class AppPresenceStatus { Available, Missing, Unreadable, Malformed, Stale, Future };
    enum class AppComponentStateStatus { Available, Missing, Unreadable, Malformed, Stale, Future };
    struct AppComponentState {
        AppComponentStateStatus status{AppComponentStateStatus::Unreadable};
        std::string version;
    };
    // Test-only fault points for the atomic publisher. They let native tests
    // prove cleanup for each publish phase without relying on filesystem ACL
    // accidents. Production callers leave this at None.
    enum class AtomicWriteFault { None, Write, Flush, Rename };
    static void SetAtomicWriteFaultForTesting(AtomicWriteFault fault);
    // Get the queue directory path (e.g., %LOCALAPPDATA%\go-mapi\queue\) — invariant
    // regardless of the calling process's TEMP/TMP environment.
    static std::wstring GetQueueDirectory();

    // The Wails app writes this small, per-user marker beneath %APPDATA%\\go-mapi
    // after it has opened the queue. It is intentionally separate from the
    // queue: queue creation alone is not proof that the app is working.
    static std::wstring GetAppPresencePath();
    static AppPresenceStatus CheckAppPresence();
    // Path/clock injectable form used by native tests. `now` must be a FILETIME
    // in UTC; production callers use CheckAppPresence().
    static AppPresenceStatus CheckAppPresenceFile(const std::wstring& path, FILETIME now);

    static std::wstring GetAppComponentStatePath();
    static AppComponentState CheckAppComponentState();
    static AppComponentState CheckAppComponentStateFile(const std::wstring& path, FILETIME now);

    // A stable create-if-absent diagnostic for legacy caller processes. It is
    // non-modal and best effort; callers must never make MAPI success depend on it.
    static bool WriteMissingAppWarning(AppPresenceStatus status);
    static bool RemoveMissingAppWarning();

    static std::wstring GetComponentMismatchWarningPath();
    static bool WriteComponentMismatchWarning(const std::string& interceptorVersion,
                                              const std::string& architecture,
                                              const std::string& minInclusive,
                                              const std::string& maxExclusive,
                                              const std::string& observedStatus,
                                              const std::string& observedVersion);
    static bool RemoveComponentMismatchWarning();

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

    // Publish UTF-8 content atomically. The file is written to a unique temp
    // file in the destination directory, flushed and closed, then renamed to
    // filePath. Queue consumers must only observe the final name after the
    // complete JSON document is durable enough to read.
    static bool WriteFileAtomically(const std::wstring& filePath,
                                    const std::string& content);

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

    // Best-effort rollback of the queue-owned attachment directory for a
    // message that could not be published. This deliberately leaves the
    // errors directory untouched so callers can still report the failure.
    static bool RemoveAttachmentsDirForStem(const std::wstring& stem);

private:
    // Get base queue directory (%LOCALAPPDATA%\go-mapi\queue) without trailing separator.
    static std::wstring GetBaseQueueDir();

    // Get 6 random hex characters
    static std::string GetRandomSuffix();
};

} // namespace go_mapi
