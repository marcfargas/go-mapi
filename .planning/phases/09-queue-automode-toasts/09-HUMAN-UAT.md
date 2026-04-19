---
status: partial
phase: 09-queue-automode-toasts
source: [09-VERIFICATION.md]
started: 2026-04-19T19:00:00Z
updated: 2026-04-19T19:00:00Z
deferred_via: .planning/todos/pending/2026-04-19-automate-tray-visual-qa-windows-sandbox.md
---

## Current Test

[awaiting automated harness OR manual pass]

## Tests

### 1. Tray icon visual QA — queue / error / idle states
expected: Icon swaps to `tray-has-queue.ico` when queue ≥ 1; reverts to idle when empty. Error priority overrides has-queue (D-16). Tooltip format `go-mapi — {segment} — N pending` (D-17).
result: [pending — deferred 2026-04-19]

### 2. Toast E2E QA — arrival, draft-success, error, dismiss (NOTIF-01..05)
expected: Arrival toast fires on new email when window hidden/unfocused; draft-success toast fires on successful auto-draft when window hidden; error toasts always fire; tag/group-based `History.Remove` clears toast from Action Center on dismiss/processed (NOTIF-05); no toasts when window visible+focused (D-11); one-shot summary toast on invalid_grant (D-10).
result: [pending — deferred 2026-04-19]

### 3. Full Phase 9 E2E QA — complete user flow
expected: View queued emails (QUEUE-01); Create Draft drafts + removes row (QUEUE-02/03); Dismiss removes row (QUEUE-04); Mode toggle persists across restart (QUEUE-05/06); Pause/Resume halts + resumes auto-draft (QUEUE-07); ReAuth banner on invalid_grant; drafted-flash fires in window when visible+focused while toast fires when hidden (D-04/D-11).
result: [pending — deferred 2026-04-19]

## Summary

total: 3
passed: 0
issues: 0
pending: 3
skipped: 0
blocked: 0
deferred: 3

## Gaps

No functional gaps. All 5 success criteria pass automated verification. The 3 items above are untestable without a real Windows shell session — tracked for closure by either:

1. A manual pass by the maintainer on a dev Windows desktop (see per-plan Manual QA Checklist in SUMMARY.md files), OR
2. The Windows Sandbox + FlaUI automation harness tracked at `.planning/todos/pending/2026-04-19-automate-tray-visual-qa-windows-sandbox.md`

Either path resolves this UAT. Will surface in `/gsd-progress` and `/gsd-audit-uat` until then.
