#define DOCTEST_CONFIG_IMPLEMENT_WITH_MAIN
#include "doctest.h"

#include "fs_utils.h"
#include "json_writer.h"

#include <windows.h>

#include <cstring>
#include <fstream>
#include <regex>
#include <string>

using namespace go_mapi;

namespace {

std::string ReadFixture(const char* name) {
    std::ifstream file(std::string(GO_MAPI_QUEUE_FIXTURE_DIR) + "/" + name,
                       std::ios::binary);
    if (!file.is_open()) return "";
    return std::string(std::istreambuf_iterator<char>(file), {});
}

bool StringField(const std::string& json, const char* key, std::string* value = nullptr) {
    const std::regex field("\\\"" + std::string(key) + "\\\"\\s*:\\s*\\\"([^\\\"]*)\\\"");
    std::smatch match;
    if (!std::regex_search(json, match, field)) return false;
    if (value) *value = match[1].str();
    return true;
}

bool HasArrayField(const std::string& json, const char* key) {
    return std::regex_search(json, std::regex("\\\"" + std::string(key) + "\\\"\\s*:\\s*\\["));
}

bool HasObjectField(const std::string& json, const char* key) {
    return std::regex_search(json, std::regex("\\\"" + std::string(key) + "\\\"\\s*:\\s*\\{"));
}

bool IsQueueV1Descriptor(const std::string& json) {
    // This deliberately validates schema semantics rather than fixture text:
    // every language consumes the same files, while native producer output is
    // tested against the identical required v1 contract.
    if (json.empty() || json.front() != '{' || json.find("\"version\"") == std::string::npos ||
        !std::regex_search(json, std::regex("\\\"version\\\"\\s*:\\s*1(?:[^0-9]|$)"))) {
        return false;
    }
    std::string timestamp;
    std::string bodyFormat;
    if (!StringField(json, "timestamp", &timestamp) ||
        !std::regex_match(timestamp, std::regex("[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]+)?Z")) ||
        !StringField(json, "bodyFormat", &bodyFormat) ||
        (bodyFormat != "plain" && bodyFormat != "html") ||
        !HasObjectField(json, "recipients") || !HasArrayField(json, "attachments")) {
        return false;
    }
    // A descriptor that declares attachments must provide a staged path for
    // each attachment object; the invalid fixture intentionally violates this.
    if (std::regex_search(json, std::regex("\\\"filename\\\"\\s*:\\s*\\\"[^\\\"]+\\\"")) &&
        !std::regex_search(json, std::regex("\\\"path\\\"\\s*:\\s*\\\"[^\\\"]+\\\""))) {
        return false;
    }
    return true;
}

bool HasNoTempSibling(const std::wstring& finalPath) {
    const size_t slash = finalPath.find_last_of(L"\\/");
    if (slash == std::wstring::npos) return false;
    const std::wstring directory = finalPath.substr(0, slash);
    WIN32_FIND_DATAW entry{};
    HANDLE find = FindFirstFileW((directory + L"\\*.tmp").c_str(), &entry);
    if (find == INVALID_HANDLE_VALUE) return true;
    FindClose(find);
    return false;
}

void WriteExistingFile(const std::wstring& path, const char* content) {
    HANDLE file = CreateFileW(path.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS,
                              FILE_ATTRIBUTE_NORMAL, nullptr);
    REQUIRE(file != INVALID_HANDLE_VALUE);
    DWORD written = 0;
    REQUIRE(WriteFile(file, content, static_cast<DWORD>(strlen(content)), &written, nullptr));
    CloseHandle(file);
}

std::string ReadFile(const std::wstring& path) {
    std::ifstream file(path.c_str(), std::ios::binary);
    return std::string(std::istreambuf_iterator<char>(file), {});
}

MailMessage CanonicalMessage() {
    MailMessage message;
    message.subject = "Quarterly report";
    message.body = "Please review the attached report.";
    message.bodyFormat = "plain";
    message.toRecipients.push_back({"Ada Lovelace", "ada@example.com"});
    message.originApp = "WINWORD.EXE";
    return message;
}

}  // namespace

TEST_CASE("queue-v1 native conformance validates shared valid and invalid fixtures") {
    CHECK(IsQueueV1Descriptor(ReadFixture("plain-message.json")));
    CHECK(IsQueueV1Descriptor(ReadFixture("html-with-attachment.json")));
    CHECK_FALSE(IsQueueV1Descriptor(ReadFixture("invalid-unsupported-version.json")));
    CHECK_FALSE(IsQueueV1Descriptor(ReadFixture("invalid-timestamp.json")));
    CHECK_FALSE(IsQueueV1Descriptor(ReadFixture("invalid-attachment.json")));
}

TEST_CASE("JsonWriter produces a bare queue-v1 descriptor with canonical fields") {
    const std::string json = JsonWriter::MessageToJson(CanonicalMessage());
    REQUIRE_FALSE(json.empty());
    CHECK(IsQueueV1Descriptor(json));
    std::string subject;
    std::string bodyFormat;
    CHECK(StringField(json, "subject", &subject));
    CHECK(subject == "Quarterly report");
    CHECK(StringField(json, "bodyFormat", &bodyFormat));
    CHECK(bodyFormat == "plain");
}

TEST_CASE("JsonWriter leaves an existing final queue document untouched when publish rename fails") {
    REQUIRE(FsUtils::EnsureOutputDirectory());
    const std::wstring stem = L"msg_queue_v1_collision_" + std::to_wstring(GetCurrentProcessId());
    const std::wstring finalPath = FsUtils::GetQueueDirectory() + stem + L".json";
    DeleteFileW(finalPath.c_str());
    WriteExistingFile(finalPath, "existing queue document");

    CHECK(JsonWriter::WriteMailToFileWithStem(CanonicalMessage(), stem).empty());
    CHECK(ReadFile(finalPath) == "existing queue document");
    CHECK(HasNoTempSibling(finalPath));

    DeleteFileW(finalPath.c_str());
}
