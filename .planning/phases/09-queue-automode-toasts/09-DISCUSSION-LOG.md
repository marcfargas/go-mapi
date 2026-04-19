# Phase 9: Queue, Automode + Toasts - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-04-19
**Phase:** 09-queue-automode-toasts
**Areas discussed:** Queue row + actions, Toast stack + AUMID path, Automode goroutine + failure UX, Pause-watching + has-queue icon

---

## Queue row + actions

### Q1: How should Create draft / Dismiss buttons appear on each queue row?
| Option | Description | Selected |
|--------|-------------|----------|
| Inline, always visible | Two buttons on the right edge of every row, always visible. Zero discovery friction; uses more horizontal space. | ✓ |
| Hover-reveal + focus | Buttons appear on row hover or keyboard focus. Cleaner idle view, feels modern; discovery cost for non-mouse users. | |
| Expand-on-click | Row click expands to show recipients + attachments + action buttons. Richer context on demand; adds a step. | |

**User's choice:** Inline, always visible.

### Q2: How should attachment count render on a queue row?
| Option | Description | Selected |
|--------|-------------|----------|
| Icon + count, hidden when zero | 📎 2 inline when attachments exist; no slot when zero. Minimal clutter. | ✓ |
| Always-on count ("0 attachments") | Count always visible; predictable layout but cluttered for no-attachment case. | |
| Icon only (no number) | 📎 glyph when any attachments exist. Loses count information. | |

**User's choice:** Icon + count, hidden when zero.

### Q3: What should happen when the user clicks on the row body (not a button)?
| Option | Description | Selected |
|--------|-------------|----------|
| Nothing (buttons only) | Row body is inert. Every action is explicit via buttons. Simplest mental model. | ✓ |
| Expand / collapse detail | Reveals recipients + attachment filenames. No body preview (privacy). | |
| Open Gmail draft URL | If email is already drafted, row click opens the draft in Gmail. | |

**User's choice:** Nothing (buttons only).

### Q4: What feedback does the UI give after 'Create draft' succeeds on a row?
| Option | Description | Selected |
|--------|-------------|----------|
| Row disappears (silent) | MarkProcessed deletes JSON, row vanishes on next queue-update. | |
| Row fades with '✓ Drafted' flash | Row stays briefly (~1.5s) with a transient checkmark then fades. | |
| Row disappears + toast | Toast fires on every draft regardless of window state. | |

**User's choice (freeform):** Conditional — if UI open, row fades with flash; if UI hidden, toast fires.
**Notes:** Smart split. Keeps the UI quiet when the user is watching and adds signal when they aren't. Recorded as D-04 in CONTEXT.md and applied to automode draft-success as well.

---

## Toast stack + AUMID path

### Q1: Which toast library should Phase 9 lock in for v3.0?
| Option | Description | Selected |
|--------|-------------|----------|
| go-toast/toast (PowerShell XML) | Mature, widely used, zero CGO. ~200ms PowerShell startup per toast. | |
| Direct WinRT via golang.org/x/sys/windows | Native path; faster; proper callback channel. More code; may need Phase 10 COM registration. | |
| Claude researches + picks | Defer to gsd-phase-researcher who surveys current Win11-toast Go library state. | |

**User's choice (freeform):** Defer to researcher. "PowerShell per toast is not nice; find other options; make sure Wails does not already provide this."
**Notes:** Recorded as D-05 with hard constraints — no PowerShell-per-toast; verify Wails v2.12.0 doesn't already ship a helper; RDS/RDP primacy carries to library selection.

### Q2: What should Phase 9 do about Action Center persistence (AUMID) during `wails dev`?
Initial question answered with a meta-question: "why do we want AUMID at all?"

Agent explanation provided (NOTIF-04 requires AC persistence; unpackaged Win32 apps without AUMID + Start Menu shortcut lose AC entries immediately; RDS AUMID works per-session via HKCU).

Re-asked question:
| Option | Description | Selected |
|--------|-------------|----------|
| Dev helper script | scripts/register-dev-aumid.ps1 creates HKCU shortcut with dev AUMID. | ✓ |
| Accept no-AC persistence in dev | Toasts flash + disappear in dev; manual UAT via installer. | |
| Register at app startup (unified dev + prod) | App self-writes HKCU registration on first run. | |

**User's choice:** Dev helper script.
**Notes:** Recorded as D-06. Suggested AUMID: `com.marcfargas.gomapi.dev` for dev, `com.marcfargas.gomapi` for prod. Phase 10 installer owns prod registration.

### Q3: How should toast action buttons (Create draft / Dismiss) activate the running app?
| Option | Description | Selected |
|--------|-------------|----------|
| Foreground-activation + hide-to-tray | Brings app forward, handles action, re-hides. Cheapest; no COM. | |
| COM background activator (Phase 10 installer) | Toast activation without window flash; requires installer COM plumbing. | |
| Defer to researcher | Researcher compares based on current 2026 Wails + Win11 patterns. | |

**User's choice (freeform):** Defer to researcher. "Do note that RDS/RDP is a primary deployment target."
**Notes:** Recorded as D-07 with RDS/RDP primacy as a hard constraint on the researcher's evaluation. Multi-session isolation materially affects COM-activator feasibility.

### Q4: What tag/group scheme should drive NOTIF-05 (remove toast on process/dismiss)?
| Option | Description | Selected |
|--------|-------------|----------|
| tag = email-id, group = 'go-mapi-queue' | Per-email tag + shared group. Surgical removal + AC grouping. | ✓ |
| tag = email-id only | Simpler; loses AC grouping. | |
| Clear-all on process | Removes entire group on any event. Loses unrelated pending toasts. | |

**User's choice:** tag = email-id, group = 'go-mapi-queue'.
**Notes:** Recorded as D-08. Email-id is the watcher's content-hash.

---

## Automode goroutine + failure UX

### Q1: How should an auto-draft failure present to the user?
| Option | Description | Selected |
|--------|-------------|----------|
| Inline row badge + error toast | Red '!' badge on failed row + hover-tooltip + error toast. | ✓ |
| Inline row badge only (silent) | Badge only; no toast. Quieter; failures discovered later. | |
| Sticky in-window banner + badge | Persistent banner summarizes failures; per-row badge too. | |

**User's choice:** Inline row badge + error toast.

### Q2: If auto-draft fails because user is signed out / invalid_grant, what should happen?
| Option | Description | Selected |
|--------|-------------|----------|
| Fall back to Manual + re-auth banner + one toast | Rows stay with badge + ReAuthBanner surfaces + summary toast; no retroactive draining. | ✓ |
| Auto-resume after re-auth (process backlog) | Drain pending backlog after re-auth. Duplicate-draft risk. | |
| Suppress toasts entirely while signed out | Banner + tray icon only. Risks user missing arrivals while away. | |

**User's choice:** Fall back to Manual + re-auth banner + one summary toast. No retroactive backlog draining.

### Q3: Where should the Manual / Auto-draft mode toggle live?
| Option | Description | Selected |
|--------|-------------|----------|
| In-window header, near the account | Segmented control next to SignedInHeader. | ✓ |
| Tray right-click menu only | Radio items under tray menu. Power-user pattern. | |
| Both window AND tray menu | Redundant wiring; Slack-style. | |

**User's choice:** In-window header, near the account.

### Q4: Should we suppress new-email toasts while the main window is visible and focused?
| Option | Description | Selected |
|--------|-------------|----------|
| Yes — suppress when window is visible | Rely on live list; skip toast to reduce double-signalling. | ✓ |
| Always fire toasts | Consistent; noisy when window is open. | |
| Suppress arrivals but fire 'Draft created' toasts always | Hybrid; more conditional logic. | |

**User's choice:** Yes — suppress arrival toasts when window is visible; draft-success toasts follow the same rule; error toasts always fire.

---

## Pause-watching + has-queue icon

### Q1: What should the 'Pause watching' tray menu item actually pause?
| Option | Description | Selected |
|--------|-------------|----------|
| Suppress toasts + pause automode; watcher keeps running | Queue still accrues; user can open window and act manually. | ✓ |
| Stop the watcher entirely | fsnotify stops; new arrivals stack up on disk. Risk on crash/AV. | |
| Stop watcher + suppress toasts + halt automode | Total pause (Dropbox-style). Same on-disk-JSON risk. | |

**User's choice:** Suppress toasts + pause automode; watcher keeps running.

### Q2: Should the paused state persist across app restarts?
| Option | Description | Selected |
|--------|-------------|----------|
| No — pause resets on restart | Session-only; prevents "forgot I paused for a month" failure mode. | ✓ |
| Yes — persist in settings.json | Survives restart until explicitly resumed. | |
| Persist with auto-expiry | Resumes after N hours. Added complexity. | |

**User's choice:** No — pause resets on restart (session-only).

### Q3: How should the tray icon signal has-queue state?
| Option | Description | Selected |
|--------|-------------|----------|
| Static third variant (tray-has-queue.ico) | Three pre-rendered icons: idle, has-queue, error. Tooltip carries count. | ✓ |
| Runtime-composed badge with count | image/draw overlay. Nicer visual; DPI + RDS edge cases. | |
| Use tooltip only, keep idle icon | No icon variant; user must hover to check. | |

**User's choice:** Static third variant (tray-has-queue.ico).

### Q4: What should the tray tooltip show?
| Option | Description | Selected |
|--------|-------------|----------|
| 'go-mapi — <mode> — N pending' | Mode + count visible on hover; 'Paused' replaces mode when paused. | ✓ |
| Simple count only | Shorter; loses mode discoverability. | |
| Error-aware only (current Phase 7 behavior) | Idle message normally, 'watcher stopped' on error. No count/mode. | |

**User's choice:** `go-mapi — <mode> — N pending` with `Paused` / `Signed out` replacing the mode segment as applicable.

---

## Claude's Discretion

Items the user explicitly deferred to planner/researcher/UI-spec judgement, captured in CONTEXT.md §Claude's Discretion:

- Exact row-fade duration (~1.5s target) and CSS transition curve
- Error-toast copy + error-badge tooltip phrasing
- Whether `auto-draft-result` event emits for both success and failure or only failure
- Draft-success toast content (`Draft created: <subject>`) and whether to include an `Open in Gmail` link
- Whether draft-success toasts carry action buttons (probably not)
- AUMID string values (suggested `com.marcfargas.gomapi` prod / `.dev` for dev)
- `tray-has-queue.ico` visual design at 16×16
- Pause-menu label wording (`Pause watching` vs `Pause notifications`)
- Mode-toggle visual (segmented vs toggle-switch vs radio)
- `App.PauseWatching()` binding signature
- `settings.json` location (`%APPDATA%` preferred) and atomic-write pattern
- Exact tray icon priority table when multiple states overlap
- Row focus outline + keyboard accessibility details
- Two sets of ICO sizes (16×16 + 32×32 for HiDPI)

---

## Deferred Ideas

Captured in CONTEXT.md §Deferred:

- Bulk row actions (select multiple)
- Row expand-to-show-detail
- Retroactive auto-draft of backlog after re-auth (explicitly rejected)
- Pause with auto-expiry (Slack-style)
- Mode toggle duplicated in tray menu
- Runtime-composed tray badge with numeric count
- Distinct tray icon variants for paused / signed-out
- `Open in Gmail` deep link on draft-success toast (maybe Phase 9, maybe defer)
- Auto-send mode + undo-send window (Out of Scope for v3.0)
- Per-email mode override (Out of Scope)
- Audit log of automode actions (ENT-03, future)
- Telemetry for automode failure rates (QUAL-03 forbids)
- Windows Focus Session suppression (differentiator)
- Toast inline images (privacy + complexity)
- Dedicated `go-mapi` Settings UI panel (later phase if settings grow)
