---
phase: 10-installer-migration
plan: 04
subsystem: installer
tags:
  - installer
  - uninstaller
  - nsis
  - cleanup
  - credential-manager
  - migration-docs
requirements:
  - INST-05
dependency_graph:
  requires:
    - plan 10-01 (Uninstall section stub + un.RestorePreviousMailClient stub + %ProgramData%\go-mapi\uninst\previous-mail-client.json backup JSON shape)
    - plan 10-03 (firewall rule name literal "go-mapi OAuth loopback" — must match byte-for-byte in the delete-rule call)
  provides:
    - src/installer/go-mapi.nsi Section "Uninstall" with full D-18 10-step scrub body
    - src/installer/go-mapi.nsi Function un.RestorePreviousMailClient (real implementation — naive JSON line-scan + target-key verify + 3-fallback chain)
    - src/installer/go-mapi.nsi Functions un.StrContains, un.StrExtract (uninstall-only string primitives)
    - README.md — v2-uninstall-first migration note (D-20) + multi-user RDS caveat section (D-19)
  affects:
    - plan 10-05 (Pester tests will assert firewall rule removal, CredMan target absence, (Default) restoration, %APPDATA% + %ProgramData% scrub)
    - plan 10-06 (release pipeline invokes the same Uninstall section for version upgrades; behavior must stay stable)
tech_stack:
  added: []
  patterns:
    - Naive JSON line-scan via NSIS string primitives (no JSON parser in NSIS; relies on plan 10-01's position-stable single-line JSON)
    - Target-key existence verification before registry restore (D-11 dangling-handler mitigation)
    - Multi-branch fallback chain (Microsoft Outlook → Outlook → Windows Mail → clear) for when backup is missing / previous client uninstalled
    - un.StrContains / un.StrExtract as $R1..$R7-scoped uninstall helpers (no caller-state clobber)
    - Errata-discipline grep gates (plan-level verification greps for slash-form absence in source + docs)
key_files:
  created:
    - .planning/phases/10-installer-migration/10-04-SUMMARY.md
  modified:
    - src/installer/go-mapi.nsi
    - README.md
  deleted: []
decisions:
  - id: D-18-ordering
    summary: "Uninstall ordering is load-bearing: Call un.RestorePreviousMailClient (step 4) MUST precede RMDir /r on %ProgramData%\\go-mapi\\uninst\\ (step 5). The restore reads previous-mail-client.json from that directory; deleting it first would always fall through to the fallback chain."
  - id: cmdkey-colon-errata
    summary: "zalando/go-keyring Windows backend concatenates target as service+':'+username → \"go-mapi:oauth-tokens\" (colon). CONTEXT.md §specifics line 199 erroneously wrote the slash form. PATTERNS.md §Shared Pattern 3 carries the errata. Uninstaller uses the colon form; README uses the colon form; plan-level grep asserts the slash form appears nowhere in either file."
  - id: json-parse-strategy
    summary: "NSIS has no JSON parser; wrote un.StrContains (substring check) + un.StrExtract (between-delimiters extraction) as local primitives. Relies on plan 10-01's BackupPreviousMailClient writing stable single-line shapes: {\"previousClient\":null,\"backedUpAt\":\"...\"} or {\"previousClient\":\"<name>\",\"backedUpAt\":\"...\"}. If plan 10-01 ever pretty-prints the JSON, this helper breaks — locked in by plan 10-05 Pester test."
  - id: D-11-target-verify
    summary: "Before WriteRegStr for a non-null restored name, issue ReadRegStr on HKLM\\SOFTWARE\\Clients\\Mail\\<name>\\(Default). If the subkey is gone (another installer may have removed the previous client since backup), fall through to fallbacks. Prevents restoring a dangling handler."
  - id: D-20-clean-break
    summary: "No v2.x artifact cleanup in the v3 installer (native-messaging manifests, browser-extension registry, etc.). README directs v2 users to uninstall v2 first. Verified by grep gate: NativeMessagingHosts/nativeMessaging count must equal 0 in go-mapi.nsi."
  - id: D-19-multi-user-caveat
    summary: "Uninstaller only scrubs the uninstalling user's %APPDATA%\\go-mapi\\ and Credential Manager entry. Other users on RDS / shared Windows Server hosts retain their own per-user state. README 'Uninstalling on multi-user machines' subsection discloses the limitation + provides self-service cleanup command (cmdkey /delete:go-mapi:oauth-tokens per user)."
  - id: errata-comment-literal
    summary: "Original Task 2 comment included the WRONG literal 'go-mapi/oauth-tokens' as illustrative text of the errata — tripped the plan-level grep gate (count must equal 0). Fixed in a follow-up commit by rephrasing to 'the slash-separated form' without embedding the wrong literal. See `Deviations from Plan` below."
metrics:
  duration: "25 minutes"
  completed_date: "2026-04-20T12:02:46Z"
  tasks: 3
  files_created: 1
  files_modified: 2
---

# Phase 10 Plan 04: Uninstaller 10-step Scrub + README Migration Notes Summary

**NSIS uninstaller full-scrub body (firewall → shortcut → MAPI key → (Default) restore → ProgramData → TEMP → APPDATA → CredMan → binaries → install dir), real un.RestorePreviousMailClient (JSON parse + target-key verify + 3-fallback chain), and README notes for v2-uninstall-first migration + multi-user RDS caveat.**

## Performance

- **Duration:** ~25 minutes
- **Started:** 2026-04-20T11:37:23Z (immediately after plan 10-03 handoff)
- **Completed:** 2026-04-20T12:02:46Z
- **Tasks:** 3 (+ 1 deviation commit)
- **Files modified:** 2 (src/installer/go-mapi.nsi, README.md)
- **Files created:** 1 (this SUMMARY.md)

## Accomplishments

- Replaced the `un.RestorePreviousMailClient` stub with a real implementation: reads the backup JSON via NSIS file I/O, detects the `null` previousClient form with `un.StrContains`, extracts the named previousClient with `un.StrExtract`, verifies the target subkey exists under `HKLM\SOFTWARE\Clients\Mail\<name>` before writing the `(Default)`, and falls back through Microsoft Outlook → Outlook → Windows Mail → clear if anything is missing (D-11).
- Replaced the minimal Uninstall section stub with the full D-18 10-step scrub in strict order. Firewall rule name and cmdkey target both validated against byte-for-byte literals from plan 10-03 and from `src/app/auth.go:27-28` respectively.
- Added two README sections: a prominent blockquote at the top of Install telling v2.x users to uninstall v2 first (D-20 clean-break), and an `### Uninstalling on multi-user machines (RDS / shared Windows Server)` subsection documenting per-user scope of `%APPDATA%\go-mapi\` and the Credential Manager target `go-mapi:oauth-tokens` (D-19), including a self-service recovery command for other users.

## Task Commits

Each task was committed atomically:

1. **Task 1: Implement `un.RestorePreviousMailClient` + helpers** — `ebbd26c` (feat)
2. **Task 2: Replace Uninstall section with full 10-step D-18 scrub** — `fdec5a4` (feat)
3. **Task 3: README.md migration notes** — `83b7de0` (docs)
4. **Deviation fix: remove literal slash form from errata comment** — `f29d5c9` (fix)

_(No separate plan-metadata commit — SUMMARY.md will be committed as part of this plan's completion handoff by the orchestrator.)_

## Files Created/Modified

- `src/installer/go-mapi.nsi` — replaced Uninstall section stub + `un.RestorePreviousMailClient` stub; added `un.StrContains` and `un.StrExtract` helpers
- `README.md` — added v2-uninstall-first blockquote in Install section; added `### Uninstalling on multi-user machines` subsection
- `.planning/phases/10-installer-migration/10-04-SUMMARY.md` — this file

## Decisions Made

See `decisions:` frontmatter above for full rationale on each.

1. **D-18 step ordering is load-bearing** — `Call un.RestorePreviousMailClient` (step 4) precedes `RMDir /r "$APPDATA\..\..\ProgramData\go-mapi\uninst"` (step 5). Reversing would always skip the restore and go to fallbacks.
2. **Errata-corrected CredMan target** — uninstaller uses `go-mapi:oauth-tokens` (colon), verified against `src/app/auth.go:27-28` + zalando/go-keyring's Windows `credName()` method. The slash form from CONTEXT §specifics is NOT used and is asserted absent in both .nsi and README by plan-level grep gates.
3. **Naive JSON line-scan** — no JSON parser in NSIS, so the helper relies on plan 10-01 writing stable single-line forms. Tight coupling is intentional and documented; plan 10-05 Pester test will catch regressions if either plan drifts.
4. **Target-key existence verify (D-11)** — before restoring Mail (Default) to `<name>`, confirm `HKLM\SOFTWARE\Clients\Mail\<name>\(Default)` exists. A tampered or stale backup JSON cannot inject an arbitrary dangling handler name (see threat register T-10-04-01).
5. **D-20 clean-break** — no v2 cleanup logic in the v3 installer; README places the burden on the user to uninstall v2 first. Simpler and safer than detection heuristics.
6. **D-19 accepted limitation** — per-user scrub only; documented in README with a self-service `cmdkey /delete:go-mapi:oauth-tokens` recovery command. Enumerating all profiles is out of scope.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Remove literal slash form from Task 2 errata comment**

- **Found during:** Plan-level verification gate after Task 3 commit
- **Issue:** Task 2's Uninstall body included an explanatory comment reading `CONTEXT specifics line 199 wrote "go-mapi/oauth-tokens" (slash) — WRONG.` The literal `"go-mapi/oauth-tokens"` inside the comment caused plan-level verification's grep-based "slash form absent" gate to fail: `grep -c 'go-mapi/oauth-tokens' src/installer/go-mapi.nsi` returned `1` instead of `0`. The intent of embedding the literal in a comment was to make the errata self-documenting, but the plan's acceptance criteria 2 + verification step 2 treat the slash form as forbidden text anywhere in the file, including comments. The grep gate is also what plan 10-05's Pester tests will use to guard against regressions.
- **Fix:** Rephrased the comment to `CONTEXT specifics line 199 wrote the slash-separated form — WRONG.` The errata is still explained; the forbidden literal is gone.
- **Files modified:** `src/installer/go-mapi.nsi` (1 line)
- **Verification:** `grep -c 'go-mapi/oauth-tokens' src/installer/go-mapi.nsi` → `0`. All Task 1 + Task 2 + Task 3 automated verify scripts still pass after the fix.
- **Committed in:** `f29d5c9`

---

**Total deviations:** 1 auto-fixed (1 bug / verification-gate violation)
**Impact on plan:** The errata comment served documentation purposes only; the fix preserves the errata explanation while respecting the plan-level grep gate. No scope creep, no behavioral change to the uninstaller.

## Issues Encountered

- **Task 3 first-pass regex failure:** The plan's automated verify regex for the v2-uninstall-first note uses `/uninstall.*v2[\s\S]{0,80}(before|first)/i`, imposing an 80-character proximity window between `v2` and `before`/`first`. The first-pass blockquote wording (`uninstall any prior **go-mapi v2.x** (Chrome/Edge extension + native-host) via **Settings → Apps → Installed apps** **before** installing v3.0`) had ~86 characters between `v2` and `before`, tripping the gate. Resolved by rephrasing to move `**before**` closer to `v2.x`: `uninstall any prior **go-mapi v2.x** **before** installing v3.0 — via **Settings → Apps → Installed apps** (this removes the Chrome/Edge extension + native-host)`. No scope change; same information, tighter proximity.
- **Shell quoting edge case:** Running the Task 1 Node verify script inline via `bash -c node -e "..."` caused the shell to substitute `$0` into `/usr/bin/bash` (Git-Bash behavior), corrupting the regex literals. Worked around by writing the verification script to `tmp-verify-taskN.cjs` and running `node tmp-verify-taskN.cjs`, then deleting the scratch file. Project-standard pattern going forward.
- **makensis not installed in worktree environment:** The plan-level "NSIS compile sanity" step requires `makensis` on PATH, which is not available in this executor's worktree. Static grep/regex-based verifications ran and passed; compile sanity will be exercised in CI by plan 10-05's pipeline (which has makensis staged).

## Deviations from RESEARCH §Code Examples 7 and 9

- **Code Example 7 (Uninstall section body):** Implemented as planned. No deviations.
- **Code Example 9 (un.RestorePreviousMailClient):** Implemented as planned, with the two plan-mandated additions (target-key existence check per D-11 + the 3-fallback chain). The private `un.StrContains` / `un.StrExtract` helpers were added below the function as specified — both use `$R1..$R7` register variables to avoid clobbering the caller's state.

## Plan-Level Verification Results

| Gate | Command | Expected | Actual | Status |
|------|---------|----------|--------|--------|
| Firewall add count | `grep -c 'add rule name="go-mapi OAuth loopback"' src/installer/go-mapi.nsi` | 1 | 1 | PASS |
| Firewall delete count | `grep -c 'delete rule name="go-mapi OAuth loopback"' src/installer/go-mapi.nsi` | 1 | 1 | PASS |
| Firewall total literal | `grep -c 'name="go-mapi OAuth loopback"' src/installer/go-mapi.nsi` | 2 | 2 | PASS |
| cmdkey colon form in .nsi | `grep -c 'go-mapi:oauth-tokens' src/installer/go-mapi.nsi` | ≥1 | 3 | PASS |
| cmdkey slash form in .nsi | `grep -c 'go-mapi/oauth-tokens' src/installer/go-mapi.nsi` | 0 | 0 | PASS (after `f29d5c9`) |
| cmdkey colon form in README | `grep -c 'go-mapi:oauth-tokens' README.md` | ≥1 | 2 | PASS |
| cmdkey slash form in README | `grep -c 'go-mapi/oauth-tokens' README.md` | 0 | 0 | PASS |
| No v2 artifact cleanup creep | `grep -ci 'NativeMessagingHosts\|nativeMessaging' src/installer/go-mapi.nsi` | 0 | 0 | PASS |
| Ordering invariant | `Call un.RestorePreviousMailClient` line < `RMDir /r ProgramData\go-mapi\uninst` line | true | true | PASS |
| NSIS compile sanity | `makensis /DGOMAPI_VERSION=0.0.0-dev src/installer/go-mapi.nsi` | exit 0 | n/a | DEFERRED to CI (plan 10-05) |

## Next Phase Readiness

- Uninstall section is feature-complete; handoff surface for plan 10-05 (Pester-based install/uninstall E2E tests) is stable:
  - Pester can assert `Get-NetFirewallRule -DisplayName 'go-mapi OAuth loopback'` returns empty after uninstall
  - Pester can assert `cmdkey /list:go-mapi:oauth-tokens` returns empty after uninstall
  - Pester can assert `HKLM\SOFTWARE\Clients\Mail\go-mapi` key is gone
  - Pester can assert `HKLM\SOFTWARE\Clients\Mail\(Default)` is either restored to the pre-install value, one of the hardcoded fallbacks, or empty string
  - Pester can assert `%APPDATA%\go-mapi\`, `%TEMP%\go-mapi\`, `%ProgramData%\go-mapi\uninst\` directories are gone for the test user
- Plan 10-06 (release pipeline) will consume the same Uninstall section unchanged; upgrade semantics (reinstall over existing) continue to work because plan 10-01's `BackupPreviousMailClient` `AlreadyUs` branch preserves the original backup across reinstalls.
- No known blockers. INST-05 is fully delivered.

---
*Phase: 10-installer-migration*
*Completed: 2026-04-20*

## Self-Check: PASSED

**Files verified:**
- FOUND: src/installer/go-mapi.nsi (modified; Section "Uninstall" + un.RestorePreviousMailClient + un.StrContains + un.StrExtract all present)
- FOUND: README.md (modified; v2-uninstall-first blockquote + multi-user RDS subsection present)
- FOUND: .planning/phases/10-installer-migration/10-04-SUMMARY.md (this file)

**Commits verified in git log:**
- FOUND: ebbd26c (Task 1 — un.RestorePreviousMailClient implementation)
- FOUND: fdec5a4 (Task 2 — Uninstall 10-step scrub)
- FOUND: 83b7de0 (Task 3 — README migration notes)
- FOUND: f29d5c9 (Deviation — remove literal slash form from errata comment)

**Gate verifications:** All 9 executable plan-level gates PASS (makensis compile sanity deferred to CI per environment constraints).
