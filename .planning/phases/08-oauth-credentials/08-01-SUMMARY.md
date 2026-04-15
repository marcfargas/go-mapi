---
phase: "08"
plan: "01"
subsystem: oauth-credentials
tags: [oauth, credentials, gcp, ldflags, dev-tooling]
dependency_graph:
  requires: []
  provides: []
  affects: []
tech_stack:
  added: []
  patterns: []
key_files:
  created: []
  modified: []
decisions: []
metrics:
  duration: ""
  completed_date: ""
  tasks_completed: 0
  tasks_total: 3
  files_changed: 0
---

# Phase 8 Plan 01: OAuth Credential Injection Pipeline Summary

## Status: CHECKPOINT REACHED

Execution paused at Task 1 (checkpoint:human-action). No code changes were made.

## Checkpoint: Task 1 — Confirm GCP desktop OAuth client + verification submitted + .env.local populated

This plan begins with a blocking human-action checkpoint. The following prerequisites must be completed manually before Tasks 2 and 3 (automated code implementation) can proceed:

1. Create a GCP Desktop OAuth client (Application type: Desktop app) in GCP Console -> APIs & Services -> Credentials
2. Configure OAuth consent screen with scopes: gmail.compose, gmail.send, userinfo.email, userinfo.profile
3. Submit Google OAuth verification request (4-8 week external review)
4. Create `src/app/.env.local` with real GOMAPI_OAUTH_CLIENT_ID and GOMAPI_OAUTH_CLIENT_SECRET values

Once confirmed, the automated tasks will implement:
- `src/app/auth_credentials.go` — ldflags injection targets + dev env-var fallback
- `src/app/.env.local.example` — template
- `.gitignore` update — gitignore rule for .env.local
- `src/app/main.go` — D-10 fatal guard before wails.Run
- `scripts/dev-wails.ps1` — dev wrapper that loads .env.local

## Deviations from Plan

None. Execution stopped as designed at the human-action gate.

## Self-Check: N/A

No files created or modified in this execution pass.
