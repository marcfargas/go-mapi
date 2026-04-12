---
phase: 03
phase_name: Inno Setup Installer + Signing + Distribution
status: human_needed
verified: 2026-04-10
verifier: Phase 3 executor agent (autonomous, no Windows runner available)
---

# Phase 3 Verification: Inno Setup Installer + Signing + Distribution

## Goal-backward check

**Phase goal (from ROADMAP.md):** "A non-technical Windows user downloads
a single signed `.exe` from a stable URL, clicks through one UAC prompt,
and has go-mapi fully registered for all five Chromium-family browsers."

**Was the goal achieved?** Source-level yes; runtime yes-pending-CI. Every
file needed to hit the goal exists and passes static review. What cannot
be verified on the executor host:

- `iscc.exe` compile of `src/installer/go-mapi.iss` — no Inno Setup 6
  installed on the sandbox.
- Pester 5 execution of `src/installer/tests/installer.Tests.ps1` —
  requires Administrator rights and a built installer.
- SignPath signing path — requires a real SignPath organization +
  project + policy + API token, none of which exist yet (Phase 1
  deferred SignPath filing).
- GitHub Release publication — requires a pushed `v*` tag, which this
  phase explicitly does NOT push (out of scope per task brief).

These gaps move the phase status to `human_needed`. The first CI run of
`.github/workflows/installer-smoke.yml` is the authoritative verification
and will either confirm completion or surface specific failures to fix.

## Requirement-by-requirement check

| Req | Status | Evidence |
|-----|--------|----------|
| INST-01 | ✓ Source complete | `src/installer/go-mapi.iss` (349 lines) + `src/installer/README.md` committed in `ba4d562`. `OutputBaseFilename=go-mapi-setup` produces `go-mapi-setup.exe`. |
| INST-02 | ✓ Source complete | `[Files]` copies DLL + host to `{app}=%ProgramFiles%\go-mapi`. `[Registry]` writes `HKLM\SOFTWARE\Clients\Mail\go-mapi` with `DLLPath`. |
| INST-03 | ✓ Source complete | `RenderManifest()` Pascal helper + `WriteSharedManifest()` render the shared `.tmpl` to `{commonappdata}\go-mapi\com.gomapi.host.json`. `[Registry]` writes five HKLM browser trees (Chrome, Chromium, Edge, Brave, Vivaldi). All five `grep`-verified in the `.iss` file. |
| INST-04 | ✓ Source complete | `PrivilegesRequired=admin` → single UAC prompt. All state under HKLM and `{commonappdata}`, zero per-user state. |
| INST-05 | ✓ Source complete | `BackupPreviousMailClient()` writes JSON backup with `previousClient` + `backedUpAt` fields to `{commonappdata}\go-mapi\uninst\previous-mail-client.json` before the default-client overwrite. Skip-on-exist preserves original backup across upgrades. |
| INST-06 | ✓ Source complete | `CurUninstallStepChanged` removes the shared manifest, backup JSON, `{commonappdata}\go-mapi` tree, `%TEMP%\go-mapi`, and invokes `RestorePreviousMailClient()`. Browser trees and handler key removed declaratively via `uninsdeletekey`. |
| INST-07 | ~ Source ready, CI pending | `src/installer/tests/installer.Tests.ps1` (Pester 5) + `.github/workflows/installer-smoke.yml` (windows-latest) committed in `2a85141`. `pwsh` parse check passed on executor host. First CI run is the authoritative verification. |
| SIGN-02 | ✓ Source complete | `.github/workflows/installer-release.yml` has two `SignPath/github-action-submit-signing-request@v1` steps: one before `iscc.exe` (DLL+host) and one after (installer). Signed artifacts replace unsigned ones in-place before publish. |
| SIGN-03 | ✓ Source complete | Every signing step is gated on `if: env.SIGNPATH_API_TOKEN != ''`. The `Note unsigned fallback` step emits a CI warning when the secret is absent. Unsigned installer still builds and publishes. |
| SIGN-04 | ✓ Source complete | `softprops/action-gh-release@v2` attaches `go-mapi-setup.exe` to tag releases with the stable filename, resolving to `https://github.com/marcfargas/go-mapi/releases/latest/download/go-mapi-setup.exe`. |
| SIGN-05 | ✓ Source complete | `.github/release-template.md` includes "If Windows SmartScreen blocks the installer" section with "More info" → "Run anyway" walkthrough. `append_body: true` on the release action ensures this ships with every release. |
| EXT-07  | ⚠ Merge-time follow-up | Target file `src/extension/src/popup/InstallPrompt.tsx` does not exist in this worktree — Phase 2 is running in parallel and has not yet written it. Phase 2 was instructed to use the exact URL that Phase 3 locks as final, so the expected merge-time outcome is a pre-matched no-op. See `03-03-SUMMARY.md` "EXT-07 merge-time coordination note" for the reviewer handoff. |

## Static verification on executor host (what ran)

- **Grep acceptance criteria**: all plan-level acceptance criteria
  (22 patterns in 03-01, 12 in 03-02, 7 in 03-03, ~15 in 03-04)
  pass against the committed files. See individual `SUMMARY.md` files.
- **Five browser registry trees present** in both the `.iss` file
  (`grep 'NativeMessagingHosts'` → 5 matches) and the Pester test
  fixture (`grep -c 'NativeMessagingHosts'` → 5 matches).
- **YAML tabs check**: `installer-release.yml` and `installer-smoke.yml`
  contain no tab characters (verified via Python scan).
- **PowerShell parse check**: `installer.Tests.ps1` passes
  `[System.Management.Automation.Language.Parser]::ParseFile()` with
  zero errors (executed via `pwsh -NoProfile`).
- **`release.yml` untouched**: `git diff` against `develop` shows no
  changes to the existing `.github/workflows/release.yml` — additive
  only (SIGN-04 D-22 scope discipline).
- **Phase 1 artifacts intact**: `src/native-host/manifests/*.tmpl` files
  and `scripts/install.ps1` unchanged. Only new files added in
  `src/installer/` and `.github/`.

## What was NOT verified on the executor host

| Check | Reason | Resolution |
|---|---|---|
| `iscc.exe /DGOMAPIVersion=... src\installer\go-mapi.iss` compile | No Inno Setup 6 installed on the sandbox. | First run of `installer-smoke.yml` on any PR / push to `develop`. |
| `Invoke-Pester` round-trip (install → verify → uninstall → verify) | Requires Admin, built installer, real `%ProgramFiles%`. Executor sandbox can't do any of these. | First run of `installer-smoke.yml`. |
| SignPath signing request → signed output round-trip | No SignPath API token, no project, no policy (SignPath Foundation application not yet filed per Phase 1 handoff). | When Marc files SignPath and adds the four repository secrets, a tag push will exercise the signed path. Until then, only the unsigned fallback path runs. |
| `softprops/action-gh-release@v2` with `body_path: .github/release-template.md` + `append_body: true` | Requires a tag push, explicitly out of scope for this phase. | First `v*` tag Marc pushes after Phase 3 merges. |
| Rendered manifest JSON validity at install time (backslash-escape correctness, UTF-8 encoding, no BOM) | Requires the installer to run. | Smoke test verifies `Get-Content ... \| ConvertFrom-Json` succeeds on the written manifest. |
| `HKLM\SOFTWARE\Clients\Mail\(Default)` round-trip through backup → uninstall → restore | Requires running the installer. | Smoke test has assertions for the backup file shape but does not simulate a pre-existing default client (the permissive branch accepts both outcomes). A second test pass with a pre-seeded `Microsoft Outlook` default would strengthen INST-05 coverage — deferred to Phase 4 follow-up if Marc wants it. |

## Build verification

Not applicable — Phase 3 does not touch Go, C++, or TypeScript sources.
Phase 1's `go test ./...`, `go vet ./...`, and `tsc --noEmit` results from
`01-VERIFICATION.md` remain current for those layers.

## Scope discipline audit

- [x] No modification of `.github/workflows/build.yml`
- [x] No modification of `.github/workflows/release.yml`
- [x] No modification of `src/native-host/` files
- [x] No modification of `src/interceptor/` files
- [x] No modification of `src/extension/` files (Phase 2 parallel constraint; EXT-07 documented as merge-time follow-up)
- [x] No modification of `scripts/install.ps1`
- [x] No modification of the `.tmpl` manifest files from FOUND-06
- [x] No new npm / Go / CMake dependencies
- [x] No SignPath application filing (Phase 1 deferred)
- [x] No tag push (release workflow is tag-triggered but dormant until Marc pushes `v2.0.0`)
- [x] No Phase 4 test writing beyond the Pester smoke test required by INST-07
- [x] No blegal.dev mirror, no Edge Add-ons, no tray icon, no telemetry

## Must-haves (goal-backward)

1. **Single-file Windows installer buildable from repo sources** — ✓
   source complete (`go-mapi.iss`), ◯ compile unverified (needs
   Windows+Inno Setup).
2. **Single UAC prompt, no per-user state** — ✓ `PrivilegesRequired=admin`
   + HKLM-only + `%ProgramData%`-only.
3. **Five Chromium-family browsers registered** — ✓ all five in both
   `[Registry]` and the Pester fixtures.
4. **Previous Mail client backup + restore on uninstall** — ✓ Pascal
   helpers in place with the same semantics as `install.ps1`.
5. **Signed pipeline when SignPath approved** — ✓ source complete (two
   gated SignPath steps), ◯ end-to-end unverified until Marc has a
   SignPath project.
6. **Unsigned fallback when SignPath is not approved** — ✓ gate present
   on every signing step.
7. **Stable GitHub Releases download URL** — ✓ filename locked to
   `go-mapi-setup.exe`, published via `softprops/action-gh-release@v2`.
8. **SmartScreen guidance in release notes** — ✓ released-template.md
   committed with the "If Windows SmartScreen blocks the installer"
   section.
9. **Pester 5 smoke test on windows-latest CI** — ✓ test and workflow
   committed, ◯ not run in this phase.
10. **Extension URL swap (EXT-07)** — ⚠ merge-time follow-up; target
    file not in worktree yet.

## Deviations from plan

1. **`src/extension/src/popup/InstallPrompt.tsx` does not exist in the
   worktree.** The worktree branch was originally at a pre-Phase-1
   HEAD (`8a01fa3`), was fast-forwarded to `develop` (`af37211`) at
   the start of this phase run to pick up Phase 1 artifacts, and at
   `af37211` Phase 2 has only its CONTEXT.md. Per plan 03-03 Task 2
   case (1), EXT-07 is documented as a merge-time follow-up rather
   than being applied. This is the expected path — Phase 2 was given
   the same final URL value as its placeholder, so the follow-up is
   expected to be a trivial no-op verification.

2. **Worktree fast-forward.** The worktree branch
   `worktree-agent-a2647d2d` was created from a pre-Phase-1 base.
   The executor ran `git reset --hard develop` at the start of the
   phase to bring in the 36 Phase 1 commits. No conflicts; clean
   fast-forward. All Phase 3 commits are therefore children of
   `af37211` and will merge cleanly back to `develop`.

3. **No Inno Setup / no Pester-in-sandbox verification.** The task
   brief explicitly authorizes `human_needed` status when the
   executor host cannot fully verify on Windows. CI is the
   authoritative verifier; the first run of `installer-smoke.yml`
   either confirms everything or surfaces specific errors to fix in
   a follow-up plan.

## Phase status

**PHASE 3 SOURCE COMPLETE. `human_needed` pending CI verification.**

Next actions for the Phase 4 reviewer / orchestrator:

1. Let the first `installer-smoke.yml` CI run on the worktree branch
   (or on a PR against `develop`) verify `iscc.exe` compile, install
   round-trip, and Pester assertions.
2. If the smoke run fails, open a targeted fix plan (`03-05-PLAN.md`
   or similar) against the specific failure. Do not rewrite the phase.
3. After merging Phase 2 into `develop`, confirm EXT-07 per the
   "merge-time coordination note" in `03-03-SUMMARY.md`:
   `grep -c "https://github.com/marcfargas/go-mapi/releases/latest/download/go-mapi-setup.exe" src/extension/src/popup/InstallPrompt.tsx` should return `>= 1` with no `// EXT-07:` TODO comment remaining.
4. Leave SignPath verification for when Marc files the application
   and adds the four repository secrets. Until then, tag pushes
   produce an unsigned installer via the gated fallback path, which
   is the agreed behavior.

## Commits (Phase 3)

```
f65111c docs(03): Phase 3 CONTEXT.md — installer + signing + distribution decisions
df82ece docs(03): Phase 3 plans — installer, signing CI, release template, smoke test
ba4d562 feat(03-01): add Inno Setup installer script (INST-01..06)
754ce59 ci(03-02): add installer-release workflow with SignPath gate (SIGN-02/03/04)
970ecdf docs(03-03): add GitHub Release notes template with SmartScreen guidance (SIGN-05)
2a85141 ci(03-04): add Pester 5 installer smoke test and CI workflow (INST-07)
```

(plus follow-up commits for the summaries + this verification file.)
