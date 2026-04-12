---
phase: 05-release-cut
plan: 01
type: execute
wave: 1
depends_on: []
files_modified:
  - src/interceptor/json_writer.h
  - .planning/phases/05-release-cut/05-MANUAL-STEPS.md
autonomous: false
requirements: [REL-01, REL-04]
must_haves:
  truths:
    - "The pre-existing -Wcomment warning in json_writer.h:36 no longer appears in GCC/MinGW builds (REL-04)"
    - "Marc has a single documented sequence of gh workflow run commands to trigger installer-smoke.yml, e2e.yml, and go-race-nightly.yml on develop (REL-01)"
    - "Each CI trigger in the docs has an exact gh run list --json conclusion command to confirm the run succeeded"
  artifacts:
    - path: "src/interceptor/json_writer.h"
      provides: "Warning-free comment on line 36"
      contains: "/temp/go-mapi/"
    - path: ".planning/phases/05-release-cut/05-MANUAL-STEPS.md"
      provides: "Executable command sequence for Marc"
      contains: "## REL-01: Trigger CI workflows"
  key_links:
    - from: "05-MANUAL-STEPS.md"
      to: ".github/workflows/installer-smoke.yml"
      via: "gh workflow run installer-smoke.yml --ref develop"
      pattern: "gh workflow run installer-smoke.yml"
    - from: "05-MANUAL-STEPS.md"
      to: ".github/workflows/e2e.yml"
      via: "gh workflow run e2e.yml --ref develop"
      pattern: "gh workflow run e2e.yml"
    - from: "05-MANUAL-STEPS.md"
      to: ".github/workflows/go-race-nightly.yml"
      via: "gh workflow run go-race-nightly.yml --ref develop"
      pattern: "gh workflow run go-race-nightly.yml"
---

<objective>
Close PHASE-4-FINDING-02 with a one-line fix to `src/interceptor/json_writer.h:36` so the `-Wcomment` warning stops appearing in MinGW/GCC CPPTEST-02 builds, and create `05-MANUAL-STEPS.md` documenting the exact `gh workflow run` command sequence Marc will execute from his authenticated terminal to trigger and green-light the three CI workflows (`installer-smoke.yml`, `e2e.yml`, `go-race-nightly.yml`) on `develop`. The json_writer.h fix lands before the first CI run so CPPTEST-02's build output is clean on the first-ever green run. The MANUAL-STEPS document is the executor-side output for REL-01, since `gh` auth is not available inside the executor sandbox (per D-02).

Purpose: Phase 5's first wave needs the trailing-backslash comment fixed so CI output is not noisy on REL-01's first run, and it needs a single reference document that Marc can keep open during the Phase 5 manual sequence.
Output: Fixed header file, committed MANUAL-STEPS.md with REL-01 commands and expected outcomes.
</objective>

<execution_context>
@C:/dev/go-mapi/.claude/get-shit-done/workflows/execute-plan.md
@C:/dev/go-mapi/.claude/get-shit-done/templates/summary.md
</execution_context>

<context>
@.planning/ROADMAP.md
@.planning/REQUIREMENTS.md
@.planning/phases/05-release-cut/05-CONTEXT.md
@.planning/phases/04-test-suite-completeness-e2e/04-FINDINGS.md
@.planning/phases/04-test-suite-completeness-e2e/04-E2E-SPIKE.md
@.github/workflows/installer-smoke.yml
@.github/workflows/e2e.yml
@.github/workflows/go-race-nightly.yml
@src/interceptor/json_writer.h

<interfaces>
<!-- The current (broken) line 36 reads:
//     // Write a MailMessage to a JSON file in %TEMP%\go-mapi\
// The trailing '\' before the newline is a line-continuation marker inside a C++ line comment,
// which GCC interprets as "the comment continues onto the next source line" and emits -Wcomment.
-->
Relevant CI workflow triggers (from .github/workflows/*.yml):
- installer-smoke.yml  → workflow_dispatch {}  (path: .github/workflows/installer-smoke.yml)
- e2e.yml              → workflow_dispatch:    (path: .github/workflows/e2e.yml)
- go-race-nightly.yml  → workflow_dispatch:    (path: .github/workflows/go-race-nightly.yml)

All three accept `gh workflow run <filename> --ref develop` with no additional inputs.
</interfaces>
</context>

<tasks>

<task type="auto">
  <name>Task 1: Close PHASE-4-FINDING-02 (REL-04) — fix trailing backslash in json_writer.h line 36</name>
  <files>src/interceptor/json_writer.h</files>
  <read_first>
    - src/interceptor/json_writer.h (full file, confirm the exact line 36 text before editing)
    - .planning/phases/04-test-suite-completeness-e2e/04-FINDINGS.md (PHASE-4-FINDING-02 section for rationale + suggested fixes)
  </read_first>
  <action>
    Use the Edit tool on `src/interceptor/json_writer.h` to replace EXACTLY the line:

        // Write a MailMessage to a JSON file in %TEMP%\go-mapi\

    with:

        // Write a MailMessage to a JSON file in %TEMP%/go-mapi/

    Rationale (per PHASE-4-FINDING-02 fix option "forward slash"): the trailing `\` at end-of-line inside a `//` comment is interpreted by GCC as a line-continuation into the next physical source line, triggering `-Wcomment`. Switching to forward slashes removes both backslashes in one go and has zero runtime/behavior impact (it is a comment). Do NOT change any other line. Do NOT reformat the file. Do NOT touch `json_writer.cpp`.

    Verification from the shell (run from repo root):

        grep -n 'go-mapi' src/interceptor/json_writer.h | head -5

    should show line 36 containing `%TEMP%/go-mapi/` and no trailing `\` before end-of-line on that line.

    Commit with: `fix(05-01): close PHASE-4-FINDING-02 — json_writer.h -Wcomment (REL-04)`
  </action>
  <verify>
    <automated>grep -n "go-mapi" src/interceptor/json_writer.h | grep -q "%TEMP%/go-mapi/" &amp;&amp; ! grep -nE "go-mapi\\\\$" src/interceptor/json_writer.h</automated>
  </verify>
  <acceptance_criteria>
    - `grep -n "%TEMP%/go-mapi/" src/interceptor/json_writer.h` returns a match on line 36
    - `grep -nE "go-mapi\\\\$" src/interceptor/json_writer.h` returns NO matches (no trailing backslash inside any // comment)
    - `git diff src/interceptor/json_writer.h` shows exactly one line changed (no whitespace churn)
    - No other `.cpp`/`.h` file in `src/interceptor/` was modified by this task
  </acceptance_criteria>
  <done>
    json_writer.h line 36 no longer triggers `-Wcomment` under GCC/MinGW. REL-04 closes on commit.
  </done>
</task>

<task type="auto">
  <name>Task 2: Author 05-MANUAL-STEPS.md — REL-01 section (gh workflow run commands)</name>
  <files>.planning/phases/05-release-cut/05-MANUAL-STEPS.md</files>
  <read_first>
    - .planning/phases/05-release-cut/05-CONTEXT.md (D-02: why CI triggers are Marc-owned; Claude's Discretion note endorsing documented-commands approach)
    - .github/workflows/installer-smoke.yml (confirm it has `workflow_dispatch: {}` and the job name `smoke`)
    - .github/workflows/e2e.yml (confirm it has `workflow_dispatch:` and the job name `e2e`)
    - .github/workflows/go-race-nightly.yml (confirm it has `workflow_dispatch:` and the job name `go-race`)
    - .planning/phases/04-test-suite-completeness-e2e/04-E2E-SPIKE.md §"Unresolved risks" (five risks to watch on the first e2e.yml run — Defender latency, mock-gmail stdin hang, extension ID instability, etc.)
  </read_first>
  <action>
    Create `.planning/phases/05-release-cut/05-MANUAL-STEPS.md` with the structure below. This file is the Phase 5 runbook Marc opens in one terminal window when he sits down to ship. Plan 04 will later append REL-05/REL-06/REL-07 sections; this task writes the REL-01 section only, plus the skeleton headings so the later plan has clear insertion points.

    Full file contents to write (use Write tool):

    ---
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
    ---

    Commit with: `docs(05-01): add Phase 5 MANUAL-STEPS runbook with REL-01 section (REL-01)`
  </action>
  <verify>
    <automated>test -f .planning/phases/05-release-cut/05-MANUAL-STEPS.md &amp;&amp; grep -q "^## REL-01:" .planning/phases/05-release-cut/05-MANUAL-STEPS.md &amp;&amp; grep -q "gh workflow run installer-smoke.yml --ref develop" .planning/phases/05-release-cut/05-MANUAL-STEPS.md &amp;&amp; grep -q "gh workflow run e2e.yml --ref develop" .planning/phases/05-release-cut/05-MANUAL-STEPS.md &amp;&amp; grep -q "gh workflow run go-race-nightly.yml --ref develop" .planning/phases/05-release-cut/05-MANUAL-STEPS.md</automated>
  </verify>
  <acceptance_criteria>
    - File `.planning/phases/05-release-cut/05-MANUAL-STEPS.md` exists
    - Contains heading `## REL-01: Trigger the three CI workflows on develop`
    - Contains literal string `gh workflow run installer-smoke.yml --ref develop`
    - Contains literal string `gh workflow run e2e.yml --ref develop`
    - Contains literal string `gh workflow run go-race-nightly.yml --ref develop`
    - Contains placeholder headings `## REL-05:`, `## REL-06:`, and `## REL-07:` (so Plan 04 has stable insertion points)
    - Contains the first-run flake watch list referencing `04-E2E-SPIKE.md`
    - Contains a REL-01 sign-off checklist with three "success" conditions
  </acceptance_criteria>
  <done>
    Marc can copy-paste the REL-01 section into his terminal to trigger all three workflows, and has a documented procedure for handling first-run flakes without rewriting the phase.
  </done>
</task>

</tasks>

<threat_model>
## Trust Boundaries

| Boundary | Description |
|----------|-------------|
| developer terminal → GitHub API (via gh CLI) | Workflow dispatch carries `GITHUB_TOKEN` scope on the runner, secrets are not in the client request |
| GitHub Actions runner → repository secrets | `SIGNPATH_*` secrets are absent during the Phase 5 unsigned fallback run, which is by design (D-01) |

## STRIDE Threat Register

| Threat ID | Category | Component | Disposition | Mitigation Plan |
|-----------|----------|-----------|-------------|-----------------|
| T-05-01-01 | Information Disclosure | REL-01 CI trigger logs | accept | The three workflows run against public `develop`; no secrets in logs. `installer-smoke.yml` runs without SignPath secrets (dispatch-triggered on non-tag). `e2e.yml` has no secrets at all. `go-race-nightly.yml` has no secrets. No logs reference credentials. |
| T-05-01-02 | Elevation of Privilege | REL-01 on fork PRs | accept | `workflow_dispatch` requires write access to the repo. Forks cannot dispatch. Marc is the sole maintainer; no external dispatch surface. |
| T-05-01-03 | Tampering | json_writer.h fix scope | mitigate | Task 1 acceptance criteria pin the change to exactly one line via `git diff` check. No behavior change possible — the edit is inside a `//` comment. |
| T-05-01-04 | Repudiation | MANUAL-STEPS.md authenticity | accept | File is committed to `develop`; git history is the audit trail. Marc is the only operator. |
</threat_model>

<verification>
- `grep -n "%TEMP%/go-mapi/" src/interceptor/json_writer.h` returns line 36
- `grep -nE "go-mapi\\\\$" src/interceptor/json_writer.h` returns nothing
- `test -f .planning/phases/05-release-cut/05-MANUAL-STEPS.md` succeeds
- `grep -c "gh workflow run" .planning/phases/05-release-cut/05-MANUAL-STEPS.md` returns >= 3
- Commits on `develop`: one `fix(05-01): ...` and one `docs(05-01): ...`
</verification>

<success_criteria>
REL-04 closed by source fix. REL-01 documented as an executable command sequence Marc can run from an authenticated `gh` terminal to trigger and sign off on the three `windows-latest` CI workflows. This plan does NOT execute the CI triggers — that is a separate Marc-owned manual step done between Wave 1 and Wave 2.
</success_criteria>

<output>
After completion, create `.planning/phases/05-release-cut/05-01-SUMMARY.md` per the standard summary template.
</output>
