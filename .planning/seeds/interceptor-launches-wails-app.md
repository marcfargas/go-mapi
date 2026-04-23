---
title: "Interceptor DLL launches go-mapi.exe if not running"
trigger_condition: "v3.1 milestone planning, or sooner if 'Start at logon' is shipped and first-run-without-app issue still surfaces"
planted_date: 2026-04-23
---

## Idea

When the MAPI interceptor DLL (`go-mapi.dll`) handles a `MAPISendMail` / `MAPISendMailW` call from a legacy Windows app, after it has written the JSON + copied attachments into `%LOCALAPPDATA%\go-mapi\queue\`, check whether `go-mapi.exe` is running. If not, spawn it detached.

The legacy caller is still blocked at this point in the DLL (same synchronous window used today for attachment copy in commit `bbbfc75`), so the `CreateProcess` call latency is amortised inside the Send action the user already initiated.

## Why

Closes the silent-queue failure mode from the other angle. "Start at logon" (companion seed `start-at-logon.md`) handles the 80% case, but users who disable that toggle, or machines that were suspended through logon, or RDS sessions where the app crashed earlier, all still lose the feedback loop. This makes the interceptor self-healing — if you sent mail, the app *will* appear.

## Breadcrumbs

- DLL is C++17, already does file I/O and can include `<windows.h>` (`CreateProcessW` + `CloseHandle` is the entire payload).
- Resolve `go-mapi.exe` path via the install-time registry key that already stores `DLLPath`'s sibling — NSIS can write `InstallDir` under `HKLM\SOFTWARE\Clients\Mail\go-mapi` at install time, DLL reads via `RegGetValueW`.
- Use a named kernel mutex (`Global\GoMapiSingleInstance` — already exists in `src/app/singleinstance.go`) to detect "already running" without enumerating processes.
- Launch detached (`CREATE_NEW_PROCESS_GROUP | DETACHED_PROCESS`) so the legacy app's process tree does not adopt the Wails app as a child (closing the legacy app would otherwise kill go-mapi).
- Respect user pause state: if `Pause watching` is on, do NOT auto-launch (the user explicitly opted out). This means the settings file has to be readable from the DLL — or the DLL writes the JSON first and lets the running-app gate auto-launching based on its own settings; **prefer the second approach** to keep the DLL ignorant of Go/Svelte state.

## When to surface

During v3.1 milestone planning, as a paired follow-up to "Start at logon". Shipping both gives a strong "just works" UX: startup on logon covers steady-state; DLL auto-launch covers the edge cases.

## Risk / constraints

- **Privacy-first invariant:** DLL must still succeed (write JSON, return MAPI_OK) even if launching `go-mapi.exe` fails — never block the caller's send on app-launch failure.
- **No legacy-process adoption:** use detached spawn flags so the Wails app does not inherit the legacy app's console, handles, or lifetime.
- **32-bit ↔ 64-bit:** the x86 DLL inside a 32-bit legacy host must still spawn the 64-bit `go-mapi.exe` (`CreateProcessW` is arch-agnostic; no special handling required, but verify).
- **Anti-malware heuristics:** a DLL in a legacy app that spawns a new process could trip heuristic AV. Mitigation: SmartScreen reputation (existing SignPath signing plan) + documented rationale in README.
