# Phase 5: Release Cut - Context

**Gathered:** 2026-04-11 (scaffolded during interim milestone audit)
**Status:** Ready for planning

<domain>
## Phase Boundary

Take v2.0.0 from "source complete, all tests green locally" to "a real user can download, install, and use go-mapi on a fresh Windows box". Phase 5 exists because the autonomous run of Phases 2-4 produced a fully-merged codebase with 87/87 extension tests green and a complete Inno Setup script, but zero runtime evidence on a real Windows runner: installer-smoke.yml has never run, e2e.yml has never run, go-race-nightly.yml has never run, nothing has been published to GitHub Releases, and no human has ever installed the `.exe` on a real box.

**In scope:** CI triggering + green-lighting, `tests/sandbox/` hardening for local repro, README rewrite for the real distribution flow, PHASE-4-FINDING-02 close-out, v2.0.0 tag push + GitHub Releases publish (unsigned fallback), manual UAT on a real Windows box, re-archiving the milestone after UAT passes.

**Out of scope:** SignPath Foundation approval and signed re-cut (deferred to v2.0.1 per Phase 5 decision). Anything that isn't on the v2.0.0 exit path. New features. Chrome Web Store publishing.

</domain>

<decisions>
## Implementation Decisions

### Ship unsigned, re-cut signed in v2.0.1 (D-01)
- **D-01:** v2.0.0 ships with the SIGN-03 unsigned fallback path. Users see the SmartScreen "Windows protected your PC" dialog and click through via "More info" → "Run anyway". Release notes (from `.github/release-template.md`) walk them through it. SignPath Foundation approval is not blocked on, not waited for, and not gated into Phase 5. When approval lands (weeks away), a v2.0.1 re-cut with signed binaries ships from the same `develop` branch with zero code changes — just a new tag and the `SIGNPATH_API_TOKEN` secret present in the workflow environment.
- **Rationale:** Matches user decision from the Phase 5 scoping question. Avoids coupling a shippable release to an external approval process with unknown calendar time. The unsigned fallback path already exists, works, and is CI-tested.

### Phase 5 is mostly Marc-owned manual work (D-02)
- **D-02:** The three CI workflow triggers (`installer-smoke.yml`, `e2e.yml`, `go-race-nightly.yml`) need `gh workflow run` from an authenticated `gh` CLI, which the executor sandbox does not have. The tag push needs explicit approval. The manual UAT needs a real Windows box with Admin rights (or a Windows Sandbox). Phase 5 execution is therefore a series of Marc-owned manual steps with Claude handling the scriptable pieces (CONTEXT, PLAN, `tests/sandbox/` hardening, README rewrite, the json_writer.h one-liner, the SUMMARY/VERIFICATION writing after each step).
- **Rationale:** Honest accounting of what can actually happen in an executor sandbox without admin/network/secrets. Avoids another "source complete, not shipped" confusion.

### Harden the existing `tests/sandbox/` instead of greenfielding (D-03)
- **D-03:** `tests/sandbox/` already contains `run-sandbox-test.ps1` (158 lines — orchestrator using the Windows 11 24H2+ `wsb` CLI), `setup.ps1` (62 lines — WinAppDriver install + developer mode toggle), and `test-dll-registration.ps1` (69 lines — DLL registration sanity check). Phase 5 hardens these: adds a `.wsb` config for declarative sandbox provisioning, extends `run-sandbox-test.ps1` to run the full v2.0.0 install → E2E → uninstall flow, writes `tests/sandbox/README.md` documenting prerequisites and expected runtime, and wires the existing `installer-smoke.yml` Pester test to optionally run inside the sandbox instead of on bare `windows-latest` for faster local feedback.
- **Rationale:** The scaffolding already exists and references the right CLI (`wsb`), so greenfielding would waste work. The user explicitly called this out as "needs hardening but enables verifying everything locally (even e2e)".
- **Non-goal:** This does NOT replace the CI workflows. CI remains the authoritative ship gate. The sandbox harness is the fast local repro path.

### PHASE-4-FINDING-02 bundled into Phase 5 (D-04)
- **D-04:** The pre-existing `-Wcomment` warning in `src/interceptor/json_writer.h:36` gets its one-line fix here because (a) Phase 5 is already touching CI output (the warning shows in the first CPPTEST-02 CI run and makes the output noisy), and (b) bundling it avoids scope creep in future phases. Fix is mechanical: replace the trailing backslash with either a backtick-wrapped path or a forward slash. One line, no behavior change.
- **Rationale:** Documented as a deferred finding during Phase 4 ("bundle with next interceptor edit"). Phase 5 is that edit.

### Tag pushes `v2.0.0`, not `v2.0.0-rc1` or similar (D-05)
- **D-05:** The tag pushed is `v2.0.0`. No RC, no beta, no prerelease markers. Rationale: Phase 5's Success Criterion #6 (manual UAT on a real Windows box) is the ship gate. If UAT finds a blocker, the fix lands on `develop` and a new tag `v2.0.1` takes its place — the original `v2.0.0` tag is left alone (never delete published tags). If UAT passes, `v2.0.0` is the shipped version with no rename needed.
- **Rationale:** Marc's pragmatic-over-perfect default (from `~/.claude/CLAUDE.md`). RC tags add ceremony without changing the shipping model — the v2.0.1 hotfix path handles post-UAT issues just as well.

### README rewrite is part of Phase 5, not a separate docs phase (D-06)
- **D-06:** `README.md` currently has dev-oriented install instructions (Node + Go + MinGW + CMake + PowerShell). Phase 5 rewrites the "Installation" section (and possibly the "Usage" / "Uninstall" sections) for a non-technical Windows user: download the installer from GitHub Releases, click through SmartScreen, single UAC, any of the five supported Chromium browsers just works. Dev-oriented instructions move to a separate section (`## Development` or `CONTRIBUTING.md`) so they're still discoverable but don't gate a non-technical user's first install.
- **Rationale:** The v2.0.0 core value statement ("a non-technical Windows user can install go-mapi once and have every Send to Mail recipient action appear as a Gmail draft") is only true if the README reflects that flow. Dev-only README is a bug against core value.
- **Non-goal:** Full documentation site, Chrome Web Store listing copy, or privacy policy. Those are v2.1.0+ work.

### Re-archive milestone after UAT passes (D-07)
- **D-07:** The premature milestone archival from the initial autonomous run (commits `c69ca81` + `6747569`) was rolled back via `git reset --hard 9f72f42`. The v2.0.0 tag was also deleted (was pointing at the rolled-back archive commit). After Phase 5 completes its manual UAT step, `/gsd:complete-milestone v2.0.0` runs again — this time against the runtime-verified state, with the tag about to be created fresh as part of REL-05. The re-archival produces a new, accurate MILESTONES.md entry and moves phases 1-5 into `.planning/milestones/v2.0.0-phases/`.
- **Rationale:** The initial archive was correct in structure but wrong in meaning (archived "source complete" as "shipped"). Re-running the lifecycle after UAT fixes the meaning.

### Claude's Discretion
- Exact wording of the `tests/sandbox/README.md` (needs to cover Windows 11 24H2+ `wsb` CLI prerequisite, but the rest is informational).
- Layout of the `.wsb` config (XML schema is documented; pick the minimal config that shares the project folder read-only and maps an output folder read-write).
- Exact phrasing of the README SmartScreen click-through section — short, factual, non-scary.
- Whether PLAN files are needed at the granularity of one-per-requirement or can be bundled (e.g., REL-01 + REL-04 in one CI-cleanup PLAN, REL-02 in a sandbox PLAN, REL-03 in a docs PLAN, REL-05 + REL-06 + REL-07 in a release-and-UAT PLAN). Planner's call.
- Whether to run the CI workflows via `gh workflow run` from a separate Marc-run step or to document the exact commands in a `05-MANUAL-STEPS.md` file that Marc executes himself. Default to the documented-commands approach since the sandbox can't `gh auth login` anyway.

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Phase scope + roadmap
- `.planning/ROADMAP.md` §"Phase 5: Release Cut" — goal, success criteria, dependencies on Phases 1-4.
- `.planning/REQUIREMENTS.md` REL-01..07 (Release Cut section) — full requirement text with acceptance criteria.
- `.planning/v2.0.0-MILESTONE-AUDIT.md` — describes the exact runtime validation gaps Phase 5 closes. Status `tech_debt` is accepted here, not resolved.

### What's already shipped (Phases 1-4 context)
- `.planning/phases/01-foundation-signpath-application/01-VERIFICATION.md` — Phase 1 exit state + SIGN-01 filing deferred notes.
- `.planning/phases/02-extension-install-ux/02-VERIFICATION.md` — Phase 2 exit state (tsc/lint/tests clean).
- `.planning/phases/03-inno-setup-installer-signing-distribution/03-VERIFICATION.md` — Phase 3 exit state (source complete, CI-pending — exactly what REL-01 fixes).
- `.planning/phases/04-test-suite-completeness-e2e/04-VERIFICATION.md` — Phase 4 exit state (CI-pending for E2E + race nightly).
- `.planning/phases/04-test-suite-completeness-e2e/04-FINDINGS.md` — PHASE-4-FINDING-01 (fixed during audit) and PHASE-4-FINDING-02 (bundled into REL-04).
- `.planning/phases/04-test-suite-completeness-e2e/04-E2E-SPIKE.md` — the reserved E2E-05 spike research, including the five unresolved flakiness risks with first-line fixes. Consult when triaging the first `e2e.yml` run.

### CI workflows that need triggering + potentially fixing
- `.github/workflows/installer-smoke.yml` — Pester 5 install → verify → uninstall round-trip on `windows-latest`. Triggered via `workflow_dispatch`. First run is authoritative for INST-01..07.
- `.github/workflows/e2e.yml` — Playwright happy path + install UX on `windows-latest`. Triggered via `workflow_dispatch`. First run is authoritative for E2E-01..06.
- `.github/workflows/go-race-nightly.yml` — `go test -race ./...` on amd64. Triggered via `workflow_dispatch` for the first Phase 5 run; normally runs on `cron`.
- `.github/workflows/installer-release.yml` — tag-triggered release workflow. SignPath-gated (unsigned fallback when `SIGNPATH_API_TOKEN` secret is absent). Pushing the `v2.0.0` tag fires this. Publishes `go-mapi-setup.exe` to `releases/latest`.
- `.github/release-template.md` — body template used by `installer-release.yml`, contains the SmartScreen guidance walkthrough.

### Existing local repro scaffolding to harden
- `tests/sandbox/run-sandbox-test.ps1` (158 lines) — Windows Sandbox orchestrator using the `wsb` CLI. Already references the `wsb start / list / stop` command surface.
- `tests/sandbox/setup.ps1` (62 lines) — WinAppDriver install + developer mode enable inside the sandbox.
- `tests/sandbox/test-dll-registration.ps1` (69 lines) — DLL registration sanity check that runs inside the sandbox.
- Existing references in `.pi/context.md` and `CONTRIBUTING.md` — check what they already say before rewriting.

### The installer + extension that Phase 5 ships
- `src/installer/go-mapi.iss` (Inno Setup script) — what gets compiled into `go-mapi-setup.exe`.
- `src/installer/README.md` + `src/installer/tests/installer.Tests.ps1` — current installer docs + Pester test.
- `src/extension/src/popup/InstallPrompt.tsx` — `INSTALLER_DOWNLOAD_URL` constant. REL-05 verifies the URL it links to actually resolves to 200.
- `src/native-host/version.go` — version stamped into binaries via `-ldflags`. Phase 5 doesn't bump this (stays 2.0.0); v2.0.1 will.

### The one-line fix
- `src/interceptor/json_writer.h:36` — PHASE-4-FINDING-02: trailing backslash in a `//` comment triggers `-Wcomment` under GCC. REL-04 closes this.

### User-facing docs that need rewriting
- `README.md` — install instructions rewrite (REL-03). Check current state first before drafting the new version.
- `CONTRIBUTING.md` — possibly extended with the "how to run tests locally via Windows Sandbox" pointer from REL-02.

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `tests/sandbox/run-sandbox-test.ps1`: existing `wsb start --raw | ConvertFrom-Json` orchestrator. Already handles the "existing sandbox found, stop it" case and the "wsb CLI not found" error path. REL-02 extends this rather than rewriting it.
- `tests/sandbox/setup.ps1`: already installs WinAppDriver and enables developer mode inside the sandbox. Reusable for the install-inside-sandbox flow.
- `.github/workflows/installer-release.yml`: already handles the SignPath-gated vs unsigned-fallback branching. REL-05 just fires it via a tag push — no workflow changes needed unless the first run surfaces a bug.
- `.github/release-template.md`: already contains the SmartScreen click-through walkthrough. REL-03 links to this same content from the README.
- The `wsb` CLI (Windows 11 24H2+): declarative sandbox management with JSON output (`--raw` flag), used by REL-02 harness.

### Established Patterns
- PowerShell harness scripts log to `C:\output\*.log` inside the sandbox (from `setup.ps1` pattern). Phase 5 additions follow the same convention.
- `gh workflow run <workflow> --ref develop` is the CI trigger pattern. Results tailed via `gh run list --workflow=<workflow> --limit=1` + `gh run view <id>`.
- `git tag -a v<version> -m "..."` followed by `git push origin v<version>` fires the release workflow. No separate "create release" step — the workflow handles it.
- Conventional commits: `feat(05-NN): ...`, `ci(05-NN): ...`, `docs(05-NN): ...`, `fix(05-NN): ...`.

### Integration Points
- `gh workflow run` + workflow dispatch → `windows-latest` runner → result feedback via `gh run view`. Phase 5 CI-triggering happens entirely through this loop.
- `git push origin v2.0.0` → `installer-release.yml` via tag-push trigger → `iscc.exe` build → (optional SignPath sign) → `softprops/action-gh-release@v2` publish → `releases/latest/download/go-mapi-setup.exe` URL live.
- Windows Sandbox harness → `wsb start` → shared project folder read-only → run installer + extension + Chrome inside sandbox → capture logs to mapped output folder → sandbox stopped. No host state touched.
- Manual UAT → real Windows box → extension side-loaded from unpacked `dist/` → Chrome or Edge with the extension → Notepad "Send to Mail recipient" → Gmail draft appears in Marc's target account. Results captured in `05-UAT.md`.

</code_context>

<specifics>
## Specific Ideas

- User note from Phase 5 scoping: "We were using Windows Sandboxes for testing locally, that should be somewhere in the repo; needs hardening but enables verifying everything locally (even e2e)". This is the REL-02 mandate — not a greenfield sandbox setup, a hardening of what's already there.
- Ship-unsigned decision is a hard one: Phase 5 does NOT wait for SignPath. If `SIGNPATH_API_TOKEN` is absent at `installer-release.yml` run time, the workflow takes the unsigned fallback path (already tested in Phase 3 source). This was explicitly chosen to avoid blocking v2.0.0 on an external approval timeline.
- UAT is the final gate. If UAT fails on a real Windows box, Phase 5 does not close — a fix lands on develop, a new `v2.0.1` tag fires the release workflow again, and UAT re-runs against the new installer.
- The re-archive (REL-07) is the close-out ritual. Until REL-07 runs, v2.0.0 is not "shipped" — it's in Phase 5.

</specifics>

<deferred>
## Deferred Ideas

- **SignPath-signed v2.0.1 re-cut** — deferred explicitly per D-01. Ships whenever SignPath Foundation approval lands. No code changes; same `develop`, new tag, secret present in workflow env.
- **Chrome Web Store listing publication** — out of milestone scope entirely. Placeholder link in README if it's not live yet.
- **Real Gmail API E2E smoke test (SMOKE-01)** — v2.1.0 candidate, noted in v2 requirements.
- **blegal.dev download mirror (DIST-01)** — out of scope per REQUIREMENTS.md and Marc's confidentiality rule (no direct references to blegal.dev infra in public content).
- **Edge Add-ons Store publishing (DIST-02)** — v2.1.0+.
- **Host self-update (UPDATE-01, UPDATE-02)** — v2 section, not this milestone.
- **Bumping `MIN_SUPPORTED_HOST_VERSION` to activate the OUTDATED dead branch (HAND-01)** — v3.0.0.
- **Full documentation site or CONTRIBUTING.md rewrite** — Phase 5 only touches what REL-03 requires (install instructions). Anything broader is a separate future effort.
- **Pre-existing staticcheck suggestions in `gmail.go`, `main.go`, `watcher.go`** — still deferred. Bundle with next production code edit in those files.

</deferred>

---

*Phase: 05-release-cut*
*Context gathered: 2026-04-11 (scaffolded during interim milestone audit after the premature archival roll-back)*
