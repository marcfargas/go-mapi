---
phase: 09-queue-automode-toasts
plan: "08"
subsystem: frontend-ui-components
tags: [frontend, svelte-runes, segmented-control, error-badge, accessibility, tdd]
dependency_graph:
  requires:
    - phase: 09-07
      provides: settings.ts with Mode + ErrorCategory types; Phase 9 CSS tokens in styles.css
  provides:
    - ModeToggle.svelte: two-segment pill control (Manual / Auto-draft) with full ARIA
    - AutoDraftErrorBadge.svelte: 20x20 red ! circle badge with role=status + category→label mapping
  affects:
    - 09-09 (queue row UI — imports ModeToggle into SignedInHeader; imports AutoDraftErrorBadge into QueueRow)
tech_stack:
  added: []
  patterns:
    - Svelte 5 runes ($props, $derived) for prop-only pure UI components
    - aria-pressed on segmented control segments (true/false string attribute)
    - role=group + aria-label for segmented control container
    - role=status + tabindex=0 for keyboard-focusable live-region badge
    - TDD: test written first, component implemented to make tests green
key_files:
  created:
    - src/app/frontend/src/lib/components/ModeToggle.svelte
    - src/app/frontend/src/lib/components/ModeToggle.test.ts
    - src/app/frontend/src/lib/components/AutoDraftErrorBadge.svelte
    - src/app/frontend/src/lib/components/AutoDraftErrorBadge.test.ts
  modified: []
key-decisions:
  - "ModeToggle active segment click is a no-op (guards with if next === mode return) — prevents redundant onModeChange calls when user clicks the already-selected segment"
  - "AutoDraftErrorBadge uses <span role=status> not <button> — badge is informational, not interactive; tabindex=0 allows keyboard focus for tooltip reading per UI-SPEC accessibility contract"
  - "AutoDraftErrorBadge $derived falls through to 'Gmail error' for the gmail case rather than explicit ternary chain — matches plan spec and avoids dead branch"
  - "Both components use only var(--c-*) tokens from styles.css; zero hard-coded hex values"
metrics:
  duration: "~10 minutes"
  tasks_completed: 2
  tasks_total: 2
  files_created: 4
  files_modified: 0
  tests_added: 12
  tests_passing: 46
  completed: "2026-04-19T16:38:00Z"
requirements_closed: [QUEUE-04, QUEUE-05, QUEUE-06]
---

# Phase 9 Plan 08: ModeToggle + AutoDraftErrorBadge Components Summary

**ModeToggle (2-segment pill with full ARIA) and AutoDraftErrorBadge (20x20 red ! circle with role=status and category-to-label mapping) — 12 new tests, all 46 suite tests passing, svelte-check clean.**

## Performance

- **Duration:** ~10 minutes
- **Started:** 2026-04-19T16:36:00Z
- **Completed:** 2026-04-19T16:38:00Z
- **Tasks completed:** 2/2
- **Tests added:** 12 (7 ModeToggle + 5 AutoDraftErrorBadge)
- **Full suite:** 46 tests passing, 0 failing

## Commits

| Task | Commit | Description |
|------|--------|-------------|
| 1: ModeToggle | `1b3af9c` | feat(09-08): add ModeToggle segmented control component + 7 tests |
| 2: AutoDraftErrorBadge | `c9d1e77` | feat(09-08): add AutoDraftErrorBadge component + 5 tests |

## Tasks Completed

### Task 1: ModeToggle.svelte + ModeToggle.test.ts

Two-segment pill segmented control matching Windows Segmented Button pattern per UI-SPEC §Mode Toggle.

**Key implementation details:**
- Props: `{ mode: Mode, onModeChange: (next: Mode) => void }` via `$props()`
- Container: `<div role="group" aria-label="Draft mode">` with `display:inline-flex; border:1px solid var(--c-border); border-radius:4px; overflow:hidden`
- Each `<button type="button">` has `aria-pressed={mode === 'segment-value'}` (renders as "true"/"false" string)
- Active segment: `background:var(--c-accent); color:white; font-weight:600`; inactive: `background:var(--c-surface-alt); color:var(--c-text); font-weight:400`
- Click on inactive calls `onModeChange(next)`; click on active is guarded (`if (next === mode) return`)
- Focus-visible: `outline:2px solid var(--c-accent); outline-offset:-2px`
- Zero hard-coded hex values; 6 `var(--c-*)` token uses

**Tests (7):** renders labels, container role+aria-label, aria-pressed when mode=manual, aria-pressed when mode=auto-draft, click inactive fires onModeChange, click active is no-op, click auto-draft when already auto-draft is no-op.

### Task 2: AutoDraftErrorBadge.svelte + AutoDraftErrorBadge.test.ts

20x20 red circle badge with `!` glyph for auto-draft failure indication per UI-SPEC §AutoDraft Error Badge.

**Key implementation details:**
- Props: `{ category: ErrorCategory }` via `$props()`
- `$derived` label lookup: `signed-out` → `Signed out`, `network` → `Network error`, `gmail` → `Gmail error`
- `<span role="status" tabindex="0" title={label} aria-label={"Auto-draft failed: " + label}>!`
- Positioned absolutely (parent QueueRow in Plan 09 must be `position:relative`)
- Background: `var(--c-destructive)`; focus ring: `var(--c-accent)`
- Zero hard-coded hex values

**Tests (5):** renders `!`, role=status + tabindex=0, signed-out maps title + aria-label, network maps title, gmail maps title.

## Deviations from Plan

None — plan executed exactly as written. Component code matches the plan's `<action>` blocks verbatim.

## Known Stubs

None. Both components are purely presentational — they receive typed props and render them faithfully. No hardcoded data, no placeholder text other than the intentional fallback label strings specified in the UI-SPEC Copywriting Contract.

## Threat Flags

No new network endpoints, auth paths, file access patterns, or schema changes introduced. Both components are purely presentational Svelte UI — they receive typed props and render DOM. No threat surface expansion beyond what the plan's threat model covers.

## Self-Check: PASSED

- [x] `src/app/frontend/src/lib/components/ModeToggle.svelte` exists
- [x] `src/app/frontend/src/lib/components/ModeToggle.test.ts` exists
- [x] `src/app/frontend/src/lib/components/AutoDraftErrorBadge.svelte` exists
- [x] `src/app/frontend/src/lib/components/AutoDraftErrorBadge.test.ts` exists
- [x] Commit `1b3af9c` exists (ModeToggle)
- [x] Commit `c9d1e77` exists (AutoDraftErrorBadge)
- [x] `role="group" aria-label="Draft mode"` present in ModeToggle.svelte (line 15)
- [x] `aria-pressed` present in ModeToggle.svelte (lines 20, 29)
- [x] `var(--c-*)` count in ModeToggle.svelte: 6 (no hex)
- [x] `role="status"` present in AutoDraftErrorBadge.svelte (line 17)
- [x] 3 label strings present in AutoDraftErrorBadge.svelte
- [x] `var(--c-destructive)` in AutoDraftErrorBadge.svelte (line 31)
- [x] 0 hex matches in both component files
- [x] Full vitest suite: 46/46 passing
- [x] svelte-check: 0 errors (2 warnings, both pre-existing or expected per UI-SPEC)
