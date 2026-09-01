# queue-v1 filesystem contract

`queue-v1` is the runtime boundary between the machine-wide MAPI interceptor
and the per-user go-mapi Wails application. It is deliberately independent of
the components' release versions: each component can be released separately as
long as it continues to support this contract.

This document defines the on-disk protocol. It does not define the historical
native-messaging envelopes in `tests/protocol-fixtures/*.json`; those files
have a top-level `type`/`id`/`data` envelope and remain fixtures for the legacy
native-host protocol. Queue-v1 payloads are the *bare* `MailMessage` JSON
objects in `tests/protocol-fixtures/queue-v1/`.

## Location and ownership

For the interactive Windows user that invoked MAPI, the queue root is:

```
%LOCALAPPDATA%\go-mapi\queue\
```

The interceptor is registered machine-wide, but it writes only to that
calling user's `%LOCALAPPDATA%`; it must not write a shared HKLM or service
queue. The Wails app for the same user watches that directory. A user without
the app currently has no queue consumer.

The interceptor owns the producer side. The Wails app owns ingestion, error
handling, and any later delivery/cleanup policy. Neither component obtains
elevation merely to use the queue.

## Publication

Each message has an opaque, unique `stem`. Its published descriptor is
`<stem>.json`; if it has attachments, they live in the sibling directory
`<stem>\`.

1. The producer creates/copies every attachment into `<stem>\` and records
   the resulting paths and sizes in the descriptor.
2. The producer writes the complete UTF-8 JSON to a temporary, non-`.json`
   name in the same queue directory.
3. The producer atomically renames that file to `<stem>.json`. The rename is
   the publication event.
4. Consumers process only published `*.json` descriptors and must ignore
   temporary files and attachment directories.

If copying or publishing fails, no descriptor may be published. Producers may
write diagnostic files under `queue\errors\`, which are not messages and must
not be ingested as such. The current implementation's debounce/retry is a
compatibility guard for older non-atomic writers; new producers must use the
publication rule above.

## Descriptor schema

The published file is a JSON object encoded as UTF-8, with no envelope.
Unknown fields must be ignored so that additive changes remain compatible.
Required fields are marked **required**.

| Field | Type | Meaning |
| --- | --- | --- |
| `version` | integer | **Required.** Queue schema version. Queue-v1 is `1`. |
| `timestamp` | string | **Required.** UTC ISO 8601/RFC 3339 time at interception. |
| `subject` | string | Subject; may be empty. |
| `body` | string | Body; may be empty. |
| `bodyFormat` | string | **Required.** Exactly `plain` or `html`. |
| `recipients` | object | Recipient collections, with `to`, `cc`, and `bcc` arrays. Empty arrays are valid. |
| `recipients.*[]` | object | A recipient has `name` (string) and **required non-empty** `address` (string). |
| `attachments` | array | Attachment descriptors; empty is valid. |
| `attachments[]` | object | `filename` (string), `path` (string), and `size` (integer bytes). A non-empty `path` refers to the producer-owned stable copy below `<stem>\`. |
| `originApp` | string | Name of the process which made the MAPI call; may be empty. |
| `interceptorVersion` | string | Producer component version from `src/interceptor/interceptor-version.txt`; optional for backward compatibility. |

`hostVersion` is intentionally not part of the on-disk queue-v1 contract. It
is app-local diagnostic state added after ingestion, if needed.

## Compatibility and fixtures

`version: 1` is the compatibility discriminator, not an interceptor or app
release number. A queue-v1 consumer must reject a missing or zero version and
must not treat another version as v1 without an explicit compatibility rule.
Producers must emit all required v1 fields.

The canonical bare fixtures are:

- `tests/protocol-fixtures/queue-v1/plain-message.json`
- `tests/protocol-fixtures/queue-v1/html-with-attachment.json`

They have stable values for deterministic contract tests. Their attachment
paths are illustrative Windows paths, not files expected to exist on the host
running a parser test.
