---
created: 2026-04-23T20:41:00.000Z
title: Installer fails to overwrite 32-bit go-mapi.dll on reinstall (investigation)
area: installer
files:
  - src/installer/go-mapi.nsi
---

## Problem

Reported 2026-04-23: running `go-mapi-setup.exe` over an existing install (no prior uninstall) errors specifically on the 32-bit `go-mapi.dll` saying it is "not writable". No other file in the install set triggers this. A manual delete of the DLL via Explorer **does succeed** (with the standard UAC elevation prompt), so the file is **not** kernel-locked by a running process — a loaded-DLL lock would survive elevation too.

## What the hand-delete finding rules out

- Not a `LoadLibrary`/mapped-image lock (those survive elevation).
- Not a missing admin grant on the containing directory (delete + re-create would both fail, but delete works).
- Not a simple "running go-mapi.exe has it open" (guard already covers that and the DLL isn't loaded by the Wails app).

## Plausible causes to investigate

- **NSIS overwrite flag mismatch for the 32-bit block only.** The x64 DLL path may use `SetOverwrite try`/`SetOverwrite on` while the x86 block inherits the previous NSIS default. Quick audit of both `SetOutPath` blocks should show this.
- **UAC file-virtualisation interaction** with `$PROGRAMFILES32`. The installer runs elevated (`RequestExecutionLevel admin`), but if the DLL was *first* placed by an older unelevated path, its owner/ACL may differ and the elevated writer still sees a deny.
- **AV/Defender real-time scan** briefly holding the file open on upgrade — transient lock that manual delete (seconds later) no longer hits.
- **Installer sequencing:** the uninstall-old-version sub-step may finish asynchronously; the new overwrite may race with the unmap of the old DLL from the same installer's uninstaller-runner.

## Action

Deferred — captured as investigation seed in `.planning/seeds/installer-32bit-dll-overwrite-investigation.md` so it surfaces at next milestone planning. Not a blocker for first-time-install smoke; only reproduces on in-place reinstall.

## Repro (short form)

1. Machine already has go-mapi installed.
2. Run `go-mapi-setup.exe` again without uninstalling first.
3. Installer errors on `$PROGRAMFILES32\go-mapi\go-mapi.dll`.
4. Close installer → right-click DLL → Delete → elevation prompt → file is deleted cleanly.
5. Re-run installer → succeeds.
