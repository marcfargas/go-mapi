---
phase: 05-release-cut
plan: 04
type: execute
wave: 2
depends_on: [05-01, 05-02, 05-03]
files_modified:
  - .planning/phases/05-release-cut/05-MANUAL-STEPS.md
  - .planning/phases/05-release-cut/05-UAT.md
autonomous: false
requirements: [REL-05, REL-06, REL-07]
must_haves:
  truths:
    - "Marc has a documented step-by-step sequence for pushing the v2.0.0 tag and verifying installer-release.yml publishes go-mapi-setup.exe (REL-05)"
    - "The REL-05 verification is grep-concrete: curl -IL on the releases/latest/download URL returns HTTP 200 with non-empty Content-Length"
    - "A filled-in 05-UAT.md template exists with the exact manual UAT checklist (download, install, load extension, observe MISSING-to-READY, Send to Mail recipient, confirm Gmail draft) per REL-06"
    - "The REL-07 section documents the exact /gsd:complete-milestone v2.0.0 invocation and lists STATE.md + MILESTONES.md post-conditions"
    - "The MANUAL-STEPS.md REL-05/06/07 sections are inserted into the placeholder headings Plan 01 left behind, not appended at the end"
  artifacts:
    - path: ".planning/phases/05-release-cut/05-MANUAL-STEPS.md"
      provides: "Completed runbook for REL-05, REL-06, REL-07"
      contains: "git push origin v2.0.0"
    - path: ".planning/phases/05-release-cut/05-UAT.md"
      provides: "End-to-end UAT checklist template with result capture fields"
      contains: "UAT Session"
  key_links:
    - from: "05-MANUAL-STEPS.md REL-05 section"
      to: "git tag v2.0.0 + git push origin v2.0.0"
      via: "explicit command block"
      pattern: "git push origin v2.0.0"
    - from: "05-MANUAL-STEPS.md REL-05 verification"
      to: "https://github.com/marcfargas/go-mapi/releases/latest/download/go-mapi-setup.exe"
      via: "curl -IL check"
      pattern: "curl -IL"
    - from: "05-MANUAL-STEPS.md REL-06 section"
      to: "05-UAT.md"
      via: "link to the checklist template"
      pattern: "05-UAT\\.md"
    - from: "05-MANUAL-STEPS.md REL-07 section"
      to: "/gsd:complete-milestone v2.0.0"
      via: "documented GSD command invocation"
      pattern: "gsd.complete-milestone v2\\.0\\.0"
---

<objective>
Produce the two artifacts Marc needs for the final Phase 5 manual sequence: append the REL-05 (tag push + release publication), REL-06 (manual UAT checklist handoff), and REL-07 (milestone re-archive) sections to the `05-MANUAL-STEPS.md` runbook that Plan 01 created, and create a standalone `05-UAT.md` checklist template that Marc fills in during the UAT session. This plan does NOT execute the tag push, run the UAT, or re-run `/gsd:complete-milestone` — those three steps are Marc-owned manual work (per D-02) done in sequence after Wave 1 completes and CI has been triggered and green-lit via the REL-01 section. Everything here is a documentation deliverable Marc executes himself.

Purpose: The v2.0.0 ship ritual needs to be one document Marc can follow top to bottom. Scattering the tag push across one file, the UAT checklist across another, and the milestone re-archive across a third creates friction at the final ship gate.
Output: Appended `05-MANUAL-STEPS.md` sections + new `05-UAT.md` checklist + a completed Phase 5 runbook structure.
</objective>

<execution_context>
@C:/dev/go-mapi/.claude/get-shit-done/workflows/execute-plan.md
@C:/dev/go-mapi/.claude/get-shit-done/templates/summary.md
</execution_context>

<context>
@.planning/ROADMAP.md
@.planning/REQUIREMENTS.md
@.planning/phases/05-release-cut/05-CONTEXT.md
@.planning/v2.0.0-MILESTONE-AUDIT.md
@.planning/phases/05-release-cut/05-MANUAL-STEPS.md
@.github/workflows/installer-release.yml
@.github/release-template.md
@src/extension/src/popup/InstallPrompt.tsx

<interfaces>
Release workflow trigger surface (from .github/workflows/installer-release.yml):
- Trigger: on push tags 'v*' — the tag push is the authoritative trigger
- Tag parsing: ${GITHUB_REF#refs/tags/} -> v2.0.0 -> SEMVER=2.0.0
- Native host version: go build -ldflags "-X main.Version=2.0.0"
- Signing: every SignPath step gated on `if: env.SIGNPATH_API_TOKEN != ''` (unsigned fallback when absent — D-01)
- Release body: body_path .github/release-template.md with append_body: true
- Output asset: go-mapi-setup.exe attached to the release
- Stable URL: https://github.com/marcfargas/go-mapi/releases/latest/download/go-mapi-setup.exe

Previously-rolled-back state (from D-07 in 05-CONTEXT.md):
- Autonomous-run milestone archival reverted via `git reset --hard 9f72f42`
- The v2.0.0 tag was deleted (was pointing at a rolled-back commit)
- REL-07 re-runs /gsd:complete-milestone against the runtime-verified state

Placeholder headings left in 05-MANUAL-STEPS.md by Plan 01 Task 2:
- "## REL-05: Push v2.0.0 tag and verify release publication" (+ "*(Filled in by Plan 04.)*")
- "## REL-06: Manual UAT on a real Windows box" (+ "*(Filled in by Plan 04. UAT checklist lives in `05-UAT.md`.)*")
- "## REL-07: Re-archive the v2.0.0 milestone" (+ "*(Filled in by Plan 04.)*")
This plan REPLACES each placeholder line with its full section content. It does NOT append at EOF.
</interfaces>
</context>

<tasks>

<task type="auto">
  <name>Task 1: Append REL-05 / REL-06 / REL-07 sections to 05-MANUAL-STEPS.md</name>
  <files>.planning/phases/05-release-cut/05-MANUAL-STEPS.md</files>
  <read_first>
    - .planning/phases/05-release-cut/05-MANUAL-STEPS.md (ENTIRE file — produced by Plan 01 Task 2; confirm exact placeholder line format before editing)
    - .github/workflows/installer-release.yml (tag-push trigger, SignPath gate, release body handling, output artifact path)
    - .github/release-template.md (release body — REL-05 section notes this auto-appends via `append_body: true`)
    - .planning/v2.0.0-MILESTONE-AUDIT.md (current audit state — REL-07 replaces/updates it with the runtime-verified version)
  </read_first>
  <action>
    Use the Edit tool three times on `.planning/phases/05-release-cut/05-MANUAL-STEPS.md`.

    **Edit 1 — REL-05 section.** Replace the exact line `*(Filled in by Plan 04.)*` that follows `## REL-05: Push v2.0.0 tag and verify release publication` with the following block (preserve 4-space indentation inside code fences where shown):

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

    **Edit 2 — REL-06 section.** Replace the exact line `*(Filled in by Plan 04. UAT checklist lives in `05-UAT.md`.)*` that follows `## REL-06: Manual UAT on a real Windows box` with:

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

    **Edit 3 — REL-07 section.** Replace the exact line `*(Filled in by Plan 04.)*` that follows `## REL-07: Re-archive the v2.0.0 milestone` with:

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

    Commit with: `docs(05-04): append REL-05/06/07 sections to Phase 5 runbook (REL-05, REL-06, REL-07)`
  </action>
  <verify>
    <automated>grep -q "git push origin v2.0.0" .planning/phases/05-release-cut/05-MANUAL-STEPS.md</automated>
  </verify>
  <acceptance_criteria>
    - `grep -q "git push origin v2.0.0" .planning/phases/05-release-cut/05-MANUAL-STEPS.md` matches
    - `grep -q "git tag -a v2.0.0" .planning/phases/05-release-cut/05-MANUAL-STEPS.md` matches
    - `grep -q "curl -IL https://github.com/marcfargas/go-mapi/releases/latest/download/go-mapi-setup.exe" .planning/phases/05-release-cut/05-MANUAL-STEPS.md` matches
    - `grep -q "gh run watch" .planning/phases/05-release-cut/05-MANUAL-STEPS.md` matches
    - `grep -q "05-UAT.md" .planning/phases/05-release-cut/05-MANUAL-STEPS.md` matches
    - `grep -q "/gsd:complete-milestone v2.0.0" .planning/phases/05-release-cut/05-MANUAL-STEPS.md` matches
    - `grep -q "milestone_complete" .planning/phases/05-release-cut/05-MANUAL-STEPS.md` matches
    - `grep -c "sign-off checklist" .planning/phases/05-release-cut/05-MANUAL-STEPS.md` returns `>= 4` (REL-01 from Plan 01 + REL-05/06/07 here)
    - `grep -q "Filled in by Plan 04" .planning/phases/05-release-cut/05-MANUAL-STEPS.md` returns NO match (all placeholders replaced)
    - `grep -q "v2.0.0-rc" .planning/phases/05-release-cut/05-MANUAL-STEPS.md` returns NO match (D-05 — no RC tags)
    - `grep -q "SIGNPATH_API_TOKEN" .planning/phases/05-release-cut/05-MANUAL-STEPS.md` matches (ship-unsigned rationale explicit)
  </acceptance_criteria>
  <done>
    `05-MANUAL-STEPS.md` is a complete Phase 5 runbook Marc can follow top-to-bottom from CI triggering through milestone re-archive.
  </done>
</task>

<task type="auto">
  <name>Task 2: Create 05-UAT.md — manual UAT checklist template with result capture fields</name>
  <files>.planning/phases/05-release-cut/05-UAT.md</files>
  <read_first>
    - .planning/REQUIREMENTS.md REL-06 (required UAT steps — download, install, load extension, observe MISSING->READY+toast, trigger Send to Mail recipient, confirm Gmail draft)
    - .planning/phases/04-test-suite-completeness-e2e/04-FINDINGS.md (PHASE-4-FINDING-01 — the MISSING->READY toast fix must be verified manually since E2E-04 does not assert it)
    - .planning/phases/05-release-cut/05-CONTEXT.md (D-01 ship-unsigned — UAT confirms SmartScreen walkthrough; D-05 tag v2.0.0)
    - README.md (the install flow rewritten by Plan 03; UAT steps should match README verbatim so testing what users actually read)
  </read_first>
  <action>
    Create `.planning/phases/05-release-cut/05-UAT.md` with the content below using the Write tool. This is a fill-in-the-blank checklist template — Marc edits the bracketed placeholders during the UAT session and commits the result to `develop` as the REL-06 authoritative record.

    File contents to write:

        # Phase 5 UAT: v2.0.0 Manual End-to-End Verification (REL-06)

        **Tester:** Marc Fargas
        **Environment:** [marcwin / Windows Sandbox — circle one]
        **Date:** [YYYY-MM-DD]
        **Installer URL tested:** https://github.com/marcfargas/go-mapi/releases/latest/download/go-mapi-setup.exe
        **Installer SHA256:** [run `(Get-FileHash go-mapi-setup.exe -Algorithm SHA256).Hash` and paste here]
        **Browser used:** [Chrome / Edge / Chromium / Brave / Vivaldi — circle one]
        **Target Gmail account:** [e.g. marc@example.com — just for your own record]

        ---

        ## Pre-conditions

        - [ ] REL-05 complete: `installer-release.yml` run for `v2.0.0` reached `conclusion: success`
        - [ ] `curl -IL https://github.com/marcfargas/go-mapi/releases/latest/download/go-mapi-setup.exe` returned HTTP 200 with a non-empty `Content-Length`
        - [ ] The UAT host is a CLEAN state: go-mapi not currently installed, no stale registry under `HKLM\SOFTWARE\Clients\Mail\go-mapi`, no files under `%ProgramFiles%\go-mapi\` or `%ProgramData%\go-mapi\`
        - [ ] A Gmail or Google Workspace account is signed in to the browser being used

        ---

        ## UAT Session

        ### Step 1 — Download

        Visit `https://github.com/marcfargas/go-mapi/releases/latest` in the browser. Click the `go-mapi-setup.exe` asset.

        - [ ] Download completes without errors
        - [ ] Downloaded file size matches `content-length` from the `curl -IL` preflight
        - [ ] **Observed file size:** [bytes]

        ### Step 2 — SmartScreen walkthrough (unsigned fallback — D-01)

        Double-click `go-mapi-setup.exe` from the Downloads folder.

        - [ ] **"Windows protected your PC"** dialog appears (expected; v2.0.0 ships unsigned)
        - [ ] Click **More info** — publisher line appears ("Unknown publisher")
        - [ ] Click **Run anyway** — dialog dismisses
        - [ ] IF the dialog does NOT appear: note below (possibly Defender already saw the file; not a blocker, but record it)
        - [ ] **Notes:** [free text]

        ### Step 3 — UAC + installer wizard

        - [ ] Exactly ONE UAC prompt appears (per INST-04)
        - [ ] Clicking **Yes** launches the Inno Setup wizard
        - [ ] Wizard completes without error dialogs
        - [ ] Final "Installation completed successfully" screen appears
        - [ ] **Wall-clock time from launch to wizard completion:** [seconds]

        ### Step 4 — Post-install filesystem state

        Open PowerShell (non-elevated is fine):

        ```powershell
        Test-Path 'C:\Program Files\go-mapi\go-mapi.dll'
        Test-Path 'C:\Program Files\go-mapi\go-mapi-host.exe'
        Test-Path 'C:\ProgramData\go-mapi\com.gomapi.host.json'
        Test-Path 'C:\ProgramData\go-mapi\uninst\previous-mail-client.json'
        ```

        - [ ] All four paths return `True`
        - [ ] **Notes:** [free text if any return False]

        ### Step 5 — Post-install registry state

        ```powershell
        Test-Path 'HKLM:\SOFTWARE\Clients\Mail\go-mapi'
        Test-Path 'HKLM:\SOFTWARE\Google\Chrome\NativeMessagingHosts\com.gomapi.host'
        Test-Path 'HKLM:\SOFTWARE\Microsoft\Edge\NativeMessagingHosts\com.gomapi.host'
        Test-Path 'HKLM:\SOFTWARE\Chromium\NativeMessagingHosts\com.gomapi.host'
        Test-Path 'HKLM:\SOFTWARE\BraveSoftware\Brave-Browser\NativeMessagingHosts\com.gomapi.host'
        Test-Path 'HKLM:\SOFTWARE\Vivaldi\NativeMessagingHosts\com.gomapi.host'
        ```

        - [ ] All six paths return `True`
        - [ ] `(Get-ItemProperty 'HKLM:\SOFTWARE\Clients\Mail').'(Default)'` returns `go-mapi`
        - [ ] **Notes:** [free text]

        ### Step 6 — Load the browser extension

        From the browser chosen at the top of this file:

        1. Open `chrome://extensions` (or the equivalent)
        2. Enable **Developer mode**
        3. Click **Load unpacked** and select the `dist/` folder from the unpacked release ZIP (or install from the Chrome Web Store listing if it's live)
        4. Click the go-mapi extension icon in the toolbar to open the popup

        - [ ] Extension loads without errors in `chrome://extensions`
        - [ ] Popup opens when clicking the toolbar icon
        - [ ] **Initial popup state:** [MISSING / PROBING / READY — circle one]

        ### Step 7 — Host-state transition + success toast (EXT-06 / PHASE-4-FINDING-01)

        This step verifies the MISSING -> READY transition and the one-time success toast that PHASE-4-FINDING-01 fixed at the end of Phase 4.

        **If the initial popup state in Step 6 was READY** — go-mapi was already discovered on first popup open. Skip to Step 8 and note that the toast could not be observed on this run (the toast only fires on the live MISSING -> READY edge). To exercise this path, close the browser, uninstall go-mapi, re-open the browser first, then re-install — but this is optional.

        **If the initial popup state was MISSING or PROBING:**

        - [ ] Within ~6 seconds (one reconnect alarm cycle), the popup transitions to READY
        - [ ] The `InstallPrompt` banner disappears
        - [ ] A one-time **"go-mapi is installed"** success toast appears
        - [ ] Closing and reopening the popup does NOT show the toast again (one-time only via `hasShownInstalledToast` latch)
        - [ ] **Notes:** [free text]

        ### Step 8 — Real MAPI trigger (the shipping gate)

        1. Open Notepad (or any Win32 app with a "Send to Mail recipient" shell integration).
        2. Type some placeholder text.
        3. Save to a file so File Explorer knows about it.
        4. In File Explorer, right-click the saved file -> **Send to** -> **Mail recipient**.

        **Expected result:** Within a second or two, the go-mapi extension popup (if open) shows a new email entry. If the popup is closed, the extension badge updates to show the queue count.

        - [ ] Right-click -> Send to -> Mail recipient does NOT show an error dialog
        - [ ] The extension popup / badge reflects the new email within ~2 seconds
        - [ ] Click the email in the popup to preview it
        - [ ] The preview shows the attached file(s) as a draft body with attachment metadata
        - [ ] **Notes:** [free text]

        ### Step 9 — Gmail draft creation

        Click **Save as Draft** in the extension popup.

        - [ ] The "Save as Draft" action succeeds without showing an error toast
        - [ ] Open `https://mail.google.com/mail/u/0/#drafts` in the same browser
        - [ ] A new draft appears at the top of the Drafts list, authored from the go-mapi-triggered action
        - [ ] The draft contains the attachment(s) from the file that was right-clicked
        - [ ] **Gmail draft ID (from URL after clicking the draft):** [optional, for record-keeping]

        **This step is the v2.0.0 shipping gate.** If the draft appears in Gmail, the end-to-end flow works and Phase 5 passes UAT.

        ### Step 10 — Uninstall + cleanup

        Windows **Settings -> Apps -> Installed apps -> go-mapi -> Uninstall**.

        - [ ] Uninstall wizard launches with one UAC prompt
        - [ ] Uninstall completes without error dialogs

        After uninstall:

        ```powershell
        Test-Path 'C:\Program Files\go-mapi\go-mapi.dll'        # expect False
        Test-Path 'C:\ProgramData\go-mapi\com.gomapi.host.json' # expect False
        Test-Path 'HKLM:\SOFTWARE\Clients\Mail\go-mapi'         # expect False
        Test-Path 'HKLM:\SOFTWARE\Google\Chrome\NativeMessagingHosts\com.gomapi.host'  # expect False
        ```

        - [ ] All four checks return `False`
        - [ ] Previous default Mail client (if any) restored from the backup file (INST-05/INST-06)
        - [ ] **Notes:** [free text]

        ---

        ## UAT Disposition

        Select ONE:

        - [ ] **PASSED** — all steps green, Gmail draft created, clean uninstall. v2.0.0 ships.
        - [ ] **PASSED WITH NOTES** — all critical steps green, minor deviations documented above but not blocking. v2.0.0 ships. List deviations:
          - [free text]
        - [ ] **FAILED** — a critical step failed. A fix is required before v2.0.0 ships. Next action:
          - [ ] Fix on develop, cut new `v2.0.1` tag (per D-05, NEVER re-use `v2.0.0`), re-run `installer-release.yml`, re-run this UAT against the new installer.
          - [ ] Failure details: [free text]

        **Ship decision:** [SHIP / BLOCK — circle one]
        **Signed off by:** Marc Fargas
        **Signed off at:** [timestamp]

        ---

        *This file is the REL-06 authoritative record. Commit it to `develop` before running REL-07.*

    Commit with: `docs(05-04): add 05-UAT.md manual UAT checklist template (REL-06)`
  </action>
  <verify>
    <automated>test -f .planning/phases/05-release-cut/05-UAT.md</automated>
  </verify>
  <acceptance_criteria>
    - `test -f .planning/phases/05-release-cut/05-UAT.md` succeeds
    - `grep -q "^## UAT Session" .planning/phases/05-release-cut/05-UAT.md` matches
    - `grep -q "Send to" .planning/phases/05-release-cut/05-UAT.md` matches
    - `grep -q "Gmail draft" .planning/phases/05-release-cut/05-UAT.md` matches
    - `grep -q "SmartScreen" .planning/phases/05-release-cut/05-UAT.md` matches
    - `grep -q "MISSING" .planning/phases/05-release-cut/05-UAT.md` matches
    - `grep -q "READY" .planning/phases/05-release-cut/05-UAT.md` matches
    - `grep -q "Uninstall" .planning/phases/05-release-cut/05-UAT.md` matches
    - `grep -q "PASSED" .planning/phases/05-release-cut/05-UAT.md` matches
    - `grep -q "FAILED" .planning/phases/05-release-cut/05-UAT.md` matches
    - `grep -q "Ship decision" .planning/phases/05-release-cut/05-UAT.md` matches
    - `grep -c "\\[ \\]" .planning/phases/05-release-cut/05-UAT.md` returns `>= 30` (the checklist has many checkbox items)
    - `grep -q "com.gomapi.host" .planning/phases/05-release-cut/05-UAT.md` matches (registry verification documented)
  </acceptance_criteria>
  <done>
    Marc has a fill-in-the-blank UAT checklist ready to open when he sits down at marcwin for the manual verification session.
  </done>
</task>

</tasks>

<threat_model>
## Trust Boundaries

| Boundary | Description |
|----------|-------------|
| developer terminal → GitHub API (via `git push` of annotated tag) | Tag push requires Marc's write credentials; carries only the annotated tag message, no secrets |
| GitHub Actions runner → repository secrets | `SIGNPATH_*` secrets ABSENT by design (D-01); workflow takes SIGN-03 unsigned fallback path |
| Marc's UAT host (marcwin or Sandbox) → downloaded installer | Downloaded installer is executed with Admin privileges; source is the public GitHub Release |
| Marc's UAT host → Gmail API | OAuth-mediated, existing flow from Phase 1-4 |

## STRIDE Threat Register

| Threat ID | Category | Component | Disposition | Mitigation Plan |
|-----------|----------|-----------|-------------|-----------------|
| T-05-04-01 | Spoofing | Marc installs the wrong installer (phishing URL) | mitigate | `05-UAT.md` Pre-conditions section pins the exact URL and requires a `curl -IL` verification before the download step. The URL is cross-referenced against `InstallPrompt.tsx:5` and `.github/release-template.md:7` by the REL-05 section. |
| T-05-04-02 | Tampering | Compromised `installer-release.yml` workflow injecting malware into `go-mapi-setup.exe` | mitigate | `installer-release.yml` was reviewed in Phase 3 (`03-VERIFICATION.md` §SIGN-02/SIGN-03). All build steps run on GitHub-hosted `windows-latest` runners with `permissions: contents: write` only. The REL-05 section documents `gh run watch` so Marc sees the full build log before tagging a release as the shipped version. Post-REL-05, the on-disk installer SHA256 is captured in `05-UAT.md` Step 1 for later comparison if a security question arises. |
| T-05-04-03 | Information Disclosure | `SIGNPATH_API_TOKEN` leaking in release workflow logs | accept | Token is not set (D-01 ships unsigned). The signing steps are gated on `if: env.SIGNPATH_API_TOKEN != ''` and no-op when absent. `Note unsigned fallback` step emits a CI warning but no token content. Verified in `03-VERIFICATION.md`. |
| T-05-04-04 | Repudiation | UAT result disputed later ("did we actually test this?") | mitigate | `05-UAT.md` is a committed artifact on `develop` with Marc's sign-off timestamp and the specific installer SHA256 tested. Git history is the audit trail. |
| T-05-04-05 | DoS | Release workflow timing out or hitting GitHub API rate limits | accept | The workflow runs once per release; rate limits don't apply. Runner timeout is the workflow default (`timeout-minutes: 360` implicit). If it times out, re-run via `workflow_dispatch` with the matching version input. |
| T-05-04-06 | Elevation of Privilege | Installer elevation prompt misused to install a modified binary | mitigate | Marc verifies the download against the URL and (optionally) the SHA256. The UAT procedure explicitly tests the install on a clean host with a clean starting state, so any unexpected post-install registry entries or files would be noticed in Steps 4-5. |
| T-05-04-07 | Tampering | User training themselves to click through SmartScreen on all installers | mitigate | `05-UAT.md` Step 2 documents that this is an expected unsigned-fallback behavior specific to v2.0.0, tied to D-01. The signed v2.0.1 re-cut is the mitigation path — UAT is temporary tolerance, not a permanent stance. |
| T-05-04-08 | Information Disclosure | `/gsd:complete-milestone` committing internal project paths or secrets | accept | The GSD command is a project-internal planning tool. Its output (`MILESTONES.md`, `STATE.md`, phase archives) has been reviewed in prior milestones and contains no secrets. Commit is to the public `develop` branch; all content is already public. |
</threat_model>

<verification>
- `test -f .planning/phases/05-release-cut/05-MANUAL-STEPS.md` succeeds and all REL-05/06/07 acceptance-criteria greps match
- `test -f .planning/phases/05-release-cut/05-UAT.md` succeeds and all checklist acceptance-criteria greps match
- `grep -q "Filled in by Plan 04" .planning/phases/05-release-cut/05-MANUAL-STEPS.md` returns NO match (all three placeholder lines replaced)
- Phase 5 goal-backward check: after the four plans, Marc has: (1) CI trigger commands to run from `gh`, (2) a hardened sandbox harness for local repro, (3) a non-dev-oriented README, (4) a tag push + release verification procedure, (5) a fill-in UAT checklist, (6) a milestone re-archive procedure. Every REL-01..07 has a concrete landing place.
- Decision coverage: D-01 (ship unsigned) captured in MANUAL-STEPS REL-05 + UAT Step 2; D-02 (Marc-owned) captured via `autonomous: false`; D-05 (no RC tags) captured as grep anti-pattern; D-07 (re-archive rationale) captured in REL-07 section.
</verification>

<success_criteria>
REL-05, REL-06, and REL-07 all have executable, Marc-followable documentation. The Phase 5 runbook (`05-MANUAL-STEPS.md`) and UAT template (`05-UAT.md`) are the complete set of artifacts needed to take v2.0.0 from "wave-1 plans merged + CI green" to "shipped, UAT-verified, milestone archived" with nothing left to interpret.
</success_criteria>

<output>
After completion, create `.planning/phases/05-release-cut/05-04-SUMMARY.md` per the standard summary template.
</output>
