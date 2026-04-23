#include "json_writer.h"
#include "fs_utils.h"
#include <sstream>
#include <iomanip>
#include <ctime>
#include <chrono>
#include <windows.h>

namespace go_mapi {

std::string JsonWriter::EscapeJsonString(const std::string& str) {
    std::string result;
    result.reserve(str.length() + 16);  // Reserve some extra space

    for (char c : str) {
        switch (c) {
        case '"':
            result += "\\\"";
            break;
        case '\\':
            result += "\\\\";
            break;
        case '\b':
            result += "\\b";
            break;
        case '\f':
            result += "\\f";
            break;
        case '\n':
            result += "\\n";
            break;
        case '\r':
            result += "\\r";
            break;
        case '\t':
            result += "\\t";
            break;
        default:
            if (static_cast<unsigned char>(c) < 0x20) {
                // Control character - escape as unicode
                char buf[7];
                snprintf(buf, sizeof(buf), "\\u%04x", static_cast<unsigned char>(c));
                result += buf;
            } else {
                result += c;
            }
        }
    }

    return result;
}

std::string JsonWriter::RecipientArrayToJson(const std::vector<Recipient>& recipients) {
    std::ostringstream oss;
    oss << "[";

    for (size_t i = 0; i < recipients.size(); ++i) {
        if (i > 0) oss << ",";
        oss << "{\"name\":\"" << EscapeJsonString(recipients[i].name)
            << "\",\"address\":\"" << EscapeJsonString(recipients[i].address) << "\"}";
    }

    oss << "]";
    return oss.str();
}

std::string JsonWriter::AttachmentArrayToJson(const std::vector<Attachment>& attachments) {
    std::ostringstream oss;
    oss << "[";

    for (size_t i = 0; i < attachments.size(); ++i) {
        if (i > 0) oss << ",";
        oss << "{\"filename\":\"" << EscapeJsonString(attachments[i].filename)
            << "\",\"path\":\"" << EscapeJsonString(attachments[i].path)
            << "\",\"size\":" << attachments[i].size << "}";
    }

    oss << "]";
    return oss.str();
}

std::string JsonWriter::GetIso8601Timestamp() {
    auto now = std::chrono::system_clock::now();
    auto time_t = std::chrono::system_clock::to_time_t(now);
    auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(now.time_since_epoch()) % 1000;

    struct tm tm_buf;
    gmtime_s(&tm_buf, &time_t);

    std::ostringstream oss;
    oss << std::put_time(&tm_buf, "%Y-%m-%dT%H:%M:%S")
        << '.' << std::setfill('0') << std::setw(3) << ms.count() << "Z";
    return oss.str();
}

#ifndef GO_MAPI_VERSION
#define GO_MAPI_VERSION "0.0.0-dev"
#endif

std::string JsonWriter::MessageToJson(const MailMessage& msg) {
    std::ostringstream oss;

    oss << "{"
        << "\"version\":1,"
        << "\"interceptorVersion\":\"" << GO_MAPI_VERSION << "\","
        << "\"timestamp\":\"" << GetIso8601Timestamp() << "\","
        << "\"subject\":\"" << EscapeJsonString(msg.subject) << "\","
        << "\"body\":\"" << EscapeJsonString(msg.body) << "\","
        << "\"bodyFormat\":\"" << EscapeJsonString(msg.bodyFormat) << "\","
        << "\"recipients\":{"
        << "\"to\":" << RecipientArrayToJson(msg.toRecipients) << ","
        << "\"cc\":" << RecipientArrayToJson(msg.ccRecipients) << ","
        << "\"bcc\":" << RecipientArrayToJson(msg.bccRecipients)
        << "},"
        << "\"attachments\":" << AttachmentArrayToJson(msg.attachments) << ","
        << "\"originApp\":\"" << EscapeJsonString(msg.originApp) << "\""
        << "}";

    return oss.str();
}

std::wstring JsonWriter::WriteMailToFile(const MailMessage& msg) {
    // Ensure output directory exists
    if (!FsUtils::EnsureOutputDirectory()) {
        return L"";
    }

    // Generate unique filename
    std::wstring filename = FsUtils::GenerateUniqueFilename();
    std::wstring outputDir = FsUtils::GetQueueDirectory();
    std::wstring fullPath = outputDir + filename;

    // Serialize message to JSON
    std::string jsonContent = MessageToJson(msg);

    // Write to file
    if (FsUtils::WriteFile(fullPath, jsonContent)) {
        return fullPath;
    }

    return L"";
}

} // namespace go_mapi
