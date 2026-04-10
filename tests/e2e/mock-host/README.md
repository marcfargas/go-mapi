# mock-host

Minimal native-messaging host stub used by the Phase 4 Playwright
install-UX test (`install-ux.spec.ts`). This is NOT a real native host
— it sends exactly one `{"type":"ready","hostVersion":"2.0.0"}` message
on stdout using the Chrome Native Messaging framing (4-byte
little-endian length prefix + JSON), then blocks on stdin until EOF.

Purpose: let the install-UX test register a native-messaging manifest
pointing at something-that-works, triggering the extension's
`MISSING → READY` transition without needing the full go-mapi stack.

## Protocol

Chrome invokes this program with the extension origin URL as argv[1].
The program ignores argv entirely and writes its canned READY message
on startup.

## Run standalone

```
go build -o mock-host ./...
./mock-host
# then type Ctrl+Z on Windows or Ctrl+D on Linux to EOF stdin
```

## Build

```
go build -o mock-host.exe .
```
