---
phase: 01-foundation-signpath-application
plan: 03
type: execute
wave: 1
depends_on: []
files_modified:
  - src/native-host/gmail.go
autonomous: true
requirements: [FOUND-03]

must_haves:
  truths:
    - "GmailClient struct has a baseURL field that defaults to https://www.googleapis.com/gmail/v1/users/me"
    - "All HTTP requests in gmail.go use c.baseURL instead of the package-level gmailAPIBase constant"
    - "Existing callers of NewGmailClient(token) continue to work unchanged (backwards compatible)"
    - "A new constructor or override path exists so tests and FOUND-04 CLI plumbing can inject an httptest.Server URL"
  artifacts:
    - path: "src/native-host/gmail.go"
      provides: "GmailClient with injectable baseURL"
      contains: "baseURL"
  key_links:
    - from: "GmailClient.CreateDraft"
      to: "GmailClient.baseURL"
      via: "HTTP request URL construction"
      pattern: "c\\.baseURL|gc\\.baseURL"
---

<objective>
Add a `baseURL string` field to `GmailClient` so tests can point it at an `httptest.Server` instead of the real Gmail API, and so Phase 1's FOUND-04 can plumb a `--gmail-api-base` CLI flag through to the client. Existing callers of `NewGmailClient(token)` must continue to work unchanged.

Purpose: Unblocks GOTEST-01 in Phase 4 (httptest.Server-based Gmail client tests) and E2E-02 in Phase 4 (mock Gmail server injection). Without this injection point, tests have to monkey-patch the package-level constant.
Output: A `GmailClient.baseURL` field, a constructor that accepts an optional override, and all internal HTTP calls using the field instead of the constant.
</objective>

<execution_context>
This plan implements FOUND-03 from REQUIREMENTS.md. Decisions are locked in `01-CONTEXT.md` section `### FOUND-03 (GmailClient baseURL injection)`:
- Add `baseURL string` field to `GmailClient` struct in `src/native-host/gmail.go`
- Default: `"https://www.googleapis.com/gmail/v1/users/me"` (the current value of `gmailAPIBase` — keep the existing constant as the default value assigned in `NewGmailClient`)
- Constructor: extend `NewGmailClient` to accept an optional base URL override, OR add a separate `NewGmailClientWithBase` — pick whichever keeps existing callers unchanged without variadic surprises
- All internal HTTP calls use `c.baseURL` instead of the package constant
- **No new tests in this phase** — GOTEST-01 in Phase 4 consumes the injection point

**Implementation choice (Claude's discretion per CONTEXT.md):** Use a dedicated `NewGmailClientWithBase(token, baseURL string)` constructor. This avoids variadic surprises in `NewGmailClient(token string)` that would silently accept `NewGmailClient(token, "", "extra")` without error. Keep the primary `NewGmailClient(token string)` calling into `NewGmailClientWithBase(token, gmailAPIBase)` internally so there is a single code path.
</execution_context>

<context>
@.planning/PROJECT.md
@.planning/phases/01-foundation-signpath-application/01-CONTEXT.md
@src/native-host/gmail.go
@src/native-host/main.go

<interfaces>
<!-- Current state of gmail.go — extracted so the executor does not need to re-scavenge -->

From src/native-host/gmail.go lines 16-33 — current struct and constructor:
```go
const (
    gmailAPIBase = "https://www.googleapis.com/gmail/v1/users/me"
    maxFileSize  = 25 * 1024 * 1024 // 25MB Gmail limit
)

type GmailClient struct {
    httpClient *http.Client
    token      string
}

func NewGmailClient(token string) *GmailClient {
    return &GmailClient{
        httpClient: &http.Client{},
        token:      token,
    }
}
```

From src/native-host/gmail.go line 61 — the only place the constant is used in an HTTP path:
```go
url := fmt.Sprintf("%s/drafts", gmailAPIBase)
```

From src/native-host/main.go line 127 — the existing caller of NewGmailClient:
```go
client := NewGmailClient(msg.Token)
```
This caller must keep working exactly as-is. FOUND-04 (a later plan) will switch it to a path that uses the injected base URL when the CLI flag is set.
</interfaces>
</context>

<tasks>

<task type="auto" tdd="false">
  <name>Task 1: Add baseURL field and NewGmailClientWithBase constructor</name>
  <files>src/native-host/gmail.go</files>
  <read_first>
    - src/native-host/gmail.go (full file — especially lines 16-89, the const declaration through CreateDraft)
    - src/native-host/main.go (confirm the only caller is line 127 `NewGmailClient(msg.Token)` — do NOT change this file in this task; Plan 04 will update it)
    - Check that no test file currently constructs a GmailClient: grep for `NewGmailClient` across `src/native-host/`
  </read_first>
  <action>
    Apply three changes to `src/native-host/gmail.go`:

    **Change 1 — Add `baseURL` field to the struct:**
    ```go
    type GmailClient struct {
        httpClient *http.Client
        token      string
        baseURL    string   // FOUND-03: injection point for tests and FOUND-04 CLI flag; defaults to gmailAPIBase
    }
    ```

    **Change 2 — Add a new `NewGmailClientWithBase` constructor and route the existing `NewGmailClient` through it:**
    ```go
    // NewGmailClient creates a Gmail API client with the default base URL.
    // For tests or alternate endpoints, use NewGmailClientWithBase.
    func NewGmailClient(token string) *GmailClient {
        return NewGmailClientWithBase(token, gmailAPIBase)
    }

    // NewGmailClientWithBase creates a Gmail API client with an explicit base URL.
    // Used by tests (httptest.Server) and by the native host when --gmail-api-base
    // is passed on the command line (FOUND-04).
    // If baseURL is empty, the default gmailAPIBase is used.
    func NewGmailClientWithBase(token, baseURL string) *GmailClient {
        if baseURL == "" {
            baseURL = gmailAPIBase
        }
        return &GmailClient{
            httpClient: &http.Client{},
            token:      token,
            baseURL:    baseURL,
        }
    }
    ```

    **Change 3 — Switch the HTTP path construction in `CreateDraft` to use `gc.baseURL` instead of the package constant:**
    ```go
    url := fmt.Sprintf("%s/drafts", gc.baseURL)
    ```

    **Scope discipline:**
    - Do NOT remove the `gmailAPIBase` const — it stays as the default value in `NewGmailClientWithBase`
    - Do NOT change the `CreateDraft` function signature
    - Do NOT add HTTP timeouts (CONCERNS.md flagged this, but it is out of scope for FOUND-03 — scope discipline)
    - Do NOT add retry logic (also out of scope)
    - Do NOT add new tests (GOTEST-01 is Phase 4)
    - Do NOT touch `main.go` in this plan — Plan 04 (FOUND-04) owns that edit
    - Do NOT rename any existing methods or fields

    After the change, grep must confirm: exactly one use of `gmailAPIBase` remains in the file (as the default value argument inside `NewGmailClientWithBase` and/or the `if baseURL == ""` branch), and zero uses of `gmailAPIBase` in HTTP path construction.
  </action>
  <verify>
    <automated>cd src/native-host && go build ./... && go vet ./... && go test ./...</automated>
  </verify>
  <acceptance_criteria>
    - `src/native-host/gmail.go` `GmailClient` struct has a `baseURL string` field (grep: `grep -A 5 "type GmailClient struct" src/native-host/gmail.go | grep "baseURL"` matches)
    - A `NewGmailClientWithBase(token, baseURL string) *GmailClient` function exists (grep: `grep -n "func NewGmailClientWithBase" src/native-host/gmail.go` returns exactly 1 match)
    - The existing `NewGmailClient(token string)` function still exists with the same signature (grep: `grep -n "^func NewGmailClient(token string)" src/native-host/gmail.go` returns exactly 1 match)
    - `NewGmailClient` delegates to `NewGmailClientWithBase` (grep: `grep -A 2 "^func NewGmailClient(token string)" src/native-host/gmail.go | grep "NewGmailClientWithBase"` matches)
    - `CreateDraft` uses `gc.baseURL` in URL construction (grep: `grep -n "gc.baseURL" src/native-host/gmail.go` returns at least 1 match)
    - The package constant is NOT used in any HTTP URL construction (grep: `grep -n "gmailAPIBase" src/native-host/gmail.go | grep -v "^[^:]*:[^:]*//\|const\|= gmailAPIBase\|baseURL = gmailAPIBase"` shows only the const declaration and default-assignment uses, no `fmt.Sprintf`/URL construction)
    - `go build ./...` succeeds
    - `go vet ./...` clean
    - `go test ./src/native-host/...` passes (existing tests, no new tests added)
    - `main.go` is unchanged in this plan — diff shows zero lines modified in `src/native-host/main.go`
  </acceptance_criteria>
  <done>
    GmailClient has injectable baseURL, both constructors exist, CreateDraft uses the injected value, no HTTP timeouts or retry logic added, no tests added, main.go untouched.
  </done>
</task>

</tasks>

<verification>
- `go build ./src/native-host/...` succeeds
- `go vet ./src/native-host/...` clean
- `go test ./src/native-host/...` passes all existing tests
- Existing caller `NewGmailClient(msg.Token)` in main.go continues to compile and run
- The `gmailAPIBase` constant is retained as the default value
</verification>

<success_criteria>
- `GmailClient.baseURL` field exists and defaults to the current Gmail API base URL
- `NewGmailClientWithBase(token, baseURL string)` constructor exists as the primary constructor
- `NewGmailClient(token)` delegates to it, preserving backwards compat
- All HTTP URL construction in gmail.go uses `gc.baseURL` instead of the package constant
- No new tests in this phase (GOTEST-01 consumes this in Phase 4)
- No timeout or retry logic added (out of scope)
</success_criteria>

<output>
After completion, create `.planning/phases/01-foundation-signpath-application/01-03-SUMMARY.md` documenting:
- The exact diff to gmail.go
- The chosen constructor pattern (NewGmailClientWithBase separate function, per CONTEXT.md's "Claude's choice")
- Confirmation that main.go was not touched
- Confirmation that gmailAPIBase is retained as the default value
</output>
