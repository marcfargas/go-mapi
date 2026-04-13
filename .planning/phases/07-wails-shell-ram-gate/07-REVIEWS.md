---
phase: 7
reviewers: [codex]
reviewed_at: 2026-04-13T09:45:25Z
plans_reviewed: [07-01-PLAN.md, 07-02-PLAN.md, 07-03-PLAN.md, 07-04-PLAN.md]
note: "Only codex was available; claude skipped (self — running inside Claude Code); gemini/coderabbit/opencode not installed."
---

# Cross-AI Plan Review — Phase 7

## Codex Review

## 07-01-PLAN.md

**Summary**  
Strong foundation plan. It correctly treats the `internal/mapi` extraction as the enabling step for Phase 7 and anchors on behavior preservation plus `-race` verification. The main weakness is module/workspace uncertainty: the plan mixes a separate Go module under `internal/mapi`, `go.work`, and root `go build ./...` expectations in ways that may not work cleanly without first proving the import/layout shape.

**Strengths**
- Clear objective tied directly to `SHELL-06` and `QUAL-04`.
- Good separation of reusable logic from native-messaging-specific code.
- Preserves behavioral invariants that matter: debounce, AV retry, content-hash IDs.
- Explicitly guards against protocol regressions in the legacy native host.
- Includes fixture-path remediation, which is a real extraction risk.
- Verification is serious: `go test -race`, `go vet`, and cross-module build checks.

**Concerns**
- **HIGH**: The module layout is internally inconsistent. `internal/mapi` is described as a separate module, but also as an `internal/` package with import-restriction semantics. A standalone module under `internal/` does not give the usual “only parent tree may import” protection in the way the threat model implies.
- **HIGH**: `go build ./...` from repo root is not a safe acceptance criterion in a multi-module repo unless the exact workspace/module behavior is proven first. This may fail for reasons unrelated to the plan’s correctness.
- **MEDIUM**: Adding `src/app` to `.changeset/config.json` before `src/app/package.json` exists is a coupling hazard and may break repo tooling temporarily.
- **MEDIUM**: The plan says `go.work` should wire `src/app (placeholder)` in truths, but Task 1 explicitly omits it. That mismatch will create confusion/failing checks.
- **MEDIUM**: Exporting `NormalizeAddress` / `NormalizeRecipients` broadens public API surface without confirming external consumers actually need them.
- **LOW**: One-line comment at top of `go.mod` is mentioned; that file format tolerates comments, but this is low-value noise.

**Suggestions**
- Decide the Go layout first and simplify:
  1. Either make `internal/mapi` a normal package under a single root module, or
  2. make it a shared module but stop claiming `internal/` import-boundary protection.
- Replace repo-root `go build ./...` with explicit workspace-safe commands:
  - `go test ./internal/mapi/...`
  - `go test ./src/native-host/...`
- Move `.changeset/config.json` editing to Plan 02 when `src/app` actually exists.
- Tighten the API surface: only export symbols required by `src/native-host` and later `src/app`.
- Make the native-host adapter contract explicit: delta vs snapshot behavior should be proven before refactoring watcher output.

**Risk Assessment**  
**MEDIUM**. The extraction logic is sound, but module/workspace ambiguity is a real execution risk and could stall the phase before any functional progress.

---

## 07-02-PLAN.md

**Summary**  
Good scaffold plan with strong UX constraints and anti-pattern avoidance. It is disciplined about Phase 7 scope and mostly aligned with the UI contract. The main issue is that it mixes “scaffold only” with a lot of packaging/tooling churn, plus a blocking human checkpoint that may be too early and too manual for a still-incomplete shell.

**Strengths**
- Strong scope control: no OAuth, no watcher fold-in, no installer work.
- Correctly locks Wails v2 + `fyne.io/systray` and rejects known bad alternatives.
- Good hide-to-tray lifecycle definition.
- UI contract is concrete and testable.
- Explicitly enforces no React/Bootstrap/icon-library creep.
- Good acknowledgment of left-click uncertainty with fallback path.

**Concerns**
- **HIGH**: `src/app` as both a Go workspace and npm workspace is under-specified. Root `package.json`, `src/app/package.json`, and `src/app/frontend/package.json` responsibilities may conflict, especially with changesets and `npm install` from root.
- **MEDIUM**: The plan assumes `wails init` can be cleanly adapted into the monorepo layout, but Wails scaffolding often has opinions about project root structure. This may cause avoidable churn.
- **MEDIUM**: Human verification is blocking before Plan 03, even though Plan 03 materially changes lifecycle behavior with watcher/single-instance/session-end integration. This risks re-validating too early.
- **MEDIUM**: QUAL-02 “spot check” is weakly defined and may create false confidence if not run on a truly browser-free machine.
- **LOW**: Asset generation workflow is heavy for the value delivered in a RAM-gate phase; SVG+ICO source management is fine, but ImageMagick/Inkscape dependency assumptions are not addressed.

**Suggestions**
- Collapse packaging decisions into a simpler rule:
  - `src/app/go.mod` for Go,
  - `src/app/frontend/package.json` for frontend,
  - only add root workspace wiring if CI/build actually needs it.
- Treat `src/app/package.json` as optional unless changesets truly needs it for version tracking.
- Convert the blocking checkpoint into a non-blocking smoke gate, then do the real user-facing checkpoint after Plan 03.
- Add one explicit “Wails scaffold divergence” fallback:
  - if `wails init` structure conflicts with monorepo conventions, hand-craft the project immediately rather than fighting the generator.
- Define QUAL-02 as “observed on the Hetzner VM in Plan 04”; keep Plan 02 mention informational only.

**Risk Assessment**  
**MEDIUM**. The app scaffold itself is straightforward, but workspace/npm/Wails layout integration could cause unnecessary friction.

---

## 07-03-PLAN.md

**Summary**  
This is the most critical plan and mostly the strongest technically. It covers the real shell behaviors Phase 7 needs: single instance, session-end handling, watcher fold-in, and race safety. The main concerns are Windows lifecycle edge cases and a few implementation assumptions that are too optimistic, especially around `CreateMutex`, `FindWindowW`, message-only window plumbing, and logoff semantics.

**Strengths**
- Directly addresses the remaining phase requirements.
- Good decision to keep `EventsEmit` off the hot watcher path.
- Buffered/coalesced event bridge is the right shape for bursty fsnotify traffic.
- Uses `Local\` mutex scope, which is correct for RDS session isolation.
- Logging path choice is better than `%TEMP%` for per-user isolation.
- Explicit cross-module `-race` verification is appropriate.

**Concerns**
- **HIGH**: `CreateMutex` handling is likely wrong as written. In Win32, `CreateMutex` may return a valid handle while last-error indicates `ERROR_ALREADY_EXISTS`; relying on Go `err` semantics here is risky. This needs exact handling against `GetLastError` behavior in `x/sys/windows`.
- **HIGH**: Raising the existing instance via `FindWindowW(NULL, "go-mapi")` is fragile. Title matching is easy to spoof and may fail if Wails changes title timing/state. A named event or custom message target is safer.
- **HIGH**: `WM_QUERYENDSESSION` handling is underspecified. Returning quickly matters; stopping the watcher synchronously inside the window proc could block logoff. That is a real Windows shutdown risk.
- **MEDIUM**: The hidden message-only window pump may conflict with app shutdown ordering if `DestroyWindow` and `PostQuitMessage` are not coordinated with the correct thread.
- **MEDIUM**: `watcher.Stop()` idempotence is assumed, but the plan relies on it in multiple concurrent shutdown paths. That must be proven in Plan 01 or guarded explicitly.
- **MEDIUM**: The bridge ignores the snapshot payload and refetches via `GetQueue()`. That is fine, but then coalescing semantics should be described as “signal-only”, not “replace-on-write snapshot.”
- **LOW**: `WindowSetAlwaysOnTop(true/false)` to raise/focus can be visually awkward on Windows; acceptable, but worth noting.

**Suggestions**
- Split shutdown semantics clearly:
  - `WM_QUERYENDSESSION` should signal shutdown and return promptly.
  - actual watcher drain/cleanup should happen in a separate controlled path, not inside WndProc.
- Replace title-based raise with a session-scoped named event or registered custom window message if feasible. If not, at least document this as temporary and isolate it behind one interface.
- Add explicit tests for double-stop/double-close behavior on watcher, bridge, and session-end cancel path.
- Verify mutex behavior with `windows.GetLastError()` after `CreateMutex`, not generic `err` handling.
- Add a timeout-bound shutdown helper so logoff does not hang if watcher cleanup stalls.
- Consider moving `queue-error` emission through the same bridge/dispatcher discipline rather than directly from startup goroutine if consistency matters.

**Risk Assessment**  
**HIGH**. This plan is close to correct, but it contains several Windows-specific lifecycle assumptions that can easily fail in production or only under RDS/logoff conditions.

---

## 07-04-PLAN.md

**Summary**  
Good gate plan in principle: it treats RAM measurement as the actual phase outcome and preserves the fail-stop contingency. The biggest problem is measurement validity. The plan is not yet precise enough about what process set is measured, how concurrency is achieved legally on Windows Server, and how pass/fail should be interpreted relative to the real WebView2 process model.

**Strengths**
- Correctly frames this as a hard gate, not a nice-to-have benchmark.
- Captures the right scenarios: cold start, idle before WebView2 init, idle after first window toggle.
- Records mean, max, and variance rather than just a single number.
- Preserves the important contingency: halt and re-evaluate on failure.
- Explicitly validates browser independence on the measurement environment.
- Produces durable artifacts: script, runbook, verification doc.

**Concerns**
- **HIGH**: Measuring only the main `go-mapi` process private working set is probably not sufficient if WebView2 child processes are spawned per session. That risks understating the true per-session RAM cost and invalidating the gate.
- **HIGH**: The fallback from 5–10 sessions to 2 sessions materially weakens the RDS claim. If only 2 admin sessions are used, this should be treated as partial evidence, not full qualification.
- **MEDIUM**: The plan leaves ambiguity around whether to sum WebView2 child processes. That ambiguity should be resolved before execution, not after.
- **MEDIUM**: “Uninstall Edge Chromium” on Windows Server may be impractical or undesirable depending on image/runtime coupling. QUAL-02 should be phrased as “app runs without browser app dependency,” not necessarily require browser removal if OS constraints fight back.
- **MEDIUM**: Updating `STATE.md`/`ROADMAP.md` and committing in the same plan as a manual measurement gate is operationally awkward, especially under an “approval never” environment where git commit may not actually be desirable.
- **LOW**: The legacy docs path `docs/legacy/v3.0-ram-gate-measurement.md` is odd for current-phase output.

**Suggestions**
- Resolve the metric before running:
  - primary metric should likely be per-session sum of `go-mapi.exe` plus session-owned `msedgewebview2.exe` child processes after first window init,
  - report main-process-only as a secondary number if useful.
- If only 2 sessions are possible, explicitly mark QUAL-01 as “provisionally measured, not full RDS-scale validated,” or require a stronger VM/RDS setup before declaring PASS.
- Define how process ownership is mapped per session so data collection is reproducible.
- Separate measurement execution from repo-state updates. The gate result can be documented first; roadmap/state updates should be a follow-up once the result is accepted.
- Replace “uninstall Edge” with “verify no dependency on installed Chrome/Edge browsers; only WebView2 runtime required,” unless actual uninstall is easy and confirmed.
- Add one artifact containing the raw CSV, not just markdown summaries.

**Risk Assessment**  
**HIGH**. The gate is well-scoped, but the measurement methodology as written could produce misleadingly optimistic numbers, which would undermine the phase decision.

---

## Overall Assessment

**Summary**  
The plan set is coherent, well-sequenced, and mostly respects the phase boundary. Plans 01 and 02 establish the codebase shape and shell scaffold appropriately; Plan 03 does the real systems work; Plan 04 treats RAM as the phase gate rather than burying it. The main systemic weakness is not scope creep but execution correctness around Windows-specific lifecycle behavior and RAM methodology. Those two areas need tighter definitions before implementation starts.

**Cross-Plan Strengths**
- Dependency order is mostly correct: extraction → scaffold → shell integration → measurement.
- Good scope discipline around deferred features.
- Strong testing posture, especially `go test -race`.
- Good alignment with the project’s RDS/privacy/browser-independence constraints.
- Anti-patterns are explicitly called out and avoided.

**Cross-Plan Concerns**
- **HIGH**: Go module/workspace structure is not fully settled in Plan 01, but later plans depend heavily on it.
- **HIGH**: Windows shutdown/single-instance behaviors in Plan 03 have multiple subtle failure modes.
- **HIGH**: RAM gate methodology in Plan 04 may undercount the true per-session footprint.
- **MEDIUM**: Too much repo/package/config churn is front-loaded into Plans 01–02.
- **MEDIUM**: Human checkpoints are placed a bit awkwardly relative to when the app is actually representative.

**Cross-Plan Suggestions**
- Resolve module layout first with a short spike before Plan 01 execution.
- Tighten Plan 03 around Win32 correctness and bounded shutdown behavior.
- Redefine Plan 04’s RAM metric to include the actual per-session WebView2 footprint.
- Delay or soften early manual checkpoints until after Plan 03 yields a representative shell.
- Keep changesets/npm workspace edits minimal until `src/app` is real and buildable.

**Overall Risk Assessment**  
**MEDIUM-HIGH**. The planning quality is good, but success depends on two technically sharp edges: Windows shell lifecycle correctness and valid RAM measurement under RDS-like conditions. If those are tightened, the phase is viable.

---

## Consensus Summary

Only one external reviewer (codex) was invoked — no consensus can be cross-checked. Treat the findings below as a **single-source review**, not a consensus. Re-run with additional reviewers (`gemini`, `opencode`) if stronger signal is needed.

### Reviewer-Reported Strengths (codex)
- Dependency ordering is correct: extraction → scaffold → shell integration → measurement.
- Scope discipline around deferred features (no OAuth, no installer, no per-email actions in Phase 7).
- Strong testing posture (`go test -race`, cross-module build checks).
- Alignment with RDS / privacy / browser-independence constraints.
- Anti-patterns explicitly called out and avoided.

### Reviewer-Reported Concerns (codex — no cross-check)

**HIGH severity:**
1. **Go module/workspace shape unresolved (Plan 01).** `internal/mapi` described as both a separate module and an `internal/` package — these have different import-boundary semantics. `go build ./...` from repo root is not safe in a multi-module repo without proving workspace layout first.
2. **`CreateMutex` handling likely wrong (Plan 03).** On Win32, `CreateMutex` returns a valid handle even when `ERROR_ALREADY_EXISTS`; relying on Go `err` semantics instead of `windows.GetLastError()` after the call can misreport single-instance state.
3. **`FindWindowW` title-based raise is fragile (Plan 03).** Title-spoofing risk and locale/timing fragility. Prefer a session-scoped named event or registered custom window message.
4. **`WM_QUERYENDSESSION` handling underspecified (Plan 03).** Stopping the watcher synchronously inside WndProc can block logoff. Must return promptly; drain/cleanup belongs on a separate controlled path with a bounded timeout.
5. **RAM measurement may undercount (Plan 04).** If WebView2 child processes (`msedgewebview2.exe`) are per-session, measuring only the main `go-mapi.exe` private working set understates true per-session cost and invalidates the gate.

**MEDIUM severity:**
6. **`src/app` changesets/npm workspace churn front-loaded into Plan 01** before `src/app/package.json` exists. Move changesets config edits to Plan 02.
7. **Wails `init` template assumptions in Plan 02** may fight monorepo layout; need an explicit "hand-craft if generator conflicts" fallback.
8. **Blocking human checkpoint after Plan 02** re-validates before lifecycle-critical Plan 03 work; consider making it a non-blocking smoke gate and keeping the real user-facing checkpoint after Plan 03.
9. **RDS fallback from 5–10 sessions to 2 sessions (Plan 04)** materially weakens the QUAL-01 claim; should be labeled "provisionally measured" if only 2 sessions.
10. **"Uninstall Edge Chromium" (QUAL-02) may be impractical** on Windows Server. Reframe as "app has no runtime dependency on installed Chrome/Edge browsers; only WebView2 runtime required."
11. **`NormalizeAddress`/`NormalizeRecipients` broadens public API** without proven external consumer need (Plan 01).

**LOW severity:**
12. Asset generation workflow assumes ImageMagick/Inkscape without declaring the dependency (Plan 02).
13. `WindowSetAlwaysOnTop(true/false)` to focus can be visually jarring (Plan 03).
14. Measurement doc path `docs/legacy/v3.0-ram-gate-measurement.md` is odd for current-phase output (Plan 04).

### Divergent Views

N/A — single reviewer.

### Overall Risk (codex)

**MEDIUM-HIGH.** Planning quality good; two sharp edges need tightening: Windows shell lifecycle correctness (Plan 03) and RAM measurement validity (Plan 04).
