---
id: SEED-001
status: dormant
planted: 2026-05-24
planted_during: v3.0 (Wails Pivot) — Phase 11.1
trigger_when: when relevant
scope: unknown
---

# SEED-001: Consider Microsoft Store distribution, need to 1st verify we can do the MAPI DLL registration with that distribution

## Why This Matters

_To be filled in. Run `/gsd:capture --seed --enrich SEED-001` to add context._

Initial note: Microsoft Store distribution could improve discoverability and trust
(signed, sandboxed, auto-updating) for a non-technical Windows audience — but the
**open blocker** is whether MSIX/Store packaging can perform the MAPI handler
registration the app depends on. This must be verified BEFORE committing to a Store
track.

## When to Surface

**Trigger:** when relevant

This seed will surface during `/gsd:new-milestone` when the milestone scope matches
(e.g. a distribution/packaging milestone beyond the v3.0 NSIS installer).

## Scope Estimate

**Unknown** — run `/gsd:capture --seed --enrich SEED-001` to estimate effort.

## Breadcrumbs

The hard dependency to verify is MAPI handler registration, which today is done via
classic Win32 registry writes that an MSIX/Store package may sandbox or disallow:

- `HKLM:\SOFTWARE\Clients\Mail\go-mapi` — MAPI handler registration key (per CLAUDE.md;
  written by the Phase 10 install path). MSIX runs writes through the Desktop Bridge
  virtualized registry — confirm whether `HKLM\SOFTWARE\Clients\Mail` survives
  virtualization and is visible to the system MAPI subsystem.
- `src/interceptor/` — C++17 MAPI DLL (`go-mapi.dll`, 32- + 64-bit). Verify a Store
  package can install/register a `mapi32`-compatible DLL and that the simple-MAPI
  client resolution finds it.
- v3.0 distribution today = single-file **NSIS** installer (Phase 10, INST-02) with
  WebView2 bootstrap — the Store path would be an alternative/additional channel, not
  a replacement, until parity on registration is proven.
- Open questions to resolve in a spike: (1) does MSIX allow the required HKLM mail-client
  registration, (2) can a Store-sandboxed app be invoked as the system MAPI handler,
  (3) WebView2 runtime handling under Store policy, (4) LGPL-3.0 compatibility with
  Store distribution terms.

## Notes

_Captured via one-shot seed capture. Enrich with trigger, why, and scope at your convenience._
_Suggested first move when this surfaces: a `/gsd:spike` to prove MSIX MAPI registration before any milestone commitment._
