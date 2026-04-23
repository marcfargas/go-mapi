#pragma once

#include <string>
#include <vector>
#include <cstdint>

namespace go_mapi {

struct Recipient {
    std::string name;
    std::string address;
};

struct Attachment {
    std::string filename;
    std::string path;
    uint32_t size;
};

struct MailMessage {
    std::string subject;
    std::string body;
    std::string bodyFormat;  // "plain" or "html"
    std::vector<Recipient> toRecipients;
    std::vector<Recipient> ccRecipients;
    std::vector<Recipient> bccRecipients;
    std::vector<Attachment> attachments;
    std::string originApp;  // e.g., "explorer.exe"
};

class JsonWriter {
public:
    // Serialize a MailMessage to JSON string
    static std::string MessageToJson(const MailMessage& msg);

    // Write a MailMessage to a JSON file in %LOCALAPPDATA%\go-mapi\queue\
    // Returns the full path to the created file, empty string on failure
    static std::wstring WriteMailToFile(const MailMessage& msg);

    // QUICK-260423-tk6 — variant that lets the caller supply the stem (no
    // extension). Used by the DLL orchestration layer so the JSON file and
    // its sibling attachments dir share a deterministic identity.
    static std::wstring WriteMailToFileWithStem(const MailMessage& msg,
                                                const std::wstring& stem);

private:
    // Escape JSON string values (quotes, backslashes, newlines, etc.)
    static std::string EscapeJsonString(const std::string& str);

    // Helper to write JSON array of recipients
    static std::string RecipientArrayToJson(const std::vector<Recipient>& recipients);

    // Helper to write JSON array of attachments
    static std::string AttachmentArrayToJson(const std::vector<Attachment>& attachments);

    // Get current ISO8601 timestamp
    static std::string GetIso8601Timestamp();
};

} // namespace go_mapi
