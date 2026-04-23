#pragma once

#include <windows.h>
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

    // Generate a unique filename (timestamp_randomchars.json)
    static std::wstring GenerateUniqueFilename();

    // Write UTF-8 encoded content to a file
    static bool WriteFile(const std::wstring& filePath, const std::string& content);

private:
    // Get base queue directory (%LOCALAPPDATA%\go-mapi\queue) without trailing separator.
    static std::wstring GetBaseQueueDir();

    // Get 6 random hex characters
    static std::string GetRandomSuffix();
};

} // namespace go_mapi
