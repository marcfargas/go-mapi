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

*(Filled in by Plan 04.)*

---

## REL-06: Manual UAT on a real Windows box

*(Filled in by Plan 04. UAT checklist lives in `05-UAT.md`.)*

---

## REL-07: Re-archive the v2.0.0 milestone

*(Filled in by Plan 04.)*
