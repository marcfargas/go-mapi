// CPPTEST-02: unit tests for message_converter.
//
// Exercises the pure ANSI/Wide MAPI → MailMessage conversion paths that
// were extracted into message_converter.{h,cpp} in FOUND-05. Links against
// the message_converter_obj OBJECT library so the test binary uses the
// exact same translation units as the production DLL.
//
// Note: the C++ message_converter does NOT strip SMTP:/mailto: prefixes —
// that is the Go native host's responsibility in watcher.go:normalizeAddress.
// The "preserves SMTP prefix verbatim" test asserts pass-through, which is
// the load-bearing guarantee for the cross-layer contract.
//
// Note: ConvertAnsiMessage uses CP_ACP for subject/body decoding, which
// depends on the system's active ANSI code page. ANSI-path tests therefore
// only use pure ASCII inputs. Non-ASCII coverage lives on the Wide path
// where WideToUtf8 uses CP_UTF8 deterministically.

#define DOCTEST_CONFIG_IMPLEMENT_WITH_MAIN
#include "doctest.h"

#include "message_converter.h"
#include "mapi_types.h"
#include "json_writer.h"

#include <cstring>
#include <string>

using namespace go_mapi;
using namespace go_mapi::message_converter;

// ---------- String conversion helpers ----------

TEST_CASE("WideToUtf8 handles nullptr") {
    CHECK(WideToUtf8(nullptr) == "");
}

TEST_CASE("WideToUtf8 handles empty string") {
    CHECK(WideToUtf8(L"") == "");
}

TEST_CASE("WideToUtf8 converts ASCII") {
    CHECK(WideToUtf8(L"hello") == "hello");
}

TEST_CASE("WideToUtf8 converts non-ASCII UTF-16 to UTF-8") {
    // "résumé" — expected UTF-8 byte sequence:
    //   r  é    s  u  m  é
    //   72 c3a9 73 75 6d c3a9
    std::string got = WideToUtf8(L"r\u00e9sum\u00e9");
    REQUIRE(got.size() == 8);
    CHECK(static_cast<unsigned char>(got[0]) == 0x72);
    CHECK(static_cast<unsigned char>(got[1]) == 0xc3);
    CHECK(static_cast<unsigned char>(got[2]) == 0xa9);
    CHECK(static_cast<unsigned char>(got[3]) == 0x73);
    CHECK(static_cast<unsigned char>(got[4]) == 0x75);
    CHECK(static_cast<unsigned char>(got[5]) == 0x6d);
    CHECK(static_cast<unsigned char>(got[6]) == 0xc3);
    CHECK(static_cast<unsigned char>(got[7]) == 0xa9);
}

TEST_CASE("AnsiToUtf8 handles nullptr") {
    CHECK(AnsiToUtf8(nullptr) == "");
}

TEST_CASE("AnsiToUtf8 handles empty string") {
    CHECK(AnsiToUtf8("") == "");
}

TEST_CASE("AnsiToUtf8 passes through ASCII") {
    CHECK(AnsiToUtf8("hello@example.com") == "hello@example.com");
}

TEST_CASE("FilenameFromPath forward slash") {
    CHECK(FilenameFromPath("a/b/c.txt") == "c.txt");
}

TEST_CASE("FilenameFromPath backslash") {
    CHECK(FilenameFromPath("a\\b\\c.txt") == "c.txt");
}

TEST_CASE("FilenameFromPath mixed separators") {
    CHECK(FilenameFromPath("C:/tmp\\sub/report.pdf") == "report.pdf");
}

TEST_CASE("FilenameFromPath no separator returns input") {
    CHECK(FilenameFromPath("file.txt") == "file.txt");
}

TEST_CASE("FilenameFromPath trailing separator returns input unchanged") {
    // Current behavior: a trailing separator causes the substring bound
    // check `pos + 1 < path.size()` to fail, so the full path is returned.
    // Lock this behavior to catch unintended refactors.
    CHECK(FilenameFromPath("a/b/") == "a/b/");
}

TEST_CASE("ConvertSendDocumentsAttachments parses custom delimiter and display names") {
    std::vector<Attachment> attachments;
    REQUIRE(ConvertSendDocumentsAttachments("|", "C:\\temp\\one.txt|C:\\temp\\two.pdf",
                                            "first.txt|renamed.pdf", attachments));
    REQUIRE(attachments.size() == 2);
    CHECK(attachments[0].path == "C:\\temp\\one.txt");
    CHECK(attachments[0].filename == "first.txt");
    CHECK(attachments[1].path == "C:\\temp\\two.pdf");
    CHECK(attachments[1].filename == "renamed.pdf");
}

TEST_CASE("ConvertSendDocumentsAttachments falls back for omitted and empty names") {
    std::vector<Attachment> attachments;
    REQUIRE(ConvertSendDocumentsAttachments(";", "C:\\temp\\one.txt;C:\\temp\\two.pdf",
                                            ";", attachments));
    REQUIRE(attachments.size() == 2);
    CHECK(attachments[0].filename == "one.txt");
    CHECK(attachments[1].filename == "two.pdf");
}

TEST_CASE("ConvertSendDocumentsAttachments ignores extra names and falls back for missing names") {
    std::vector<Attachment> attachments;
    REQUIRE(ConvertSendDocumentsAttachments(";", "C:\\temp\\one.txt;C:\\temp\\two.pdf",
                                            "shown.txt", attachments));
    REQUIRE(attachments.size() == 2);
    CHECK(attachments[0].filename == "shown.txt");
    CHECK(attachments[1].filename == "two.pdf");

    REQUIRE(ConvertSendDocumentsAttachments(";", "C:\\temp\\one.txt",
                                            "shown.txt;unused.txt", attachments));
    REQUIRE(attachments.size() == 1);
    CHECK(attachments[0].filename == "shown.txt");
}

TEST_CASE("ConvertSendDocumentsAttachments accepts empty paths as the caller no-op input") {
    std::vector<Attachment> attachments;
    CHECK(ConvertSendDocumentsAttachments(";", nullptr, nullptr, attachments));
    CHECK(attachments.empty());
    CHECK(ConvertSendDocumentsAttachments(";", "", nullptr, attachments));
    CHECK(attachments.empty());
}

TEST_CASE("ConvertSendDocumentsAttachments accepts a single path without a delimiter") {
    std::vector<Attachment> attachments;
    REQUIRE(ConvertSendDocumentsAttachments(nullptr, "C:\\temp\\only.txt", nullptr, attachments));
    REQUIRE(attachments.size() == 1);
    CHECK(attachments[0].filename == "only.txt");
}

TEST_CASE("ConvertSendDocumentsAttachments rejects malformed paths and duplicate names") {
    std::vector<Attachment> attachments;
    CHECK_FALSE(ConvertSendDocumentsAttachments(";", "C:\\temp\\one.txt;;C:\\temp\\two.txt",
                                                nullptr, attachments));
    CHECK(attachments.empty());
    CHECK_FALSE(ConvertSendDocumentsAttachments(";", "C:\\temp\\one.txt;C:\\temp\\two.txt",
                                                "same.txt;same.txt", attachments));
    CHECK(attachments.empty());
}

// ---------- ConvertAnsiMessage ----------

TEST_CASE("ConvertAnsiMessage handles null fields") {
    MapiMessage msg{};
    msg.lpszSubject = nullptr;
    msg.lpszNoteText = nullptr;
    msg.lpRecips = nullptr;
    msg.nRecipCount = 0;
    msg.lpFiles = nullptr;
    msg.nFileCount = 0;

    MailMessage result = ConvertAnsiMessage(msg);

    CHECK(result.subject == "");
    CHECK(result.body == "");
    CHECK(result.bodyFormat == "plain");
    CHECK(result.toRecipients.empty());
    CHECK(result.ccRecipients.empty());
    CHECK(result.bccRecipients.empty());
    CHECK(result.attachments.empty());
}

TEST_CASE("ConvertAnsiMessage happy path ASCII") {
    char subject[] = "Test Subject";
    char body[] = "Body text";
    char recipName[] = "John";
    char recipAddr[] = "john@example.com";
    char filePath[] = "C:\\tmp\\file.txt";
    char fileName[] = "file.txt";

    MapiRecipDesc recip{};
    recip.ulRecipClass = MAPI_TO;
    recip.lpszName = recipName;
    recip.lpszAddress = recipAddr;

    MapiFileDesc file{};
    file.lpszPathName = filePath;
    file.lpszFileName = fileName;

    MapiMessage msg{};
    msg.lpszSubject = subject;
    msg.lpszNoteText = body;
    msg.nRecipCount = 1;
    msg.lpRecips = &recip;
    msg.nFileCount = 1;
    msg.lpFiles = &file;

    MailMessage result = ConvertAnsiMessage(msg);

    CHECK(result.subject == "Test Subject");
    CHECK(result.body == "Body text");
    CHECK(result.bodyFormat == "plain");
    REQUIRE(result.toRecipients.size() == 1);
    CHECK(result.toRecipients[0].name == "John");
    CHECK(result.toRecipients[0].address == "john@example.com");
    CHECK(result.ccRecipients.empty());
    CHECK(result.bccRecipients.empty());
    REQUIRE(result.attachments.size() == 1);
    CHECK(result.attachments[0].filename == "file.txt");
    CHECK(result.attachments[0].path == "C:\\tmp\\file.txt");
}

TEST_CASE("ConvertAnsiMessage routes recipient classes to to/cc/bcc") {
    char name1[] = "A";
    char addr1[] = "to@x.com";
    char name2[] = "B";
    char addr2[] = "cc@x.com";
    char name3[] = "C";
    char addr3[] = "bcc@x.com";

    MapiRecipDesc recips[3]{};
    recips[0].ulRecipClass = MAPI_TO;
    recips[0].lpszName = name1;
    recips[0].lpszAddress = addr1;
    recips[1].ulRecipClass = MAPI_CC;
    recips[1].lpszName = name2;
    recips[1].lpszAddress = addr2;
    recips[2].ulRecipClass = MAPI_BCC;
    recips[2].lpszName = name3;
    recips[2].lpszAddress = addr3;

    MapiMessage msg{};
    msg.nRecipCount = 3;
    msg.lpRecips = recips;

    MailMessage result = ConvertAnsiMessage(msg);

    REQUIRE(result.toRecipients.size() == 1);
    REQUIRE(result.ccRecipients.size() == 1);
    REQUIRE(result.bccRecipients.size() == 1);
    CHECK(result.toRecipients[0].address == "to@x.com");
    CHECK(result.ccRecipients[0].address == "cc@x.com");
    CHECK(result.bccRecipients[0].address == "bcc@x.com");
}

TEST_CASE("ConvertAnsiMessage preserves SMTP prefix verbatim") {
    // The C++ layer does NOT strip the SMTP: prefix — that is watcher.go's
    // normalizeAddress. Lock the pass-through contract so the cross-layer
    // responsibility stays unambiguous.
    char name[] = "User";
    char addr[] = "SMTP:user@example.com";

    MapiRecipDesc recip{};
    recip.ulRecipClass = MAPI_TO;
    recip.lpszName = name;
    recip.lpszAddress = addr;

    MapiMessage msg{};
    msg.nRecipCount = 1;
    msg.lpRecips = &recip;

    MailMessage result = ConvertAnsiMessage(msg);
    REQUIRE(result.toRecipients.size() == 1);
    CHECK(result.toRecipients[0].address == "SMTP:user@example.com");
}

TEST_CASE("ConvertAnsiMessage promotes email-shaped name to address when address empty") {
    // QUICK-260423-qpx: legacy Simple MAPI callers (Spanish SendEmail-style
    // apps) often populate only lpszName with a bare email and leave
    // lpszAddress NULL. Without a fallback, the Go validator rejects the
    // message with 'recipient to[0] missing address'.
    char name[] = "marc@blegal.eu";
    MapiRecipDesc recip{};
    recip.ulRecipClass = MAPI_TO;
    recip.lpszName = name;
    recip.lpszAddress = nullptr;

    MapiMessage msg{};
    msg.nRecipCount = 1;
    msg.lpRecips = &recip;

    MailMessage result = ConvertAnsiMessage(msg);
    REQUIRE(result.toRecipients.size() == 1);
    CHECK(result.toRecipients[0].address == "marc@blegal.eu");
    CHECK(result.toRecipients[0].name == "");
}

TEST_CASE("ConvertAnsiMessage does NOT promote non-email name") {
    // Guard: only promote when the name actually looks like an email. A plain
    // display name with no address must stay in .name so the Go validator
    // reports the missing address to the user.
    char name[] = "Isabel Perez";
    MapiRecipDesc recip{};
    recip.ulRecipClass = MAPI_TO;
    recip.lpszName = name;
    recip.lpszAddress = nullptr;

    MapiMessage msg{};
    msg.nRecipCount = 1;
    msg.lpRecips = &recip;

    MailMessage result = ConvertAnsiMessage(msg);
    REQUIRE(result.toRecipients.size() == 1);
    CHECK(result.toRecipients[0].address == "");
    CHECK(result.toRecipients[0].name == "Isabel Perez");
}

TEST_CASE("ConvertAnsiMessage keeps name when address is already set") {
    // When both fields are present, pass them through verbatim -- promotion
    // is a fallback, not a rewrite.
    char name[] = "Marc Fargas";
    char addr[] = "marc@blegal.eu";
    MapiRecipDesc recip{};
    recip.ulRecipClass = MAPI_TO;
    recip.lpszName = name;
    recip.lpszAddress = addr;

    MapiMessage msg{};
    msg.nRecipCount = 1;
    msg.lpRecips = &recip;

    MailMessage result = ConvertAnsiMessage(msg);
    REQUIRE(result.toRecipients.size() == 1);
    CHECK(result.toRecipients[0].address == "marc@blegal.eu");
    CHECK(result.toRecipients[0].name == "Marc Fargas");
}

TEST_CASE("ConvertWideMessage promotes email-shaped name to address when address empty") {
    wchar_t name[] = L"marc@blegal.eu";
    MapiRecipDescW recip{};
    recip.ulRecipClass = MAPI_TO;
    recip.lpszName = name;
    recip.lpszAddress = nullptr;

    MapiMessageW msg{};
    msg.nRecipCount = 1;
    msg.lpRecips = &recip;

    MailMessage result = ConvertWideMessage(msg);
    REQUIRE(result.toRecipients.size() == 1);
    CHECK(result.toRecipients[0].address == "marc@blegal.eu");
    CHECK(result.toRecipients[0].name == "");
}

TEST_CASE("ConvertAnsiMessage unknown recipient class routes to TO") {
    char name[] = "X";
    char addr[] = "unknown@x.com";

    MapiRecipDesc recip{};
    recip.ulRecipClass = 99;  // Not TO, CC, or BCC
    recip.lpszName = name;
    recip.lpszAddress = addr;

    MapiMessage msg{};
    msg.nRecipCount = 1;
    msg.lpRecips = &recip;

    MailMessage result = ConvertAnsiMessage(msg);
    REQUIRE(result.toRecipients.size() == 1);
    CHECK(result.toRecipients[0].address == "unknown@x.com");
    CHECK(result.ccRecipients.empty());
    CHECK(result.bccRecipients.empty());
}

TEST_CASE("ConvertAnsiMessage attachment filename fallback from path") {
    char filePath[] = "C:\\tmp\\report.pdf";

    MapiFileDesc file{};
    file.lpszPathName = filePath;
    file.lpszFileName = nullptr;  // Windows often leaves this null

    MapiMessage msg{};
    msg.nFileCount = 1;
    msg.lpFiles = &file;

    MailMessage result = ConvertAnsiMessage(msg);
    REQUIRE(result.attachments.size() == 1);
    CHECK(result.attachments[0].path == "C:\\tmp\\report.pdf");
    CHECK(result.attachments[0].filename == "report.pdf");
}

// ---------- ConvertWideMessage ----------

TEST_CASE("ConvertWideMessage handles null fields") {
    MapiMessageW msg{};
    MailMessage result = ConvertWideMessage(msg);

    CHECK(result.subject == "");
    CHECK(result.body == "");
    CHECK(result.bodyFormat == "plain");
    CHECK(result.toRecipients.empty());
    CHECK(result.ccRecipients.empty());
    CHECK(result.bccRecipients.empty());
    CHECK(result.attachments.empty());
}

TEST_CASE("ConvertWideMessage UTF-16 non-ASCII subject round-trip") {
    wchar_t subject[] = L"H\u00e9llo W\u00f6rld";  // "Héllo Wörld"
    wchar_t body[]    = L"UTF-16 body";

    MapiMessageW msg{};
    msg.lpszSubject = subject;
    msg.lpszNoteText = body;

    MailMessage result = ConvertWideMessage(msg);

    // UTF-8 byte sequence for "Héllo Wörld":
    //   H  é    l  l  o  (sp) W  ö    r  l  d
    //   48 c3a9 6c 6c 6f 20   57 c3b6 72 6c 64
    REQUIRE(result.subject.size() == 13);
    CHECK(static_cast<unsigned char>(result.subject[0]) == 0x48);
    CHECK(static_cast<unsigned char>(result.subject[1]) == 0xc3);
    CHECK(static_cast<unsigned char>(result.subject[2]) == 0xa9);
    CHECK(result.body == "UTF-16 body");
}

TEST_CASE("ConvertWideMessage routes recipient classes") {
    wchar_t name1[] = L"A";
    wchar_t addr1[] = L"to@x.com";
    wchar_t name2[] = L"B";
    wchar_t addr2[] = L"cc@x.com";
    wchar_t name3[] = L"C";
    wchar_t addr3[] = L"bcc@x.com";

    MapiRecipDescW recips[3]{};
    recips[0].ulRecipClass = MAPI_TO;
    recips[0].lpszName = name1;
    recips[0].lpszAddress = addr1;
    recips[1].ulRecipClass = MAPI_CC;
    recips[1].lpszName = name2;
    recips[1].lpszAddress = addr2;
    recips[2].ulRecipClass = MAPI_BCC;
    recips[2].lpszName = name3;
    recips[2].lpszAddress = addr3;

    MapiMessageW msg{};
    msg.nRecipCount = 3;
    msg.lpRecips = recips;

    MailMessage result = ConvertWideMessage(msg);
    REQUIRE(result.toRecipients.size() == 1);
    REQUIRE(result.ccRecipients.size() == 1);
    REQUIRE(result.bccRecipients.size() == 1);
    CHECK(result.toRecipients[0].address == "to@x.com");
    CHECK(result.ccRecipients[0].address == "cc@x.com");
    CHECK(result.bccRecipients[0].address == "bcc@x.com");
}

TEST_CASE("ConvertWideMessage attachment filename fallback from path") {
    wchar_t filePath[] = L"C:\\tmp\\resume.pdf";

    MapiFileDescW file{};
    file.lpszPathName = filePath;
    file.lpszFileName = nullptr;

    MapiMessageW msg{};
    msg.nFileCount = 1;
    msg.lpFiles = &file;

    MailMessage result = ConvertWideMessage(msg);
    REQUIRE(result.attachments.size() == 1);
    CHECK(result.attachments[0].path == "C:\\tmp\\resume.pdf");
    CHECK(result.attachments[0].filename == "resume.pdf");
}

TEST_CASE("ConvertWideMessage unknown recipient class routes to TO") {
    wchar_t name[] = L"X";
    wchar_t addr[] = L"unknown@x.com";

    MapiRecipDescW recip{};
    recip.ulRecipClass = 99;
    recip.lpszName = name;
    recip.lpszAddress = addr;

    MapiMessageW msg{};
    msg.nRecipCount = 1;
    msg.lpRecips = &recip;

    MailMessage result = ConvertWideMessage(msg);
    REQUIRE(result.toRecipients.size() == 1);
    CHECK(result.toRecipients[0].address == "unknown@x.com");
}
