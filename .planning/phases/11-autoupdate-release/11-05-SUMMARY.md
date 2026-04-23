---
phase: 11-autoupdate-release
plan: 05
subsystem: release-verification
tags: [sandbox, smoke-test, release-verification, evidence]
status: completed
requirements: [REL-06]
---

# Plan 11-05 — Clean-machine smoke harness

## Delivery (Task 1)

Harness scaffolded, then rewritten after the first-run feedback exposed three
blockers:

1. **v2.1 fallback removed.** The original fallback to
   `https://github.com/marcfargas/go-mapi/releases/latest/download/go-mapi-setup.exe`
   silently pulled v2.1.x during v3.0 pre-GA, which defeats the smoke. The
   harness now hard-errors if no v3.0 installer is staged at
   `tests\sandbox\phase11\installer\go-mapi-setup.exe` and points the caller at
   `scripts\build-phase11-installer.ps1`.
2. **PSSecurityException safety net.** The `.wsb` LogonCommand already passed
   `-ExecutionPolicy Bypass -NoProfile -File`, but mapped-folder files carry a
   Zone.Internet MOTW that can still block under some host settings. The
   harness now runs `Unblock-File` across `C:\phase11\*.ps1` as its first step.
3. **Manual tail shrunk 9 → 3.** The flow now auto-installs, auto-launches,
   auto-triggers MAPI via `mailto:`, auto-detects the queue JSON, auto-
   uninstalls, and auto-verifies cleanliness. Only three moments need a
   human: OAuth consent in the browser, clicking "Create draft" in the app
   window, and a y/n glance at Gmail Drafts. The harness polls `app.log` for
   the milestone lines (`oauth: signed in as`, `gmail: draft created id=`) so
   the human's job is just "do the thing, then hit Enter".

### New helper

- `scripts\build-phase11-installer.ps1` — local RC builder. Invokes `makensis`
  with an explicit absolute `!addplugindir` (the `.nsi`'s `${__FILEDIR__}`-
  based directive doesn't register under all pwsh/MSYS invocations), copies
  the installer to the staged path, and prints size + SHA256.

### Updated files

- `tests\sandbox\phase11\Run-Phase11Smoke.ps1` — full rewrite, ~250 lines, 0
  parse errors via `[Parser]::ParseFile`.
- `tests\sandbox\phase11\go-mapi-phase11.wsb` — unchanged (LogonCommand
  already correct).
- `.planning\phases\11-autoupdate-release\11-SMOKE-CHECKLIST.md` — now a
  3-prompt tail instead of a 9-step walkthrough.
- `.planning\phases\11-autoupdate-release\11-SMOKE-EVIDENCE.md` — template
  matched to the auto-generated ledger the harness drops in the evidence dir.
- `.gitignore` — adds `tests/sandbox/phase11/evidence-*/` and
  `tests/sandbox/phase11/installer/`.

### Staged for the sandbox run

- `tests\sandbox\phase11\installer\go-mapi-setup.exe` — v3.0.0-rc.1 built
  from this branch (6,793,870 bytes). Includes Phase 11 updater backend +
  tray UX + frontend UX. OAuth client ID/secret ldflags-injected.

## Pending (Task 2)

`checkpoint:human-verify gate="blocking"`. The human:

1. Verifies the installer is staged (done above).
2. Double-clicks `tests\sandbox\phase11\go-mapi-phase11.wsb`.
3. Handles the three prompts described in `11-SMOKE-CHECKLIST.md`.
4. Copies `<EvidenceDir>\EVIDENCE.md` into `11-SMOKE-EVIDENCE.md`, commits.
5. Replies `approved` to the orchestrator if verdict is `PASS`.

REL-06 is satisfied once that ledger commit lands. Plan 11-04 (v3.0 release
cut) stays blocked until it does.

## Invariants preserved

- Hosted CI unchanged — `.github/workflows/installer-smoke.yml` continues to
  cover the DLL-only smoke; Phase 11 flow stays on the sandbox per D-13.
- Evidence binaries (screenshots, `app.log` snapshot) are gitignored under
  `evidence-*/`; only the committed ledger is source of record.
- STATE.md / ROADMAP.md untouched — orchestrator owns those writes.

## Decisions honored

- D-13 Sandbox is the clean-room; not ported into hosted CI.
- D-14 Short manual tail accepted (3 prompts; OAuth consent + UI click + Gmail glance).
- D-15 Screenshots auto-captured at 7 checkpoints.
- D-16 Single green journey is the gate — `Overall: PASS` in the ledger.

## Deviations from original plan

- Original harness shipped as "5 files scaffolded" with the user running a
  9-step manual checklist. User pushed back on over-manuality + bugs; this
  rewrite shrinks the manual tail to 3 prompts and unblocks the install path.
- Added `scripts\build-phase11-installer.ps1` outside the original `files_modified`
  list. It's a local-dev helper, required because the CI path to an RC installer
  (`workflow_dispatch` dry-run) hadn't been triggered when the sandbox is run.
