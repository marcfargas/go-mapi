# Phase 5: Manual Steps Runbook

Marc-owned manual steps for Phase 5. The executor sandbox cannot run `gh`
(no authenticated CLI) or `git push` (requires explicit approval), so this
file documents the exact commands Marc runs from an authenticated terminal
on his dev box.

**Prerequisites:**
- `gh auth status` shows authenticated to `github.com` as `marcfargas`
- Working directory: `C:\dev\go-mapi` (Windows) or `~/dev/go-mapi` (nexus)
- On `develop` branch, synced with origin: `git fetch && git status` shows clean + up to date

---

## REL-01: Trigger the three CI workflows on develop

All three workflows accept `workflow_dispatch` and run on `windows-latest`.
Trigger them in the order below. After each trigger, wait for the run to
finish (or kick them off in parallel and collect conclusions at the end).

### 1. installer-smoke.yml (Pester install → verify → uninstall round-trip)

```bash
gh workflow run installer-smoke.yml --ref develop
# Wait ~10-20 seconds for the run to register, then:
gh run list --workflow=installer-smoke.yml --limit=1 --json databaseId,status,conclusion,headBranch
# Tail the most recent run:
gh run watch $(gh run list --workflow=installer-smoke.yml --limit=1 --json databaseId --jq '.[0].databaseId')
```

**Expected conclusion:** `success`. Authoritative verification for INST-01..07.

**If it fails:** download the `installer-smoke-results` artifact (NUnit XML)
and the `go-mapi-setup-smoke` artifact, inspect the Pester output. Open a
follow-up fix plan (`05-NN-installer-smoke-fix-PLAN.md`) — do not rewrite
this phase.

### 2. e2e.yml (Playwright happy-path + install UX)

```bash
gh workflow run e2e.yml --ref develop
gh run list --workflow=e2e.yml --limit=1 --json databaseId,status,conclusion
gh run watch $(gh run list --workflow=e2e.yml --limit=1 --json databaseId --jq '.[0].databaseId')
```

**Expected conclusion:** `success`. Authoritative verification for E2E-01..06.

**First-run flake watch list (from `04-E2E-SPIKE.md` §"Unresolved risks"):**
1. **Windows Defender scanning latency** on `launchPersistentContext`. If
   the run times out on the context launch step, raise `timeout` in
   `tests/e2e/playwright.config.ts` from 60s to 90s and re-run.
2. **Mock Gmail stdin hang on teardown.** If teardown hangs, change
   `child.kill()` to `child.kill('SIGKILL')` in the fixture teardown.
3. **HKCU registry write propagation delay.** Already mitigated via
   `expect.poll` — watch for it anyway.
4. **Service worker re-registration race.** If the install-UX test flakes
   after the reconnect trigger, add an explicit `HOST_STATE: READY` wait
   before the assertion.
5. **Extension ID instability.** If the extension ID changes between runs,
   pin a deterministic key in the test manifest. Low priority for v2.0.0.

### 3. go-race-nightly.yml (`go test -race` on amd64 windows-latest)

```bash
gh workflow run go-race-nightly.yml --ref develop
gh run list --workflow=go-race-nightly.yml --limit=1 --json databaseId,status,conclusion
gh run watch $(gh run list --workflow=go-race-nightly.yml --limit=1 --json databaseId --jq '.[0].databaseId')
```

**Expected conclusion:** `success`. This is the FOUND-01 watcher race fix
regression guard. No races should be detected.

**If it fails:** the race detector will print a stack trace for the
offending goroutine pair. File a follow-up fix plan. Do NOT mask the race
by reverting the nightly job — the whole point of GOTEST-03 is catching
this in CI.

### REL-01 sign-off checklist

All three must be ticked before proceeding to the next phase step:

- [ ] `gh run list --workflow=installer-smoke.yml --limit=1 --json conclusion` returns `"success"`
- [ ] `gh run list --workflow=e2e.yml --limit=1 --json conclusion` returns `"success"`
- [ ] `gh run list --workflow=go-race-nightly.yml --limit=1 --json conclusion` returns `"success"`
- [ ] Any first-run flakes from the e2e.yml watch list above are either absent or mitigated with the first-line fix

---

## REL-05: Push v2.0.0 tag and verify release publication

### Preconditions

All three CI workflows from REL-01 are green:

- [ ] `gh run list --workflow=installer-smoke.yml --limit=1 --json conclusion` -> `"success"`
- [ ] `gh run list --workflow=e2e.yml --limit=1 --json conclusion` -> `"success"`
- [ ] `gh run list --workflow=go-race-nightly.yml --limit=1 --json conclusion` -> `"success"`

Working tree is clean on `develop`:

```bash
git checkout develop
git pull --ff-only origin develop
git status   # must show "working tree clean"
```

### Push the tag

The `installer-release.yml` workflow is `on: push: tags: ['v*']`, so
the tag push is the authoritative trigger. The workflow reads the tag
via `${GITHUB_REF#refs/tags/}` -> `v2.0.0` -> `SEMVER=2.0.0` and
stamps it into the native host via `-ldflags "-X main.Version=2.0.0"`.

```bash
git tag -a v2.0.0 -m "go-mapi v2.0.0 — first shipped milestone (unsigned fallback per D-01)"
git push origin v2.0.0
```

**Ship-unsigned reminder (D-01):** `SIGNPATH_API_TOKEN` is not set as
a repository secret, so the workflow takes the SIGN-03 unsigned
fallback path (verified in `03-VERIFICATION.md`). Users will see
Windows SmartScreen on first run and click through via the walkthrough
in `.github/release-template.md` and `README.md`. A signed v2.0.1
re-cut is explicitly out of scope.

### Watch the release workflow

```bash
# Wait ~20 seconds for the push to register, then:
gh run list --workflow=installer-release.yml --limit=1 --json databaseId,status,conclusion,headBranch
gh run watch $(gh run list --workflow=installer-release.yml --limit=1 --json databaseId --jq '.[0].databaseId')
```

Expected outcome: the run reaches `conclusion: success`. The workflow
prints a "Note unsigned fallback (SIGN-03)" CI warning — this is
expected and by design.

### Verify the release is reachable

After the workflow completes, the stable URL must resolve:

```bash
curl -IL https://github.com/marcfargas/go-mapi/releases/latest/download/go-mapi-setup.exe
```

Expected response:

- Final `HTTP/2 200` (after whatever redirects GitHub Releases adds).
- `content-length:` header with a non-zero value (typically several MB).
- `content-type: application/octet-stream` or `application/x-msdownload`.

Additionally, confirm the URL matches what `InstallPrompt.tsx` links to:

```bash
grep "releases/latest/download/go-mapi-setup.exe" src/extension/src/popup/InstallPrompt.tsx
# must return exactly one line referencing the same URL
```

### REL-05 sign-off checklist

- [ ] `git tag -a v2.0.0 -m "..."` created the tag locally
- [ ] `git push origin v2.0.0` pushed the tag to `marcfargas/go-mapi`
- [ ] `installer-release.yml` run reaches `conclusion: success`
- [ ] `curl -IL https://github.com/marcfargas/go-mapi/releases/latest/download/go-mapi-setup.exe` returns 200 with non-empty Content-Length
- [ ] Release notes on the GitHub Releases page contain the SmartScreen walkthrough (auto-appended from `.github/release-template.md`)
- [ ] `gh release view v2.0.0` shows `go-mapi-setup.exe` as an attached asset

**If the release workflow fails:** inspect the run logs, identify the
specific failure (MinGW install, Inno Setup compile, artifact upload,
release publish), and open a follow-up fix plan. Do NOT delete the
tag — leaving a failed-release tag in place is fine.

**If the URL returns 404:** wait 60-90 seconds for GitHub Releases
CDN propagation. If still 404, check `gh release view v2.0.0` to
confirm the asset is actually attached.

---

## REL-06: Manual UAT on a real Windows box

### Environment

Either of:

- **marcwin** (preferred) — real Windows box with Admin rights. Fast iteration.
- **Windows Sandbox** via `tests/sandbox/README.md` — fallback if marcwin unavailable or a clean slate is wanted between UAT attempts. Note: the sandbox has no Gmail OAuth cookies, so the OAuth flow must be completed inside the sandbox each time.

### Procedure

Open `.planning/phases/05-release-cut/05-UAT.md` in your editor. That
file is the structured checklist — fill in the result fields as you
go. This section is a summary; the UAT file is the authoritative
record.

1. **Download** `go-mapi-setup.exe` from the published Release (URL just verified in REL-05).
2. **SmartScreen walkthrough** — confirm "More info" -> "Run anyway" works as documented in README.md and the release notes.
3. **UAC + installer wizard** — confirm exactly one UAC prompt and the wizard completes.
4. **Load the browser extension** from the release ZIP asset (or the Chrome Web Store listing if live).
5. **Observe the host-state transition** — with the extension loaded BEFORE the host was installed, the `InstallPrompt` should disappear within ~6 seconds of install completion, and the one-time success toast should appear (EXT-06, verified after PHASE-4-FINDING-01 fix on develop).
6. **Trigger a real MAPI call** — Notepad File -> Send -> Mail recipient, or any Win32 app with the legacy "Send to -> Mail recipient" context menu.
7. **Confirm a Gmail draft appears** in the target account's Drafts folder. THIS IS THE SHIPPING GATE.
8. **Uninstall + cleanup** — Settings -> Apps -> go-mapi -> Uninstall removes all state and restores the previous default Mail client.

### If UAT fails

Any deviation is either:

- **Fixed on develop** — land a fix commit, cut a new `v2.0.1` tag (per D-05, NEVER re-use `v2.0.0`), re-run the release workflow, re-run UAT.
- **Documented in 05-UAT.md** as a known limitation shipped in v2.0.0 — acceptable only if genuinely minor with a workaround.
- **Explicitly deferred to v2.1.0** with a reason — acceptable if scope creep rather than a ship blocker.

### REL-06 sign-off checklist

- [ ] `05-UAT.md` completed and committed to `develop`
- [ ] All UAT checklist items passed, OR deviations explicitly documented and dispositioned
- [ ] A Gmail draft was successfully created end-to-end from a Win32 app
- [ ] The install -> use -> uninstall -> verify-clean cycle was exercised at least once

---

## REL-07: Re-archive the v2.0.0 milestone

### Preconditions

- [ ] REL-05 complete: `v2.0.0` tag pushed, `installer-release.yml` green, release URL returns 200
- [ ] REL-06 complete: `05-UAT.md` committed with all checklist items passed (or explicit deviations documented)
- [ ] `git status` on `develop` is clean

### Rationale (D-07)

The previous autonomous-run milestone archival was rolled back via
`git reset --hard 9f72f42` because it archived "source complete" as
"shipped" — a meaning error, not a structural one. The `v2.0.0` tag
was also deleted at that point. After REL-05 + REL-06 pass, the
milestone is genuinely shipped and the archival now reflects the
runtime-verified state.

### Re-run the milestone lifecycle

```bash
# From the repo root on develop:
/gsd:complete-milestone v2.0.0
```

This GSD command:
1. Creates/updates `.planning/MILESTONES.md` with a v2.0.0 entry reflecting the runtime-verified state (all 7 Phase 5 REL-* items green, three CI workflows green, UAT passed).
2. Moves Phase 1-5 directories under `.planning/milestones/v2.0.0-phases/`.
3. Updates `.planning/STATE.md`: `status: milestone_complete`, archived milestone, decision log entry.
4. Updates `.planning/v2.0.0-MILESTONE-AUDIT.md` (or replaces it) so the audit reflects runtime-verified status instead of `tech_debt`.
5. Commits with `docs(milestone): archive v2.0.0`.

### Verification

```bash
grep -q "milestone_complete" .planning/STATE.md
test -f .planning/MILESTONES.md && grep -q "^## v2.0.0" .planning/MILESTONES.md
test -d .planning/milestones/v2.0.0-phases || test -d .planning/milestones/v2.0.0
git log --oneline -5  # should show the archival commit
```

### REL-07 sign-off checklist

- [ ] `/gsd:complete-milestone v2.0.0` completed successfully
- [ ] `.planning/STATE.md` contains `milestone_complete`
- [ ] `.planning/MILESTONES.md` contains a v2.0.0 entry
- [ ] Phase directories archived under `.planning/milestones/v2.0.0-*/`
- [ ] Archival commit pushed to `origin/develop`
- [ ] v2.0.0 tag still exists on develop (from REL-05 — do NOT delete it; tags are append-only)

**If archival fails:** the GSD command is idempotent — re-run it.
For partial archives, roll back with `git reset --hard origin/develop`
and re-invoke. Do NOT manually edit `STATE.md` or `MILESTONES.md` to
paper over a failure.
