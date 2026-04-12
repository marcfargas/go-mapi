---
phase: 01-foundation-signpath-application
plan: 03
subsystem: native-host
tags: [go, gmail-api, http-client, dependency-injection, testability]

# Dependency graph
requires:
  - phase: none
    provides: existing GmailClient with hard-coded gmailAPIBase constant
provides:
  - GmailClient.baseURL field with gmailAPIBase default
  - NewGmailClientWithBase(token, baseURL) constructor for test/CLI injection
  - Backwards-compatible NewGmailClient(token) that routes through the new constructor
affects:
  - 01-04-PLAN (FOUND-04 --gmail-api-base CLI flag plumbing)
  - Phase 4 GOTEST-01 (httptest.Server-based Gmail client unit tests)
  - Phase 4 E2E-02 (mock Gmail server injection for end-to-end tests)

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Dependency injection via explicit constructor variant (NewGmailClientWithBase) instead of variadic or functional options"
    - "Primary constructor delegates to the explicit-base variant to keep a single construction code path"

key-files:
  created: []
  modified:
    - src/native-host/gmail.go

key-decisions:
  - "Chose separate NewGmailClientWithBase(token, baseURL) constructor over variadic NewGmailClient(token, opts...) to avoid variadic-call surprises and keep the zero-arg default obvious at call sites"
  - "Retained the gmailAPIBase package constant as the default value fed into NewGmailClientWithBase, giving a single source of truth for the production URL and an obvious fallback when an empty override is passed"
  - "Left src/native-host/main.go untouched in this plan; FOUND-04 owns the CLI-flag plumbing edit to the sole caller"

patterns-established:
  - "Injection via dedicated alt constructor: primary constructor stays zero-config for callers, tests/advanced callers use the explicit variant"
  - "Empty-string override collapses to default, so callers that pass-through a possibly-unset CLI flag don't need to branch"

requirements-completed: [FOUND-03]

# Metrics
duration: 1 min
completed: 2026-04-10
---

# Phase 01 Plan 03: GmailClient baseURL Injection Summary

**GmailClient gains an injectable baseURL via a dedicated NewGmailClientWithBase constructor, unblocking httptest.Server-based unit tests and the upcoming --gmail-api-base CLI flag without touching any existing caller.**

## Performance

- **Duration:** 1 min
- **Started:** 2026-04-10T15:39:30Z
- **Completed:** 2026-04-10T15:40:34Z
- **Tasks:** 1
- **Files modified:** 1

## Accomplishments

- Added `baseURL string` field to `GmailClient` struct, defaulting to the existing `gmailAPIBase` constant
- Added `NewGmailClientWithBase(token, baseURL string) *GmailClient` as the explicit-base constructor
- Routed the existing `NewGmailClient(token string)` through `NewGmailClientWithBase(token, gmailAPIBase)` — callers are unchanged, there is now a single construction code path
- Switched `CreateDraft` HTTP URL construction to use `gc.baseURL` instead of the package-level `gmailAPIBase` constant
- Empty-string baseURL collapses to the default, so FOUND-04's CLI flag can pass through an unset value without branching

## Task Commits

1. **Task 1: Add baseURL field and NewGmailClientWithBase constructor** - `49aeaa5` (feat)

## Files Created/Modified

- `src/native-host/gmail.go` - Added `baseURL` field to `GmailClient`, added `NewGmailClientWithBase` constructor, routed `NewGmailClient` through it, switched `CreateDraft` URL construction to `gc.baseURL`. +16/-1 lines.

## Exact Diff

```diff
--- a/src/native-host/gmail.go
+++ b/src/native-host/gmail.go
@@ -21,14 +21,29 @@ const (
 // GmailClient handles Gmail API operations
 type GmailClient struct {
        httpClient *http.Client
        token      string
+       baseURL    string // FOUND-03: injection point for tests and FOUND-04 CLI flag; defaults to gmailAPIBase
 }

-// NewGmailClient creates a new Gmail API client with the given OAuth token
+// NewGmailClient creates a new Gmail API client with the given OAuth token
+// using the default Gmail API base URL. For tests or alternate endpoints,
+// use NewGmailClientWithBase.
 func NewGmailClient(token string) *GmailClient {
+       return NewGmailClientWithBase(token, gmailAPIBase)
+}
+
+// NewGmailClientWithBase creates a Gmail API client with an explicit base URL.
+// Used by tests (httptest.Server) and by the native host when --gmail-api-base
+// is passed on the command line (FOUND-04).
+// If baseURL is empty, the default gmailAPIBase is used.
+func NewGmailClientWithBase(token, baseURL string) *GmailClient {
+       if baseURL == "" {
+               baseURL = gmailAPIBase
+       }
        return &GmailClient{
                httpClient: &http.Client{},
                token:      token,
+               baseURL:    baseURL,
        }
 }

@@ -58,7 +73,7 @@ func (gc *GmailClient) CreateDraft(msg *MailMessage) (string, error) {
                return "", fmt.Errorf("failed to marshal request: %w", err)
        }

-       url := fmt.Sprintf("%s/drafts", gmailAPIBase)
+       url := fmt.Sprintf("%s/drafts", gc.baseURL)
        req, err := http.NewRequest("POST", url, bytes.NewReader(bodyJSON))
        if err != nil {
                return "", fmt.Errorf("failed to create request: %w", err)
```

## Decisions Made

- **Constructor pattern: dedicated `NewGmailClientWithBase` instead of variadic options.** CONTEXT.md explicitly left the call to the implementer ("pick whichever keeps existing callers unchanged without variadic surprises — Claude's choice during plan"). A variadic `NewGmailClient(token string, opts ...string)` would silently accept `NewGmailClient(token, "a", "b")` with no compile error and unclear semantics. The dedicated alt constructor keeps the zero-arg default obvious and makes test-only call sites explicit (`NewGmailClientWithBase(...)` reads as "I am opting into a non-default base").
- **Retained `gmailAPIBase` as the package constant** rather than inlining the string into `NewGmailClient`. Keeps a single source of truth for the production URL and gives `NewGmailClientWithBase` a clean fallback when an empty override is passed — which is exactly the shape FOUND-04 will produce when the CLI flag is unset.
- **Empty-string collapses to default inside `NewGmailClientWithBase`.** This means FOUND-04 can pass the CLI flag value through unconditionally without having to branch on "was it set?" at every call site.
- **`main.go` deliberately not touched in this plan.** The only caller (`client := NewGmailClient(msg.Token)` at line 123) still compiles and runs unchanged because `NewGmailClient` kept its exact signature. FOUND-04 (plan 01-04) owns the switch to `NewGmailClientWithBase` once the `--gmail-api-base` flag exists.

## Deviations from Plan

None - plan executed exactly as written.

**Note on CONTEXT.md vs PLAN.md source-of-truth conflict:** CONTEXT.md's FOUND-03 section states the default should be `"https://gmail.googleapis.com"`, but the actual existing `gmailAPIBase` constant in `src/native-host/gmail.go` is `"https://www.googleapis.com/gmail/v1/users/me"`. The plan file (01-03-PLAN.md) correctly identified the real value and instructed the executor to preserve the existing constant. Per the `verify-before-assuming` rule, source code is ground truth; CONTEXT.md has a stale value that should be corrected at next phase transition. No code change needed — the plan was already correct.

**Total deviations:** 0
**Impact on plan:** None — single task, single file, clean build/vet/tests.

## Issues Encountered

None.

## Verification Results

- `go build ./...` — clean (no output)
- `go vet ./...` — clean (no output)
- `go test ./...` — `ok github.com/marcfargas/go-mapi/native-host 0.142s` (all existing tests pass, no new tests added per plan scope)
- `grep gmailAPIBase src/native-host/gmail.go` — 5 matches, all in const declaration, doc comment, or default-value assignment. Zero matches in HTTP URL construction.
- `grep "gc\.baseURL" src/native-host/gmail.go` — 1 match, in `CreateDraft`'s URL construction
- `git diff --stat src/native-host/main.go` — empty (main.go untouched)
- `git diff --stat src/native-host/gmail.go` — `1 file changed, 16 insertions(+), 1 deletion(-)`

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

- FOUND-03 injection point ready for FOUND-04 (plan 01-04) to wire `--gmail-api-base` CLI flag through to `NewGmailClientWithBase`
- Injection point ready for Phase 4 GOTEST-01 (`httptest.Server` unit tests of Gmail HTTP client)
- Injection point ready for Phase 4 E2E-02 (mock Gmail server in end-to-end tests)
- No blockers introduced

## Self-Check: PASSED

- `src/native-host/gmail.go` exists on disk
- `.planning/phases/01-foundation-signpath-application/01-03-SUMMARY.md` exists on disk
- Commit `49aeaa5` present in git log

---
*Phase: 01-foundation-signpath-application*
*Plan: 03 (FOUND-03)*
*Completed: 2026-04-10*
