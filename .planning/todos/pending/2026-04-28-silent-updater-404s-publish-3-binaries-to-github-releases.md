---
created: 2026-04-28T22:28:02.452Z
title: Silent updater 404s — publish 3 binaries to GitHub Releases
area: autoupdate
files:
  - .github/workflows/installer-release.yml:218-227
  - src/app/updates_silent.go:189-216
  - .planning/v3.0-MILESTONE-AUDIT.md
  - .planning/research/2026-04-28-nsis-rename-while-running.md
---

## Problem

**BLOCKER for REL-09 silent auto-update.** Discovered in v3.0 milestone audit 2026-04-29.

The Phase 11.1 silent updater (`src/app/updates_silent.go:189-216`) downloads three binaries directly from `https://github.com/marcfargas/go-mapi/releases/latest/download/<name>`:

- `go-mapi.exe`
- `go-mapi-x64.dll`
- `go-mapi-x86.dll`

But `installer-release.yml` only attaches **two** assets to the GitHub Release (lines 222-224 of the `softprops/action-gh-release@v2` `files:` block):

```yaml
files: |
  ${{ steps.final.outputs.path }}    # go-mapi-setup.exe
  SHA256SUMS.txt
```

The three signed binaries are computed-hashed into `SHA256SUMS.txt` (lines 195-200 list all four asset names) but never attached as release assets. So on every silent-update run:

1. Manifest fetch → 200 ✓
2. `go-mapi.exe` download → **404** ✗
3. Silent updater logs `download/verify go-mapi.exe aborted: status 404` and exits 1.

Net effect: the entire Phase 11.1 silent-update path (Scheduled Task XML + MoveFileEx atomic swap + SHA-256 verify + 12h retry-with-backoff) is shipped but cannot succeed in production.

## Solution

Smallest correct fix: extend the `softprops/action-gh-release@v2` step in `installer-release.yml` to attach the three signed binaries alongside the existing assets.

Asset paths after the SignPath two-pass flow:

- Signed branch (`SIGNPATH_API_TOKEN` present): `staged-signed/go-mapi.exe`, `staged-signed/go-mapi-x64.dll`, `staged-signed/go-mapi-x86.dll`
- Unsigned branch (no SignPath): `staged/go-mapi.exe`, `staged/go-mapi-x64.dll`, `staged/go-mapi-x86.dll`

Because lines 136-142 only copy *back* to the source build paths conditionally, simplest is a small "stage release binaries" step that always produces a unified `release-bins/` directory regardless of signing path, then reference its three files in the `files:` block. Pseudocode:

```pwsh
- name: Stage release binaries (signed-or-unsigned)
  shell: pwsh
  run: |
    $src = if (Test-Path 'staged-signed') { 'staged-signed' } else { 'staged' }
    New-Item -ItemType Directory -Force release-bins | Out-Null
    Copy-Item "$src/go-mapi.exe"     release-bins/
    Copy-Item "$src/go-mapi-x64.dll" release-bins/
    Copy-Item "$src/go-mapi-x86.dll" release-bins/
```

Then the release step:

```yaml
files: |
  ${{ steps.final.outputs.path }}
  SHA256SUMS.txt
  release-bins/go-mapi.exe
  release-bins/go-mapi-x64.dll
  release-bins/go-mapi-x86.dll
```

### Why not Option C (run installer silently)

Researched and rejected — see `.planning/research/2026-04-28-nsis-rename-while-running.md`. Verdict:

- NSIS `File` directive is plain `CreateFile` and ABORTS with `ERROR_SHARING_VIOLATION` on a running exe.
- `SetOverwrite try` (Phase 11.1-01 T4 fix) only handles transient AV locks; it silently SKIPS long-held process handles and exits 0 — so `installer.exe /S` over a running app appears successful but leaves the old binary in place.
- Real-world NSIS installers (Notepad++, OBS, qBittorrent) all fail badly against running processes; Chrome and VS Code abandoned NSIS for separate updater services.
- Windows allows *renaming* a running exe (`FILE_SHARE_DELETE`) but not *replacing* it — the existing MoveFileEx three-step swap is the canonical pattern.

So the design is right; only the publication step is missing.

### Related WARNING (REL-05 footgun, capture in same fix or separate todo)

`src/app/app.go:624-626` `App.SaveSettings(s AppSettings)` accepts a full `AppSettings` struct but only writes `s.Mode` — silently drops `UpdateChecksEnabled` and `LastUpdateCheck`. Type signature in `settings.ts:60-62` advertises the full shape. Not currently exploited (only tray-only callers flip the field), but a future frontend caller following the documented API would lose data with no error. Suggested fix: rename binding to `SaveMode(mode string)` so the API surface matches reality, OR expand `SaveSettings` to atomically write all flat fields.

## Verification

After fix lands, on next tag push:

1. Inspect the GitHub Release page — confirm 5 assets: `go-mapi-setup.exe`, `SHA256SUMS.txt`, `go-mapi.exe`, `go-mapi-x64.dll`, `go-mapi-x86.dll`.
2. Verify each binary's `curl -sI -L <url>` redirects 302 → 200 with the expected size.
3. Manual `go-mapi.exe --update-check-silent` with `GOMAPI_UPDATES_DIR` override → confirm full pipeline runs (manifest + 3 downloads + checksum verify + MoveFileEx swap + cleanup).
4. `installer-smoke.yml` Pester items 22-24 should already exercise the install-time pieces (Scheduled Task registration / removal); the actual silent-update HTTP path lives outside Pester scope.
