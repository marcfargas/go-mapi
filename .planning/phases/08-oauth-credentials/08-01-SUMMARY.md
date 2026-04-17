---
phase: "08"
plan: "01"
subsystem: oauth-credentials
tags: [oauth, credentials, gcp, ldflags, dev-tooling, d-08, d-09, d-10, auth-06]
dependency_graph:
  requires: []
  provides:
    - "package-level var oauthClientID / oauthClientSecret in main pkg (ldflags -X injection targets)"
    - "init() env-var fallback for wails dev (GOMAPI_OAUTH_CLIENT_ID / GOMAPI_OAUTH_CLIENT_SECRET)"
    - "D-10 fatal guard in main.go before wails.Run"
    - "scripts/dev-wails.ps1 developer entry point"
    - ".env.local.example template (repo root)"
    - "/.env.local gitignore rule"
  affects:
    - "every future Phase 8 plan that needs a signed-in user — 08-02..08-05 consume oauthClientID/Secret via the golang.org/x/oauth2 PKCE flow"
    - "Phase 10 CI release pipeline — will pass GOMAPI_OAUTH_CLIENT_ID / _SECRET via -ldflags using the same var targets"
tech_stack:
  added: []
  patterns:
    - "-ldflags '-X main.<var>=<value>' for build-time secret injection (extends existing Version pattern in main.go line 15)"
    - "init()-based env-var fallback so `wails dev` does not need a -ldflags dance each run"
    - "Fail-fast guard in main() before wails.Run — empty client_id => logError FATAL + os.Exit(1)"
key_files:
  created:
    - "src/app/auth_credentials.go"
    - ".env.local.example"
    - "scripts/dev-wails.ps1"
  modified:
    - "src/app/main.go"
    - ".gitignore"
decisions:
  - "D-08 realised: package-level `var oauthClientID` / `var oauthClientSecret` (grouped var block) — must be var, not const, for -X to overwrite."
  - "D-09 realised: init() reads GOMAPI_OAUTH_CLIENT_ID / _SECRET and overrides only if non-empty, preserving the ldflags-injected release value when env vars are unset."
  - "D-10 realised: main.go aborts with a clear log line and exit 1 when either credential is empty — before any Wails init cost is paid."
  - "Per feedback (2026-04-17), .env.local + .env.local.example live at REPO ROOT (not src/app/). Marc keeps dev dotfiles at root for visibility."
  - "Safety ordering: `.gitignore` rule added BEFORE `.env.local.example` creation and BEFORE any `git add` — removes the window where an accidental `git add .` could stage the real secret."
metrics:
  duration: "~2 minutes (automation phase, post-checkpoint resume)"
  completed_date: "2026-04-17"
  tasks_completed: 3
  tasks_total: 3
  files_changed: 5
---

# Phase 8 Plan 01: OAuth Credential Injection Pipeline Summary

**One-liner:** Wired the OAuth client-credential injection pipeline — package-level `var` targets for `-ldflags -X`, env-var fallback for `wails dev`, fail-fast guard before `wails.Run`, gitignored `.env.local` + template, and a `dev-wails.ps1` entry point that sources the repo-root env file.

## What Was Built

### Task 1 — GCP desktop OAuth client + verification submission (checkpoint:human-action)

Completed by Marc ahead of this execution pass (prerequisite satisfied; recorded here for traceability):

- GCP Desktop OAuth 2.0 client created in `go-mapi` GCP project.
- OAuth consent screen configured with scopes: `gmail.compose`, `gmail.send`, `userinfo.email`, `userinfo.profile`.
- Google OAuth verification submitted on **2026-04-17** (AUTH-06 4-8 week review window running).
- `.env.local` at repo root populated with real `GOMAPI_OAUTH_CLIENT_ID` / `GOMAPI_OAUTH_CLIENT_SECRET`.
- Resume-signal "approved" provided.

No code changes in this task — it is a prerequisite gate, not a code task.

### Task 2 — auth_credentials.go + env fallback + gitignore + template

**Files:**
- `src/app/auth_credentials.go` (created) — grouped `var` block declaring `oauthClientID` and `oauthClientSecret` (both empty strings in source), plus `init()` that reads `GOMAPI_OAUTH_CLIENT_ID` / `GOMAPI_OAUTH_CLIENT_SECRET` and overrides only when non-empty.
- `.env.local.example` (created, repo root) — two-variable template with leading comment pointing developers at `scripts/dev-wails.ps1`.
- `.gitignore` — appended `/.env.local` rule (anchored to repo root) under a "Phase 8: OAuth credentials" header.

**Safety ordering:** `.gitignore` edit was performed first in the filesystem sequence — before `.env.local.example` was written, and well before any `git add`. `git check-ignore .env.local` confirmed the real secret file was ignored before any staging occurred.

**Commit:** `87370ad feat(08-01): add OAuth credential injection targets + dev env fallback`

### Task 3 — D-10 fatal guard + dev-wails.ps1

**Files:**
- `src/app/main.go` (modified) — inserted a 5-line fatal check immediately after `defer releaseSingleInstance()` and before `app := NewApp()`. Checks `oauthClientID == "" || oauthClientSecret == ""`, writes the required FATAL log line via `logError`, and calls `os.Exit(1)`. No new imports needed (`os` already in use at line 27).
- `scripts/dev-wails.ps1` (created) — resolves repo root via `(Resolve-Path (Join-Path $PSScriptRoot '..')).Path`, reads `.env.local` line-by-line with a regex that skips comments/blanks and `Set-Item`s each `KEY=VALUE` into the current environment, re-validates that both OAuth vars are set, then `Push-Location (Join-Path $repoRoot 'src' 'app')` and runs `wails dev`.

**Verification performed:**
- `cd src/app && go build ./...` — PASSED (exit 0).
- Built a throwaway binary at `/tmp/go-mapi-test.exe`, ran it with `env -u GOMAPI_OAUTH_CLIENT_ID -u GOMAPI_OAUTH_CLIENT_SECRET` — exited 1, and `%APPDATA%\go-mapi\app.log` received the exact line `[ERROR] FATAL: OAuth client credentials missing — build was not wired correctly (…)`. Test binary removed.

**Commit:** `74b5ecf feat(08-01): add D-10 fatal guard + dev-wails.ps1 entry point`

## Requirements Addressed

- **AUTH-06** (Google OAuth verification submitted day-1) — confirmed via Task 1 checkpoint; Marc submitted on 2026-04-17.
- **QUAL-03** (no secret in tracked files) — satisfied by `.gitignore` rule + repo-root template with blank values; `git check-ignore .env.local` proves the real file is outside version control.

## Decisions Made

1. **Grouped `var ( … )` block** in `auth_credentials.go` instead of two separate `var` lines — matches the plan's exact prescribed code and keeps the two related injection targets visually adjacent.
2. **Safety-first file ordering in Task 2** — `.gitignore` before `.env.local.example`; eliminated the brief window where the real `.env.local` was on disk but not yet ignored.
3. **Did not read `.env.local`'s contents** at any point. Existence was confirmed with `test -f`; ignore status with `git check-ignore`; no `cat`, `Read`, or `grep` against the file.

## Deviations from Plan

None. All three tasks executed exactly as written. No Rule 1/2/3 auto-fixes were needed; no Rule 4 architectural questions arose.

## Authentication Gates

Task 1 was itself an auth/setup gate — satisfied by the user before this execution pass (GCP console setup cannot be automated). Documented under "Task 1" above for traceability; not a mid-execution deviation.

## Known Stubs

None. `oauthClientID` / `oauthClientSecret` are **source-tree empty** by design — they are filled by `-ldflags` at release build time or by the `init()` env fallback at `wails dev` time. The empty source value is the documented pattern, not a TODO stub. The D-10 fatal guard in `main.go` guarantees any release binary that ships without injection cannot silently limp along.

## Self-Check: PASSED

Verified all claims:

- `src/app/auth_credentials.go` — FOUND (3 occurrences of `oauthClientID` on lines 6, 10, 23).
- `.env.local.example` — FOUND at repo root; contains `GOMAPI_OAUTH_CLIENT_ID=`.
- `scripts/dev-wails.ps1` — FOUND; contains `wails dev` (line 30) and `GOMAPI_OAUTH_CLIENT_ID` (line 24).
- `src/app/main.go` — FATAL block present at lines 33-36 (`oauthClientID == ""` check, FATAL log, `os.Exit(1)`).
- `.gitignore` — contains `/.env.local` at line 44; `git check-ignore .env.local` prints `.env.local`.
- Commit `87370ad` (Task 2) — FOUND in `git log`.
- Commit `74b5ecf` (Task 3) — FOUND in `git log`.
- `go build ./...` in `src/app` — PASSED.
- Fatal-path dry run (env-unset binary run) — exit=1 AND expected FATAL line in `%APPDATA%\go-mapi\app.log`.
