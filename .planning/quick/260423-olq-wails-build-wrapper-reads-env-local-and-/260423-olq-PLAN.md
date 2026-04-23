---
quick_id: 260423-olq
description: Wails build wrapper reads .env.local and injects OAuth via ldflags
date: 2026-04-23
mode: quick-inline
---

# Quick Task 260423-olq — Plan

## Context

`npm run build` produces a `go-mapi.exe` that fatals at startup with
`OAuth client_id missing — build was not wired correctly`. The guard in
`src/app/credentials_check.go` expects package-level `oauthClientID` /
`oauthClientSecret` to be set via `-ldflags -X main.oauthClientID=...`.
The existing `build` script in package.json never did this; rc.2 was
credentialed only because it shipped through Phase 11's release CI.

`.env.local` at the repo root (already gitignored, pre-existing) holds
the two env vars we need:
- `GOMAPI_OAUTH_CLIENT_ID`
- `GOMAPI_OAUTH_CLIENT_SECRET`

## Decisions (pre-approved by Marc in discussion)

1. Wrapper script approach (not env-var export in package.json) — cleaner
   separation of secret-reading from shell plumbing.
2. PowerShell 5.1 wrapper (matches rest of project's build tooling).
3. Bake secrets into `.exe` via ldflags (not runtime env var lookup) —
   consistent with Phase 8 design and the established PKCE Desktop
   client policy ("Desktop OAuth secrets ship with binaries").
4. Installer does NOT contain `.env.local` — values live only inside the
   compiled `.exe`'s data segment.

## Task breakdown

### Task 1: wrapper + wiring (1 commit)

**Files:**
- `scripts/build-wails.ps1` (NEW): reads .env.local, parses `K=V` pairs,
  validates both required vars present, builds `-ldflags "-X ..."` string,
  sets CC/CXX to triple-prefixed mstorsjo clang if available (ARM64 host
  compatibility), invokes `wails build -platform windows/amd64 -ldflags ...`.
  Secret values are never printed by this script.
- `package.json`: `build` script invokes the wrapper instead of inline
  cmd.exe gymnastics.

**Action:** Write the script, update package.json.

**Verify:** `npm run build` succeeds, produces `src/app/build/bin/go-mapi.exe`
with credentials baked in. No stray `.env.local` copies anywhere in build output.

**Done:** Wails build completes without the startup-guard fatal; installer
packages the credentialed .exe.

### Task 2: docs (1 commit)

**Files:**
- `.planning/quick/260423-olq-.../260423-olq-PLAN.md` (this file)
- `.planning/quick/260423-olq-.../260423-olq-SUMMARY.md`
- `.planning/STATE.md` — "Last activity" + Quick Tasks Completed row

**Done:** Orchestrator commit captures the audit trail.

## Known limitations (intentional)

- Wails's own CLI banner prints the full `LDFlags` string including the
  secret. Visible in build logs. Per prior project decision, accept and
  move on. A follow-up can add a redacting filter on the wrapper's stdout.
- No automated tests — the wrapper is shell glue; failure modes surface at
  runtime via the existing credentials guard.
