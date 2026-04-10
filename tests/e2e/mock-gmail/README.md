# mock-gmail

Stdlib Go mock Gmail API server used by the Phase 4 Playwright E2E tests
(`happy-path.spec.ts`). Launched as a child process by the test harness.

## Protocol

- `POST /drafts` with `Authorization: Bearer <token>` → `200 {"id":"mock-draft-id"}`
- `GET /healthz` → `200 ok`
- `GET /__count` → `200 {"drafts":N}` — call counter for test assertions

On startup, prints `LISTENING http://127.0.0.1:<port>` to stdout so the
harness can parse the resolved URL. Pass `--port 0` (default) to let the
OS assign a port, or `--port <n>` to pin one.

## Run

```
go build -o mock-gmail ./...
./mock-gmail --port 0
```

## Integration with go-mapi

The native host is launched with
`--gmail-api-base http://127.0.0.1:<port>` (FOUND-04 flag) so
`GmailClient.CreateDraft` posts to this mock instead of the real Gmail
API. Never exposes TLS or any external binding.
