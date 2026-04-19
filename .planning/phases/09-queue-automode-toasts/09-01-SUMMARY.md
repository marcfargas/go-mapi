---
phase: 09-queue-automode-toasts
plan: "01"
subsystem: go-test-hygiene
tags: [test-hygiene, go-race, ci, auth, watcher-bridge]
dependency_graph:
  requires: []
  provides: [green-ci-baseline, deterministic-bootstrap-auth, hermetic-userinfo-tests, loosened-coalesce-assertion]
  affects: [src/app/auth.go, src/app/auth_test.go, src/app/watcher_bridge_test.go]
tech_stack:
  added: []
  patterns: [httptest-stub-override, channel-done-signal, legal-range-assertion]
key_files:
  created: []
  modified:
    - src/app/auth.go
    - src/app/auth_test.go
    - src/app/watcher_bridge_test.go
decisions:
  - WR-01: Remove t.Parallel() from TestAuthCodeURLHasPKCE — mutates oauthClientID/oauthClientSecret package vars
  - WR-02: bootstrapAuth() returns <-chan struct{} so tests can wait deterministically; production caller discards channel
  - WR-03: Loosen TestDispatcherCoalesces assertion from count==1 to legal range [1,50]; document guarantee in block comment
metrics:
  duration: 5m
  completed_date: "2026-04-19T13:06:57Z"
  tasks_completed: 2
  tasks_total: 2
  files_modified: 3
  commits: 2
requirements_closed: [QUAL-03, QUAL-04]
---

# Phase 9 Plan 01: Test Hygiene (WR-01 + WR-02 + WR-03) Summary

**One-liner:** Close three Phase 8.1 test-hygiene carry-overs by making bootstrapAuth deterministic via `<-chan struct{}`, stubbing the userinfo endpoint, and loosening the over-tight coalesce assertion — establishing a green CI baseline before Phase 9 feature work.

## Tasks Completed

| # | Name | Commit | Files |
|---|------|--------|-------|
| 1 | Fix WR-01 + WR-02: deterministic bootstrapAuth and hermetic userinfo stub | cb9c35c | src/app/auth.go, src/app/auth_test.go |
| 2 | Fix WR-03: loosen TestDispatcherCoalesces assertion with explanatory comment | 18ac20e | src/app/watcher_bridge_test.go |

## What Was Built

### Task 1 — WR-01 + WR-02

**WR-01:** Removed `t.Parallel()` from `TestAuthCodeURLHasPKCE`. The test mutates `oauthClientID` and `oauthClientSecret` package-level vars (ldflags-injected globals). Parallel execution races these writes against other parallel tests. Added an explanatory comment citing STATE.md WR-01 and the `paths_test.go:16` precedent. `t.Parallel()` count: 15 → 14 actual calls (comment text excluded).

**WR-02:** Changed `bootstrapAuth()` signature from `func (a *App) bootstrapAuth()` to `func (a *App) bootstrapAuth() <-chan struct{}`. The returned channel is closed when the async userinfo-fetch goroutine completes (via `defer close(done)`). Early-return branches (auth==nil, keyring error, no tokens, invalid_grant) close `done` inline before returning. Production caller at `app.go:102` discards the channel — valid Go.

Two bootstrap tests updated:
- `TestBootstrapAuthSignedInPath`: adds `userinfoEndpointOverride` stub + `select { case <-app.bootstrapAuth(): ... case <-time.After(2s): t.Fatal(...) }`
- `TestBootstrapAuth_TransientErrorKeepsTokens`: same pattern — the transient-error path keeps tokens and proceeds to the async userinfo goroutine, so the stub and channel-wait are both needed

Two other bootstrap tests (`TestBootstrapAuthSignedOutPath`, `TestBootstrapAuth_KeyringGetHardError_SetsErrorState`) take early-return branches that close `done` synchronously — safe to discard the channel, no stub needed.

### Task 2 — WR-03

Replaced the over-tight `count == 1` assertion in `TestDispatcherCoalesces` with the correct legal range `[1, burst=50]`. Added a 32-line block comment documenting:
- The 1-slot `pending` channel guarantee: "at least one emit per non-empty burst, at most one per OnQueueChanged call"
- Three legal outcome scenarios (1, 2, up to 50 emits) with rationale for each
- WR-03 history (origin commit 36ca9e8, Phase 7 flake on windows/amd64 under -race)
- Reference to 09-RESEARCH.md §5 for full analysis

Also added a non-failing canary log: if count > 5, `t.Logf` warns that coalescing is less aggressive than expected (informational only).

`time.Sleep` extended from 50ms to 100ms to give the dispatcher more margin on slow CI runners.

## Verification Results

- `go test -run "TestAuthCodeURL|TestBootstrap" -count 10`: PASS (10/10 iterations, all 5 target tests)
- `go test -run TestDispatcherCoalesces -count 100 -timeout 120s`: PASS (100/100 iterations)
- `go test -run "TestDispatcherCoalesces|TestBootstrapAuth|TestAuthCodeURLHasPKCE" -count 25`: PASS
- `go test -count 1 -timeout 120s ./internal/mapi/... ./src/app/...`: PASS (both modules clean)
- `git diff src/app/go.mod src/app/go.sum`: empty (no dependency changes)

Note: `-race` is not supported on windows/arm64 (local dev machine). Race verification happens on `windows-latest` (amd64) CI runners per the established CI convention (QUAL-04). The code changes are designed specifically to eliminate the goroutine leaks that `-race` catches.

## Acceptance Criteria Verification

| Criterion | Status |
|-----------|--------|
| `grep -c "t.Parallel()"` decreases by exactly 1 (15 → 14) | PASS |
| `userinfoEndpointOverride =` has 3+ occurrences in auth_test.go | PASS (lines 617, 843, 906) |
| `func (a *App) bootstrapAuth() <-chan struct{}` in auth.go | PASS (line 750) |
| `count == 1` assertion removed from watcher_bridge_test.go | PASS (only in comment) |
| `WR-03 (2026-04-19)` comment in watcher_bridge_test.go | PASS (line 85) |
| No changes to go.mod / go.sum | PASS |

## Deviations from Plan

None — plan executed exactly as written.

The one adaptation: `-race` not available on windows/arm64 local machine. Tests run without `-race` locally passed 100% across all iterations. The `-race` gate runs on `windows-latest` (amd64) CI — the canonical validation environment. This is the established project convention (Phase 8.1 CI convention, STATE.md).

## Known Stubs

None. This plan is pure test-hygiene — no new feature code, no data flows, no UI rendering.

## Threat Flags

None. No new network endpoints, auth paths, file access patterns, or schema changes introduced. The `userinfoEndpointOverride` seam already existed; this plan adds two more test usages of an existing seam.

## Self-Check

Commits exist:
- cb9c35c: fix(09-01): WR-01 + WR-02 — deterministic bootstrapAuth and hermetic userinfo stub
- 18ac20e: fix(09-01): WR-03 — loosen TestDispatcherCoalesces assertion with documented guarantee

Files modified:
- src/app/auth.go (bootstrapAuth signature + body)
- src/app/auth_test.go (WR-01 comment, WR-02 stubs + channel waits)
- src/app/watcher_bridge_test.go (TestDispatcherCoalesces replacement)
