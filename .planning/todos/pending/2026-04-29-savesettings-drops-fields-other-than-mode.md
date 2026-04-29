---
created: 2026-04-29T05:50:00.000Z
title: App.SaveSettings silently drops fields other than Mode (REL-05 footgun)
area: settings
files:
  - src/app/app.go:624-626
  - src/app/frontend/src/lib/settings.ts:60-62
---

## Problem

`App.SaveSettings(s AppSettings)` in `src/app/app.go:624-626` accepts a full `AppSettings` struct via Wails binding but only writes `s.Mode` to disk. The Go side silently drops every other field — currently `UpdateChecksEnabled` and `LastUpdateCheck` (added in Phase 11 / 11.1).

The TypeScript binding shape in `src/app/frontend/src/lib/settings.ts:60-62` advertises the full `AppSettings` struct, so a frontend caller following the documented API would lose data with no error returned.

Discovered during v3.0 milestone audit (2026-04-29) and called out as a "related warning" in the silent-updater 404 todo (2026-04-28).

## Why it's currently latent

- All in-tree callers are tray-only and only flip `Mode`.
- The settings UI surface for `UpdateChecksEnabled` lives in the tray menu (toggle path), not in the frontend SaveSettings call.
- No regression yet because the only frontend `SaveSettings` use-site preserves all fields by reading-then-writing the whole struct, which happens to round-trip Mode-only on the Go side without observable failure.

It becomes a real bug the moment a frontend caller tries to persist `UpdateChecksEnabled` or `LastUpdateCheck` directly — silent data loss, no error.

## Options

**Option A — narrow the binding (recommended).** Rename the Wails binding to `SaveMode(mode string)` so the API surface matches reality. Frontend `settings.ts` updates to call `SaveMode` instead of `SaveSettings`. Type-safe, smallest behavioural change. New `UpdateChecks*` writers can be added as their own bindings (`SetUpdateChecksEnabled(bool)`, `MarkLastUpdateCheck(time.Time)`) when a UI path needs them.

**Option B — make `SaveSettings` honour the full struct.** Atomically write all flat fields. Bigger blast radius (mutex semantics, file-format rev), but matches the documented API. Worth doing if a frontend settings panel is on the roadmap for v3.x.

Either is acceptable. A is faster to ship and doesn't pre-commit to a UI shape.

## Verification

Whichever option:

1. New unit test: bind `SaveSettings` (or `SaveMode`) with a struct that has non-default `UpdateChecksEnabled` / `LastUpdateCheck`, read back via `LoadSettings`, assert all fields round-trip (or assert the explicit narrow-API contract for Option A).
2. svelte-check stays green after frontend rename (Option A).
3. Manual: tray Mode toggle keeps working; tray "Check for updates now" still updates `LastUpdateCheck`.

## Related context

- Source todo (now in `.planning/todos/completed/`): `2026-04-28-silent-updater-404s-publish-3-binaries-to-github-releases.md`
- Quick task that closed the silent-updater 404: `260429-0zg`
- Settings store entry point: `src/app/settings.go` (paths.SettingsFile + atomic write)
