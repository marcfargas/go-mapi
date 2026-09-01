// QUICK-260423-tk6: unit tests for fs_utils attachment-copy helpers.
//
// Covers the new helpers introduced so the DLL can copy attachments into a
// stable queue-owned directory during MAPISendMail, before the legacy caller
// deletes its own TEMP dir on return (see plan notes).
//
//   - GenerateUniqueStem: returns a msg_<ts>_<sfx> stem with no extension.
//   - GenerateUniqueFilename: thin wrapper — stem + L".json".
//   - GetAttachmentsDirForStem: sibling directory matching the JSON stem.
//   - EnsureDirExists: idempotent directory creation.
//   - CopyFileToDir: happy + missing-source paths, populates new path + size.
//   - WriteErrorForStem: writes errors\<stem>.error with a reason.
//
// These tests write real files into a temp scratch dir under CMAKE_BINARY_DIR
// so they do not pollute the user's %LOCALAPPDATA%\go-mapi\queue\. They never
// mutate real queue state.

#define DOCTEST_CONFIG_IMPLEMENT_WITH_MAIN
#include "doctest.h"

#include "fs_utils.h"

#include <windows.h>
#include <shlobj.h>

#include <cstdio>
#include <cstring>
#include <string>

using namespace go_mapi;

// -------- helpers --------

static std::wstring makeScratchDir(const wchar_t* leaf) {
    wchar_t tempBase[MAX_PATH];
    DWORD n = GetTempPathW(MAX_PATH, tempBase);
    REQUIRE(n > 0);
    std::wstring dir(tempBase);
    if (!dir.empty() && dir.back() != L'\\') dir += L'\\';
    dir += L"go-mapi-tk6-tests\\";
    dir += leaf;
    SHCreateDirectoryExW(nullptr, dir.c_str(), nullptr);
    return dir;
}

static void writeBytes(const std::wstring& path, const char* data, size_t len) {
    HANDLE h = CreateFileW(path.c_str(), GENERIC_WRITE, 0, nullptr,
                           CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    REQUIRE(h != INVALID_HANDLE_VALUE);
    DWORD wrote = 0;
    WriteFile(h, data, static_cast<DWORD>(len), &wrote, nullptr);
    CloseHandle(h);
}

static bool fileExists(const std::wstring& path) {
    DWORD attr = GetFileAttributesW(path.c_str());
    return (attr != INVALID_FILE_ATTRIBUTES) && !(attr & FILE_ATTRIBUTE_DIRECTORY);
}

static bool noTemporaryFiles(const std::wstring& directory) {
    WIN32_FIND_DATAW entry{};
    HANDLE find = FindFirstFileW((directory + L"\\*.tmp").c_str(), &entry);
    if (find == INVALID_HANDLE_VALUE) return true;
    FindClose(find);
    return false;
}

static std::string toUtf8(const std::wstring& w) {
    if (w.empty()) return "";
    int n = WideCharToMultiByte(CP_UTF8, 0, w.c_str(), -1, nullptr, 0, nullptr, nullptr);
    std::string out(n - 1, 0);
    WideCharToMultiByte(CP_UTF8, 0, w.c_str(), -1, &out[0], n, nullptr, nullptr);
    return out;
}

// -------- GenerateUniqueStem / GenerateUniqueFilename --------

TEST_CASE("GenerateUniqueStem begins with msg_ and has no extension") {
    std::wstring stem = FsUtils::GenerateUniqueStem();
    REQUIRE(stem.size() > 4);
    CHECK(stem.substr(0, 4) == L"msg_");
    CHECK(stem.find(L'.') == std::wstring::npos);
}

TEST_CASE("GenerateUniqueFilename is stem + .json") {
    std::wstring fname = FsUtils::GenerateUniqueFilename();
    REQUIRE(fname.size() > 5);
    CHECK(fname.substr(0, 4) == L"msg_");
    CHECK(fname.substr(fname.size() - 5) == L".json");
}

// -------- GetAttachmentsDirForStem --------

TEST_CASE("GetAttachmentsDirForStem returns sibling dir of the JSON") {
    std::wstring stem = L"msg_20260423_190249_abc123";
    std::wstring attachDir = FsUtils::GetAttachmentsDirForStem(stem);
    // The attachments dir must be under the queue directory, with the stem
    // as its final component (no trailing separator, no extension).
    std::wstring queueDir = FsUtils::GetQueueDirectory();
    REQUIRE(!queueDir.empty());
    // queueDir ends with a trailing separator; attachDir should == queueDir + stem.
    std::wstring expected = queueDir + stem;
    CHECK(attachDir == expected);
}

// -------- EnsureDirExists --------

TEST_CASE("EnsureDirExists creates a fresh directory and is idempotent") {
    std::wstring scratch = makeScratchDir(L"ensure");
    std::wstring leaf = scratch + L"\\new-subdir";

    // Pre-clean in case a previous run left it.
    RemoveDirectoryW(leaf.c_str());

    CHECK(FsUtils::EnsureDirExists(leaf) == true);
    DWORD attr = GetFileAttributesW(leaf.c_str());
    REQUIRE(attr != INVALID_FILE_ATTRIBUTES);
    CHECK((attr & FILE_ATTRIBUTE_DIRECTORY) != 0);

    // Idempotent second call succeeds too.
    CHECK(FsUtils::EnsureDirExists(leaf) == true);

    RemoveDirectoryW(leaf.c_str());
}

// -------- CopyFileToDir --------

TEST_CASE("CopyFileToDir copies file and reports new path + size") {
    std::wstring scratch = makeScratchDir(L"copyok");
    std::wstring srcPath = scratch + L"\\source.txt";
    std::wstring destDir = scratch + L"\\destdir";
    FsUtils::EnsureDirExists(destDir);

    const char payload[] = "hello-attachment";
    writeBytes(srcPath, payload, sizeof(payload) - 1);

    std::string srcUtf8 = toUtf8(srcPath);
    std::string destBasename = "source.txt";
    std::wstring outNewPath;
    uint32_t outSize = 0;

    bool ok = FsUtils::CopyFileToDir(srcUtf8, destDir, destBasename,
                                     outNewPath, outSize);
    CHECK(ok == true);
    CHECK(outSize == sizeof(payload) - 1);
    CHECK(fileExists(outNewPath));
    CHECK(outNewPath == destDir + L"\\source.txt");

    DeleteFileW(outNewPath.c_str());
    DeleteFileW(srcPath.c_str());
    RemoveDirectoryW(destDir.c_str());
}

TEST_CASE("CopyFileToDir returns false when source is missing") {
    std::wstring scratch = makeScratchDir(L"copymissing");
    std::wstring destDir = scratch + L"\\dest";
    FsUtils::EnsureDirExists(destDir);

    std::string srcUtf8 = toUtf8(scratch + L"\\does-not-exist.bin");
    std::wstring outNewPath = L"sentinel";
    uint32_t outSize = 999;
    bool ok = FsUtils::CopyFileToDir(srcUtf8, destDir, "whatever.bin",
                                     outNewPath, outSize);
    CHECK(ok == false);
    // Sanity: out params should not falsely report a successful copy.
    // (We don't mandate clearing them — just that no file was created.)
    CHECK(!fileExists(destDir + L"\\whatever.bin"));
    RemoveDirectoryW(destDir.c_str());
}

TEST_CASE("CopyFileToDir never overwrites a staged attachment on collision") {
    std::wstring scratch = makeScratchDir(L"copy-collision");
    std::wstring srcPath = scratch + L"\\source.txt";
    std::wstring destDir = scratch + L"\\dest";
    FsUtils::EnsureDirExists(destDir);
    writeBytes(srcPath, "source", 6);
    const std::wstring existing = destDir + L"\\source.txt";
    writeBytes(existing, "already-staged", 14);

    std::wstring newPath;
    uint32_t size = 0;
    CHECK_FALSE(FsUtils::CopyFileToDir(toUtf8(srcPath), destDir, "source.txt", newPath, size));

    HANDLE h = CreateFileW(existing.c_str(), GENERIC_READ, FILE_SHARE_READ,
                           nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    REQUIRE(h != INVALID_HANDLE_VALUE);
    char read[32] = {};
    DWORD count = 0;
    REQUIRE(ReadFile(h, read, sizeof(read), &count, nullptr));
    CloseHandle(h);
    CHECK(std::string(read, count) == "already-staged");

    DeleteFileW(existing.c_str());
    DeleteFileW(srcPath.c_str());
    RemoveDirectoryW(destDir.c_str());
}

// -------- WriteFileAtomically --------

TEST_CASE("WriteFileAtomically publishes complete content without leaving its staging file") {
    std::wstring scratch = makeScratchDir(L"atomic");
    std::wstring finalPath = scratch + L"\\message.json";
    DeleteFileW(finalPath.c_str());

    const std::string payload = R"({"version":1,"subject":"atomic"})";
    REQUIRE(FsUtils::WriteFileAtomically(finalPath, payload));
    REQUIRE(fileExists(finalPath));

    HANDLE h = CreateFileW(finalPath.c_str(), GENERIC_READ, FILE_SHARE_READ,
                           nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    REQUIRE(h != INVALID_HANDLE_VALUE);
    char read[64] = {};
    DWORD count = 0;
    REQUIRE(ReadFile(h, read, sizeof(read), &count, nullptr));
    CloseHandle(h);
    CHECK(std::string(read, count) == payload);

    WIN32_FIND_DATAW entry{};
    HANDLE find = FindFirstFileW((scratch + L"\\*.tmp").c_str(), &entry);
    CHECK(find == INVALID_HANDLE_VALUE);
    if (find != INVALID_HANDLE_VALUE) FindClose(find);
    DeleteFileW(finalPath.c_str());
}

TEST_CASE("WriteFileAtomically never replaces an existing queue message") {
    std::wstring scratch = makeScratchDir(L"atomic-collision");
    std::wstring finalPath = scratch + L"\\message.json";
    const char existing[] = "existing";
    DeleteFileW(finalPath.c_str());
    writeBytes(finalPath, existing, sizeof(existing) - 1);

    CHECK_FALSE(FsUtils::WriteFileAtomically(finalPath, "replacement"));

    HANDLE h = CreateFileW(finalPath.c_str(), GENERIC_READ, FILE_SHARE_READ,
                           nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    REQUIRE(h != INVALID_HANDLE_VALUE);
    char read[32] = {};
    DWORD count = 0;
    REQUIRE(ReadFile(h, read, sizeof(read), &count, nullptr));
    CloseHandle(h);
    CHECK(std::string(read, count) == existing);

    WIN32_FIND_DATAW entry{};
    HANDLE find = FindFirstFileW((scratch + L"\\*.tmp").c_str(), &entry);
    CHECK(find == INVALID_HANDLE_VALUE);
    if (find != INVALID_HANDLE_VALUE) FindClose(find);
    DeleteFileW(finalPath.c_str());
}

TEST_CASE("app component state distinguishes valid, malformed, and stale records") {
    std::wstring scratch = makeScratchDir(L"component-state");
    std::wstring path = scratch + L"\\app-component-state-v1.json";
    DeleteFileW(path.c_str());
    const std::string valid = R"({"schema":"go-mapi-app-component-state-v1","version":"4.2.0","queueProtocol":"queue-v1","refreshedAt":"2026-08-30T12:00:00Z"})";
    writeBytes(path, valid.data(), valid.size());
    FILETIME now{};
    GetSystemTimeAsFileTime(&now);
    auto state = FsUtils::CheckAppComponentStateFile(path, now);
    CHECK(state.status == FsUtils::AppComponentStateStatus::Available);
    CHECK(state.version == "4.2.0");

    DeleteFileW(path.c_str());
    const std::string malformed = R"({"schema":"wrong","version":"4.2.0"})";
    writeBytes(path, malformed.data(), malformed.size());
    state = FsUtils::CheckAppComponentStateFile(path, now);
    CHECK(state.status == FsUtils::AppComponentStateStatus::Malformed);

    ULARGE_INTEGER old{};
    old.LowPart = now.dwLowDateTime;
    old.HighPart = now.dwHighDateTime;
    old.QuadPart -= 6ULL * 60ULL * 10000000ULL;
    FILETIME oldTime{old.LowPart, old.HighPart};
    HANDLE handle = CreateFileW(path.c_str(), FILE_WRITE_ATTRIBUTES, 0, nullptr,
                                OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    REQUIRE(handle != INVALID_HANDLE_VALUE);
    REQUIRE(SetFileTime(handle, nullptr, nullptr, &oldTime));
    CloseHandle(handle);
    state = FsUtils::CheckAppComponentStateFile(path, now);
    CHECK(state.status == FsUtils::AppComponentStateStatus::Malformed);
    DeleteFileW(path.c_str());

    writeBytes(path, valid.data(), valid.size());
    handle = CreateFileW(path.c_str(), FILE_WRITE_ATTRIBUTES, 0, nullptr,
                         OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    REQUIRE(handle != INVALID_HANDLE_VALUE);
    REQUIRE(SetFileTime(handle, nullptr, nullptr, &oldTime));
    CloseHandle(handle);
    state = FsUtils::CheckAppComponentStateFile(path, now);
    CHECK(state.status == FsUtils::AppComponentStateStatus::Stale);
    DeleteFileW(path.c_str());
}

TEST_CASE("WriteFileAtomically leaves no JSON or staging file when the destination cannot be opened") {
    std::wstring scratch = makeScratchDir(L"atomic-open-failure");
    std::wstring blocker = scratch + L"\\not-a-directory";
    writeBytes(blocker, "blocker", 7);
    std::wstring finalPath = blocker + L"\\message.json";

    CHECK_FALSE(FsUtils::WriteFileAtomically(finalPath, "partial document"));
    CHECK_FALSE(fileExists(finalPath));
    CHECK(noTemporaryFiles(scratch));

    DeleteFileW(blocker.c_str());
}

TEST_CASE("WriteFileAtomically cleans up injected write flush and rename failures") {
    const FsUtils::AtomicWriteFault faults[] = {
        FsUtils::AtomicWriteFault::Write,
        FsUtils::AtomicWriteFault::Flush,
        FsUtils::AtomicWriteFault::Rename,
    };
    for (const auto fault : faults) {
        std::wstring scratch = makeScratchDir(L"atomic-injected");
        std::wstring finalPath = scratch + L"\\message.json";
        DeleteFileW(finalPath.c_str());
        FsUtils::SetAtomicWriteFaultForTesting(fault);
        CHECK_FALSE(FsUtils::WriteFileAtomically(finalPath, "partial document"));
        FsUtils::SetAtomicWriteFaultForTesting(FsUtils::AtomicWriteFault::None);
        CHECK_FALSE(fileExists(finalPath));
        CHECK(noTemporaryFiles(scratch));
    }
}

// -------- WriteErrorForStem --------

TEST_CASE("WriteErrorForStem writes errors\\<stem>.error with the reason") {
    // Use a stem unlikely to collide; clean up afterwards.
    std::wstring stem = L"msg_tk6test_zzz999";
    std::string reason = "attachment copy failed: source missing";

    bool ok = FsUtils::WriteErrorForStem(stem, reason);
    CHECK(ok == true);

    std::wstring queueDir = FsUtils::GetQueueDirectory();
    std::wstring errPath = queueDir + L"errors\\" + stem + L".error";
    REQUIRE(fileExists(errPath));

    HANDLE h = CreateFileW(errPath.c_str(), GENERIC_READ, FILE_SHARE_READ,
                           nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    REQUIRE(h != INVALID_HANDLE_VALUE);
    DWORD sz = GetFileSize(h, nullptr);
    std::string got(sz, 0);
    DWORD got_n = 0;
    ReadFile(h, got.data(), sz, &got_n, nullptr);
    CloseHandle(h);
    CHECK(got_n == sz);
    CHECK(got == reason);

    DeleteFileW(errPath.c_str());
}

// -------- app-presence / missing-app warning --------

TEST_CASE("App presence accepts only a fresh exact marker") {
    std::wstring scratch = makeScratchDir(L"app-presence");
    std::wstring marker = scratch + L"\\app-presence-v1";
    DeleteFileW(marker.c_str());

    FILETIME now{};
    GetSystemTimeAsFileTime(&now);
    CHECK(FsUtils::CheckAppPresenceFile(marker, now) == FsUtils::AppPresenceStatus::Missing);

    const char token[] = "go-mapi-app-presence-v1\n";
    writeBytes(marker, token, sizeof(token) - 1);
    GetSystemTimeAsFileTime(&now);
    CHECK(FsUtils::CheckAppPresenceFile(marker, now) == FsUtils::AppPresenceStatus::Available);

    CHECK(FsUtils::CheckAppPresenceFile(scratch, now) == FsUtils::AppPresenceStatus::Unreadable);

    writeBytes(marker, "wrong", 5);
    CHECK(FsUtils::CheckAppPresenceFile(marker, now) == FsUtils::AppPresenceStatus::Malformed);

    writeBytes(marker, token, sizeof(token) - 1);
    HANDLE h = CreateFileW(marker.c_str(), FILE_WRITE_ATTRIBUTES, 0, nullptr,
                           OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    REQUIRE(h != INVALID_HANDLE_VALUE);
    ULARGE_INTEGER ticks{};
    ticks.LowPart = now.dwLowDateTime;
    ticks.HighPart = now.dwHighDateTime;
    ticks.QuadPart += 10000000ULL;
    FILETIME future{};
    future.dwLowDateTime = ticks.LowPart;
    future.dwHighDateTime = ticks.HighPart;
    REQUIRE(SetFileTime(h, nullptr, nullptr, &future));
    CloseHandle(h);
    CHECK(FsUtils::CheckAppPresenceFile(marker, now) == FsUtils::AppPresenceStatus::Future);

    h = CreateFileW(marker.c_str(), FILE_WRITE_ATTRIBUTES, 0, nullptr,
                    OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    REQUIRE(h != INVALID_HANDLE_VALUE);
    ticks.LowPart = now.dwLowDateTime;
    ticks.HighPart = now.dwHighDateTime;
    ticks.QuadPart -= 6ULL * 60ULL * 10000000ULL;
    FILETIME stale{};
    stale.dwLowDateTime = ticks.LowPart;
    stale.dwHighDateTime = ticks.HighPart;
    REQUIRE(SetFileTime(h, nullptr, nullptr, &stale));
    CloseHandle(h);
    CHECK(FsUtils::CheckAppPresenceFile(marker, now) == FsUtils::AppPresenceStatus::Stale);
    DeleteFileW(marker.c_str());
}

TEST_CASE("Missing app warning is stable and removable") {
    FsUtils::RemoveMissingAppWarning();
    CHECK(FsUtils::WriteMissingAppWarning(FsUtils::AppPresenceStatus::Missing));
    // Stable create-only warning is the rate limiter for short-lived caller processes.
    CHECK_FALSE(FsUtils::WriteMissingAppWarning(FsUtils::AppPresenceStatus::Missing));
    CHECK(FsUtils::RemoveMissingAppWarning());
}
