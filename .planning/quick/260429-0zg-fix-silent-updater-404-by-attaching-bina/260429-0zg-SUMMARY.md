---
quick_id: 260429-0zg
description: Fix silent-updater 404 by attaching go-mapi.exe + go-mapi-x64.dll + go-mapi-x86.dll to GitHub Release in installer-release.yml
status: complete
date: 2026-04-29
commits:
  - a6fa828 fix(release): attach silent-updater binaries to GitHub Release
source_todo: 2026-04-28-silent-updater-404s-publish-3-binaries-to-github-releases.md
closes_blocker: REL-09 silent auto-update (Phase 11.1)
---

# Quick Task 260429-0zg — Summary

## Problem

The Phase 11.1 silent updater (`src/app/updates_silent.go:189-216`) downloads three binaries from `https://github.com/marcfargas/go-mapi/releases/latest/download/<name>`:

- `go-mapi.exe`
- `go-mapi-x64.dll`
- `go-mapi-x86.dll`

But `installer-release.yml` only attached `go-mapi-setup.exe` + `SHA256SUMS.txt` to the GitHub Release. Every silent-update run produced:

1. Manifest fetch → 200 ✓
2. `go-mapi.exe` download → **404** ✗ → silent updater exits 1.

Net effect: the entire Phase 11.1 silent-update path (Scheduled Task XML + MoveFileEx atomic swap + SHA-256 verify + 12h retry-with-backoff) was shipped but could not succeed in production. **BLOCKER for REL-09.**

## What changed

**`.github/workflows/installer-release.yml`** — single hunk, +21 lines:

1. New step `Stage release binaries (signed-or-unsigned)` inserted between `Generate SHA256SUMS.txt` and `Attach installer + SHA256SUMS.txt to GitHub Release`. Logic:
   - Pick `staged-signed/` when SignPath ran, else fall back to `staged/`.
   - Copy `go-mapi.exe` + `go-mapi-x64.dll` + `go-mapi-x86.dll` into `release-bins/`.
   - Echo file sizes for build-log audit.
2. `softprops/action-gh-release@v2` `files:` block extended from 2 to 5 entries (adds the three runtime binaries).

The SHA256SUMS.txt generation step already lists all four asset names, so the manifest stays correct with no further changes.

## Why this approach

Per the source todo's research note (`.planning/research/2026-04-28-nsis-rename-while-running.md`), Option C (run the installer silently as the update mechanism) was rejected:

- NSIS `File` is plain `CreateFile` and ABORTS with `ERROR_SHARING_VIOLATION` on a running exe.
- `SetOverwrite try` (Phase 11.1-01 T4 fix) silently SKIPS long-held process handles → installer exits 0 but leaves the old binary in place.
- Real-world NSIS installers (Notepad++, OBS, qBittorrent) all fail badly here; Chrome and VS Code abandoned NSIS for separate updater services.

The existing MoveFileEx three-step swap is the canonical Windows pattern. The design is right; only the publication step was missing — fixed here.

## Out of scope (recorded for follow-up)

`src/app/app.go:624-626` `App.SaveSettings(s AppSettings)` accepts a full `AppSettings` struct but only writes `s.Mode` — silently drops `UpdateChecksEnabled` and `LastUpdateCheck`. Type signature in `settings.ts:60-62` advertises the full shape. Not currently exploited (only tray-only callers flip the field), but a future frontend caller following the documented API would lose data. **Will be captured as a separate todo by the user** (per task scope decision).

## Verification (deferred — runs on next tag push)

After this fix lands, on the next `v*` tag push:

1. Inspect the GitHub Release page — confirm 5 assets: `go-mapi-setup.exe`, `SHA256SUMS.txt`, `go-mapi.exe`, `go-mapi-x64.dll`, `go-mapi-x86.dll`.
2. For each binary: `curl -sIL https://github.com/marcfargas/go-mapi/releases/latest/download/<name>` should redirect 302 → 200 with the expected `Content-Length`.
3. `curl -sL https://github.com/marcfargas/go-mapi/releases/latest/download/SHA256SUMS.txt` should list all four asset hashes.
4. Manual `go-mapi.exe --update-check-silent` with `GOMAPI_UPDATES_DIR` override → confirm full pipeline (manifest + 3 downloads + checksum verify + MoveFileEx swap + cleanup) succeeds end-to-end.
5. `installer-smoke.yml` Pester items 22-24 already exercise install-time pieces (Scheduled Task registration / removal); the silent-update HTTP path lives outside Pester scope.

No CI run was triggered as part of this quick task.

## Source todo

Moved from `.planning/todos/pending/` → `.planning/todos/completed/` (content unchanged) in the same atomic commit (`a6fa828`).
