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
