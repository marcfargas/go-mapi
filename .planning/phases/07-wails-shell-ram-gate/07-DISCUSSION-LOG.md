# Phase 7: Wails Shell + RAM Gate - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-04-13
**Phase:** 07-wails-shell-ram-gate
**Areas discussed:** RAM measurement methodology, Main window content, Codebase structure migration, Tray menu + icon scope + RAM gate failure contingency

---

## RAM Measurement Methodology

### Q1: Which memory counter should be the pass/fail metric?

| Option | Description | Selected |
|--------|-------------|----------|
| Private Working Set | Private pages in physical RAM. Excludes shared WebView2/Edge runtime pages — fair for RDS where 30 instances share runtime. Matches Task Manager "Memory (private working set)". | ✓ |
| Working Set (total) | All physical pages including shared. Overcounts WebView2 shared runtime once per instance — would make RDS case look 30× worse than reality. | |
| Commit Size / Private Bytes | Virtual commit charge. Includes paged-out memory. More stable but does not reflect actual pressure on the server. | |

### Q2: How to simulate RDS conditions for the measurement?

| Option | Description | Selected |
|--------|-------------|----------|
| Hetzner Windows Server VM, N sessions | Real RDS with 5–10 concurrent user sessions on Windows Server 2022. Closest to production. | ✓ |
| Workstation: launch N instances under one user | Simpler but different — no HDESKTOP isolation, WebView2 may share more. Under-reports RDS case. | |
| Single instance on workstation, extrapolate ×N | Cheapest. Loses "does WebView2 share across sessions?" answer. | |

### Q3: Measurement protocol — when and how many samples?

| Option | Description | Selected |
|--------|-------------|----------|
| Cold start + 5-min idle + after first window toggle, 3 runs | Three data points cover startup cost, steady state, post-WebView2-init. Averaged over 3 runs. | ✓ |
| Single 5-min idle reading per scenario | Simplest. Misses cold-start spike + post-init steady state. | |
| Long-soak (1h idle) with 60s sampling | Catches memory growth/leaks. Overkill for a gate. | |

---

## Main Window Content

### Q1: What should the main window show in Phase 7?

| Option | Description | Selected |
|--------|-------------|----------|
| Minimal live queue list, no actions | SHELL-06 folds watcher in anyway — render sender/subject/timestamp updating via Wails events. Validates event pipeline + RAM under real rendering load; Phase 9 adds actions. | ✓ |
| Welcome/status placeholder | Static "shell works" card. Smaller surface area; risks under-measuring RAM. | |
| Empty window (chrome only) | Just titlebar + empty pane. Cheapest; exercises no Svelte rendering. | |

### Q2: Window toggle behavior?

| Option | Description | Selected |
|--------|-------------|----------|
| Left-click = show + focus; click when visible = hide | Standard Windows tray pattern (OneDrive, Teams). Matches SHELL-02 + SHELL-03. | ✓ |
| Left-click = always show (never hides from tray click) | Simpler but feels broken; rejected pattern in modern Windows tray apps. | |
| Single-click focuses; double-click required to show first time | Two-step; less discoverable. | |

---

## Codebase Structure Migration

### Q1: How to introduce the Wails app into the codebase in Phase 7?

| Option | Description | Selected |
|--------|-------------|----------|
| New src/app/ alongside existing src/native-host/ | New changesets workspace. Reuse watcher/protocol/gmail by import. Keeps native-host buildable for rollback. Lowest merge risk. | ✓ |
| Move src/native-host/ into src/app/ (full absorb) | ARCHITECTURE.md end state. Biggest rename in Phase 7 — risks turning RAM-gate phase into a rename phase. | |
| Duplicate needed files into src/app/ | Avoids import coupling but creates divergence window — bugfixes applied twice. | |

### Q2: How should shared Go code be reached from the new Wails app?

| Option | Description | Selected |
|--------|-------------|----------|
| Extract to internal/ Go package, import from both | Single source of truth. Clean boundary. | ✓ |
| Import src/native-host/ packages directly from src/app/ | Quicker but couples new app to old workspace layout. | |
| Defer extraction — copy-paste in Phase 7, refactor later | Ships fastest but guarantees churn in Phase 9. | |

---

## Tray Menu + Icon Scope + RAM Gate Failure Contingency

### Q1: Tray right-click menu contents in Phase 7?

| Option | Description | Selected |
|--------|-------------|----------|
| Show + Quit only | Minimal. Pause-watching deferred to Phase 9. Explicit deviation from SHELL-02 wording — Phase 9 CONTEXT must pick it up. | ✓ |
| Show + Pause watching + Quit (full SHELL-02) | Adds state + UI in a phase meant to validate RAM. Low value before queue actions exist. | |
| Show + About + Quit | Harmless but not specified in requirements. | |

### Q2: Which tray icon variants in Phase 7?

| Option | Description | Selected |
|--------|-------------|----------|
| Idle + error only | Error = watcher init failure / WebView2 missing. Has-queue deferred to Phase 9. | ✓ |
| Just idle | Simplest. Errors only in logs during Phase 7. | |
| All three (idle + has-queue + error) | Full SHELL-07. Has-queue unused until Phase 9 — over-investment. | |

### Q3: If RAM measurement fails (>80 MB), pre-decided response?

| Option | Description | Selected |
|--------|-------------|----------|
| Halt + /gsd-explore re-evaluation | Document measurement, open dedicated explore session to decide response. No reflexive decision in-phase. | ✓ |
| Auto-fallback: swap to Fyne-native (no WebView2) | Pre-decides next stack without data on whether Fyne hits target or has acceptable UX. | |
| Accept + document deviation, continue to Phase 8 | Violates "hard stop" framing in PROJECT.md / research SUMMARY. | |

---

## Claude's Discretion

- Sample size N for concurrent RDS sessions (5 vs 10)
- RAM-result interpretation (mean vs max of 3 runs)
- Measurement automation format (Pester 5 vs manual Get-Process)
- Tray-icon light/dark variants
- Empty-queue state copy in main window
- Default window size/position; geometry persistence
- Logging location + format for the Wails app
- Exact name of the extracted internal package

## Deferred Ideas

- Pause-watching tray menu item → Phase 9
- Has-queue tray icon variant → Phase 9
- Per-email actions (Create draft / Dismiss) → Phase 9
- OAuth / Gmail draft logic / gmail.go timeout + retry → Phase 8
- WinRT toast notifications + AppUserModelID → Phase 9 + Phase 10
- NSIS installer / WebView2 bootstrapper / Firewall rule / v2.x cleanup → Phase 10
- Autoupdate + extension-store retirement → Phase 11
- Full src/native-host/ absorb into src/app/ → after Phase 7 passes
- Window geometry persistence across restarts → later phase
