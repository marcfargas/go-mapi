---
phase: 10-installer-migration
reviewed: 2026-04-20T12:18:35Z
depth: standard
files_reviewed: 12
files_reviewed_list:
  - src/installer/go-mapi.nsi
  - src/installer/plugins/x86-unicode/README.md
  - src/app/webview2_check.go
  - src/app/webview2_check_bindings.go
  - src/app/webview2_check_test.go
  - src/app/sessionend.go
  - src/app/main.go
  - src/app/wails.json
  - src/installer/tests/installer.Tests.ps1
  - src/installer/tests/AumidReader.ps1
  - .github/workflows/installer-smoke.yml
  - .github/workflows/installer-release.yml
  - .github/release-template.md
  - .gitignore
  - README.md
findings:
  critical: 0
  warning: 3
  info: 6
  total: 9
status: issues_found
---

# Phase 10: Code Review Report

**Reviewed:** 2026-04-20T12:18:35Z
**Depth:** standard
**Files Reviewed:** 12 source files (plus 3 docs/config for cross-check)
**Status:** issues_found

## Summary

Phase 10 lands a comprehensive NSIS installer, a Wails-side WebView2 runtime guard, a Pester 5 smoke harness, and both smoke + release CI workflows. Overall quality is high:

- The build-tag split for `checkWebView2` / `showWebView2MissingDialog` mirrors the `credentials_check.go` precedent byte-for-byte (Shared Pattern 1).
- `procMessageBoxW` is correctly added to the existing `user32` `var(...)` block in `sessionend.go` rather than redeclared — Shared Pattern 2 respected.
- The cmdkey target uses the colon separator (`go-mapi:oauth-tokens`) consistently across installer, uninstaller, and Pester harness (Shared Pattern 3).
- The firewall rule name `go-mapi OAuth loopback` is byte-for-byte identical in install (`AddFirewallRule`), uninstall (step 1 of the 10-step scrub), and Pester assertions (items 6 + 10).
- The AUMID literal `com.marcfargas.gomapi` matches across the NSI `!define AUMID`, release-workflow ldflags, and Pester expected value.
- `ApplicationID::Set` exit code is correctly popped and logged via `DetailPrint` per RESEARCH §Pitfall 2.
- SignPath v2 two-pass signing is correctly gated on `secrets.SIGNPATH_API_TOKEN`; unsigned fallback path resolves artifacts correctly via the `final` step.
- The main.go ordering invariant holds: `checkWebView2()` runs before `checkOAuthCredentials()`.
- Uninstaller 10-step scrub order matches D-18 exactly.

The issues below are concentrated in two areas: (1) an NSIS logic bug in `DetectWebView2` that mis-treats `pv=0.0.0.0` as "runtime present" (mitigated by the app-side check but defeats the installer's bootstrap-and-verify intent); (2) minor hygiene concerns in two NSIS helper functions (latent `$R1/$R2` corruption that is currently silent because callers use `$0–$5` only).

## Warnings

### WR-01: `DetectWebView2` treats `pv=0.0.0.0` as runtime present (diverges from Go check)

**File:** `src/installer/go-mapi.nsi:194-204`
**Issue:**
The probe-loop jump logic is inverted. `StrCmp $0 "" 0 WebView2Found` jumps to `WebView2Found` whenever `$0` is **non-empty** — which includes the sentinel value `"0.0.0.0"` that Microsoft's WebView2 distribution guidance uses to signal a broken install. The subsequent `StrCmp $0 "0.0.0.0" 0 WebView2Found` line is never reached when `$0 == "0.0.0.0"` because the prior `StrCmp` has already jumped away.

Concretely, with `pv = "0.0.0.0"` at the first probe path:
- Line 195 executes `StrCmp $0 "" 0 WebView2Found`. Since `$0 != ""`, control jumps to `WebView2Found`.
- `WebView2Found` does a `DetailPrint` and pushes `"1"` — installer concludes the runtime is present.

The Go counterpart in `src/app/webview2_check.go:45` correctly handles this: `if err == nil && pv != "" && pv != "0.0.0.0"`. The two layers are therefore out of sync — the installer will skip the bootstrapper, but the Wails app will exit with the "WebView2 required" dialog on launch.

The same inverted-jump pattern repeats at lines 198-200 (second probe) and line 204 (HKCU probe — the third probe doesn't even attempt to exclude `"0.0.0.0"`).

**Fix:**
Invert the branch semantics so an invalid/absent pv falls through to the next probe, and a valid pv jumps to `WebView2Found`. For a cleaner read, use `0` (fall-through) on the valid path and a next-probe label on the invalid path:

```nsi
  SetRegView 64
  ReadRegStr $0 HKLM "SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}" "pv"
  StrCmp $0 "" TryDirectHKLM
  StrCmp $0 "0.0.0.0" TryDirectHKLM
  Goto WebView2Found

TryDirectHKLM:
  ReadRegStr $0 HKLM "SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}" "pv"
  StrCmp $0 "" TryHKCU
  StrCmp $0 "0.0.0.0" TryHKCU
  Goto WebView2Found

TryHKCU:
  SetRegView 32
  ReadRegStr $0 HKCU "Software\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}" "pv"
  StrCmp $0 "" WebView2NotFound
  StrCmp $0 "0.0.0.0" WebView2NotFound
  Goto WebView2Found
```

Add a regression note in the comment block: "probe rejects pv='' or pv='0.0.0.0' at every path — matches Go `checkWebView2` in webview2_check.go".

---

### WR-02: Backup JSON is vulnerable to embedded quotes in previous-mail-client names

**File:** `src/installer/go-mapi.nsi:150,162`
**Issue:**
`FileWrite $1 '{"previousClient":"$0","backedUpAt":"$3"}'` interpolates `$0` (the previous-client display name read from `HKLM\SOFTWARE\Clients\Mail` default value) verbatim into a JSON string without escaping. If a third-party mail client registers with a name containing `"` or `\`, the resulting JSON is syntactically invalid. Pester item 4 (`ConvertFrom-Json` in `installer.Tests.ps1:79`) would fail, and the uninstaller's line-scan-based restore (`un.StrExtract` with delimiter `"`) would misparse the name and potentially restore the wrong value or no value at all.

Attack surface is low — mail client names are registry-controlled and typically alphanumeric — but this is still a correctness hazard for edge cases (e.g., Japanese-locale mail clients, custom-branded enterprise deployments).

**Fix:**
Add a minimal escape step before writing. NSIS lacks native JSON escaping, but the two characters that matter for JSON string context are `"` and `\`. Using `${UnStrRep}` or a small helper `Function EscapeJson` that replaces `\` with `\\` then `"` with `\"`:

```nsi
Push $0
Call EscapeJsonString   ; pops input, pushes escaped
Pop $0
FileWrite $1 '{"previousClient":"$0","backedUpAt":"$3"}'
```

Alternatively, wrap the JSON generation in the same `powershell.exe -NoProfile -Command` call already used for the timestamp, and let PowerShell's `ConvertTo-Json` handle escaping:

```nsi
nsExec::ExecToStack 'powershell.exe -NoProfile -Command "@{previousClient=\"$0\"; backedUpAt=(Get-Date).ToUniversalTime().ToString(\"o\")} | ConvertTo-Json -Compress"'
```

This also collapses the timestamp + JSON emit into a single PS invocation (~200ms saved).

---

### WR-03: Smoke-workflow artifact may embed OAuth client_secret in the installer

**File:** `.github/workflows/installer-smoke.yml:74-78,113-120`
**Issue:**
The smoke job sets `GOMAPI_OAUTH_CLIENT_SECRET` from `secrets.GOMAPI_OAUTH_CLIENT_SECRET` (line 40) and passes it into the Wails binary via ldflags injection (line 78), then uploads the resulting `go-mapi-setup.exe` as a workflow artifact (lines 113-120, `retention-days: 7`). The installer bundles the signed Wails binary, which contains the injected client_secret in the `.rdata` section where Go stores string literals for `-X` ldflags targets.

For pushes to `main`/`develop` (where repo secrets are populated — not forked-PR builds, which receive empty strings per the comment on lines 36-38), the artifact is a binary blob containing the Google OAuth desktop client_secret.

Workflow artifacts on public repos are downloadable by anyone with read access to the repo — effectively public. For Google Desktop OAuth, the client_secret is documented as "not confidential for desktop apps using PKCE", so this is not a CVE-class leak, but it expands the exposure surface beyond the intended one (release binaries on GitHub Releases). It also means rotating the secret invalidates all smoke-test artifacts retained for the past 7 days.

The same pattern exists in the release workflow, but there the installer is the product and publication to a public URL is intentional.

**Fix:**
For the smoke workflow, one of:
1. Drop `GOMAPI_OAUTH_CLIENT_ID`/`SECRET` from the env block entirely. The comment already notes Pester never launches the app, so binaries built with empty OAuth creds install + uninstall correctly. Remove lines 39-40 and the `-X main.oauthClientID=... -X main.oauthClientSecret=...` from line 78.
2. If release-matching builds are desired for smoke testing, keep the env vars but do **not** upload the installer artifact on PRs from the main repo; restrict `actions/upload-artifact` to `workflow_dispatch` invocations only:

```yaml
- name: Upload installer as workflow artifact (for debugging failed runs)
  if: always() && github.event_name == 'workflow_dispatch'
  uses: actions/upload-artifact@v4
```

Option 1 is simpler and matches the documented smoke-test intent (install/uninstall round-trip, not live OAuth). Use option 1.

## Info

### IN-01: `syscall.StringToUTF16Ptr` is deprecated — prefer `UTF16PtrFromString`

**File:** `src/app/webview2_check.go:57-58`
**Issue:**
Go's `syscall.StringToUTF16Ptr` is marked deprecated; the Go team's recommended replacement is `syscall.UTF16PtrFromString` (used elsewhere in this codebase — see `sessionend.go:79`, `settings.go:110,114`, `singleinstance.go:45,79,102`). The deprecated form panics on embedded NUL bytes rather than returning an error; since the title and body strings here are compile-time constants without NUL, there is no runtime hazard today, but the style inconsistency with the rest of the package is worth correcting.

**Fix:**
```go
title, _ := syscall.UTF16PtrFromString("go-mapi — WebView2 required")
body, _ := syscall.UTF16PtrFromString(
    "Microsoft Edge WebView2 Runtime is required to run go-mapi.\r\n\r\n" +
        "Your system browser will now open the Microsoft download page. " +
        "Install the runtime, then relaunch go-mapi.")
```

The error returns are safely discarded because the literals contain no NUL.

---

### IN-02: `un.StrContains` corrupts `$R2` in its restore sequence

**File:** `src/installer/go-mapi.nsi:494-522`
**Issue:**
Walking the stack through the function: entry pushes save `prev$R1`, `prev$R2` on the stack (via the `Exch $R1; Exch; Exch $R2` prelude), then `Push $R3; Push $R4; Push $R5` adds three more. After computation, `$R1` holds the result. The cleanup does:

```
Pop $R5    ; ok
Pop $R4    ; ok
Pop $R3    ; ok — stack now [prev$R1, prev$R2] (top = prev$R2)
Exch $R1   ; $R1 ← prev$R2, stack top ← result. Stack: [prev$R1, result]
Exch       ; swap top two. Stack: [result, prev$R1] (top = prev$R1)
Pop $R2    ; $R2 ← prev$R1  ← WRONG: should be prev$R2
Exch $R1   ; swap result and $R1(=prev$R2). $R1 ← result (WRONG — should be prev$R1);
           ;                                 stack top ← prev$R2. Final stack: [prev$R2]
```

Net effect: after the call, `$R1` holds the result (correct from the caller's view — they `Pop $4`), but `$R2` holds `prev$R1`, `$R1`'s pre-call value is lost, and one stray `prev$R2` is left on the stack that the caller never pops (a slow leak every call).

Because `un.RestorePreviousMailClient` uses only `$0–$5` (never `$R*`), the corruption is currently invisible. If a future edit adds `$R*` register use in the caller (or expands the helpers), this becomes a latent bug.

**Fix:**
The standard NSIS "save-and-restore three registers, return one value" idiom is:

```nsi
un.SC_Done:
  Pop $R5
  Pop $R4
  Pop $R3
  Pop $R2     ; restore prev$R2
  Exch $R1    ; swap prev$R1 on stack with result in $R1 — stack top = result, $R1 = prev$R1
FunctionEnd
```

(Net: 4 Pops + 1 Exch, balancing the 2 Exch-saves + 3 Pushes + 5 implicit pushes from Exch.)

Apply the same fix to `un.StrExtract` (next finding).

---

### IN-03: `un.StrExtract` has the same register-restore bug as `un.StrContains`

**File:** `src/installer/go-mapi.nsi:526-567`
**Issue:**
The entry saves `prev$R1`, `prev$R2`, `prev$R3` via `Exch $R1; Exch; Exch $R2; Exch 2; Exch $R3`, then `Push $R4; Push $R5; Push $R6; Push $R7`. Cleanup ends with:

```
Pop $R7 ... Pop $R4   ; ok
Pop $R3                ; restores prev$R3 correctly
Pop $R2                ; $R2 ← prev$R1  ← WRONG
Exch $R1               ; swaps result with $R1 (=prev$R2). $R1 ← result (WRONG);
                       ; stack top ← prev$R2
```

Same shape as IN-02: `$R1` and `$R2` are swapped on return; caller's `Pop $1` still sees the result correctly only because the final `Exch` happens to leave the result on the stack in `$R1`'s slot. But `$R1` and `$R2` no longer hold their pre-call values.

**Fix:**
```nsi
un.SE_Done:
  Pop $R7
  Pop $R6
  Pop $R5
  Pop $R4
  Pop $R3     ; restore prev$R3
  Pop $R2     ; restore prev$R2
  Exch $R1    ; swap prev$R1 with result. Stack top = result; $R1 = prev$R1
FunctionEnd
```

Same 7-pop + 1-exch balance for 3 Exch-saves + 4 Pushes + 7 implicit stack items.

---

### IN-04: `DetectWebView2` leaves `SetRegView 32` active on exit

**File:** `src/installer/go-mapi.nsi:193,202`
**Issue:**
`Function DetectWebView2` calls `SetRegView 64` at the top and `SetRegView 32` before the HKCU probe at line 202. Neither `WebView2Found` nor `WebView2NotFound` resets the view back to the NSIS default (64 for a 64-bit NSIS, 32 for the 32-bit compiler). For the current install section, this is benign — all `WriteRegStr HKLM ...` calls occur **before** the `Call InstallWebView2`, so nothing subsequently written depends on the view. But `DetectWebView2` is also invoked from inside the poll loop in `InstallWebView2`, and the install section continues after `Call InstallWebView2` with `Call CreateShortcutAndAUMID` + `Call AddFirewallRule`, both of which may grow registry writes in future phase work. A silent WOW6432Node redirect on a future `WriteRegStr HKLM "SOFTWARE\..."` would be hard to diagnose.

**Fix:**
Reset the view before returning:

```nsi
WebView2NotFound:
  SetRegView default
  Pop $1
  Pop $0
  Push "0"
  Return

WebView2Found:
  SetRegView default
  DetailPrint "WebView2 runtime detected: $0"
  Pop $1
  Pop $0
  Push "1"
  Return
```

Or structure all three probes under `SetRegView 64` only — the HKCU `Software\` path does not reflect, so the view selection there is cosmetic.

---

### IN-05: JSON `previousClient:null` detection false-matches names containing that literal

**File:** `src/installer/go-mapi.nsi:439-443`
**Issue:**
`un.RestorePreviousMailClient` decides whether the backup records a null previousClient by looking for the literal substring `"previousClient":null` via `un.StrContains`. If a previous mail client's display name happens to contain that exact literal (contrived: `Old Mail ("previousClient":null placeholder)`), the uninstaller would treat it as null and skip to fallbacks.

This is an extreme edge case — mail client display names realistically do not contain quoted JSON-like substrings — but it is a brittle string-search heuristic rather than a real JSON parse.

**Fix:**
Anchor the match more strictly by looking for the exact JSON key:value pair at a position relative to the opening `{`, or use a PowerShell one-liner to parse the JSON. The PowerShell route is cleanest:

```nsi
nsExec::ExecToStack 'powershell.exe -NoProfile -Command "(Get-Content ''$APPDATA\..\..\ProgramData\go-mapi\uninst\previous-mail-client.json'' -Raw | ConvertFrom-Json).previousClient"'
Pop $2      ; exit code
Pop $3      ; previousClient value or empty if null
```

An empty `$3` means null; any non-empty value is the restore candidate. This also fixes WR-02 implicitly (ConvertFrom-Json correctly unescapes embedded quotes written by ConvertTo-Json).

---

### IN-06: Pester AUMID reader Add-Type is idempotent-by-type-existence but not idempotent-by-definition

**File:** `src/installer/tests/AumidReader.ps1:15-100`
**Issue:**
The guard `if (-not ('GoMapi.AumidReader.Reader' -as [type]))` checks whether the compiled type `GoMapi.AumidReader.Reader` is already loaded, then calls `Add-Type -Namespace GoMapi.AumidReader -Name Reader ...`. However, the inline C# source also defines `GoMapi.AumidReader.PublicReader` (the entry point used by `Get-ShortcutAumid`), `IPropertyStore`, `IPersistFile`, etc. If a parallel test file ever defined the same types (or if a re-dot-source happened in a long-running PS session), the guard would skip recompilation even though the `PublicReader` symbol might be from a previous definition — and a stale definition would be used.

In the current CI environment this is moot (clean runner per job), but it's a subtle hazard for anyone running the Pester suite iteratively on a dev machine.

**Fix:**
Either guard against the symbol actually referenced (`GoMapi.AumidReader.PublicReader`) for clarity, or wrap the entire `Add-Type` in a try/catch that swallows "type already exists" errors:

```powershell
if (-not ('GoMapi.AumidReader.PublicReader' -as [type])) {
    Add-Type -Namespace GoMapi.AumidReader -Name Reader -MemberDefinition @'
    ...
'@
}
```

`PublicReader` is the actual entry point, so checking its presence is the correct proxy for "the compiled assembly is loaded". Rename the guarded symbol accordingly.

---

_Reviewed: 2026-04-20T12:18:35Z_
_Reviewer: Claude (gsd-code-reviewer)_
_Depth: standard_
