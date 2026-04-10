# Phase 4 Findings

Bugs, ambiguities, and warnings discovered during Phase 4 test writing.
Per the task brief, Phase 4 does NOT fix bugs in Phase 1/2/3 source —
findings are documented here and flagged for the milestone reviewer.

---

## PHASE-4-FINDING-01 — HOST_INSTALLED_TOAST (EXT-06) never fires in practice

**Severity:** high (the EXT-06 success-toast feature is silently broken).

**Files:** `src/extension/src/background/service-worker.ts` lines 93–113,
with the toast guard at line 108.

**Symptom:** The one-time success toast that should fire on the
`MISSING → READY` edge when the user installs the native host mid-session
never renders. Users installing go-mapi see the email queue appear
silently, but no confirmation toast pops in the popup.

**Root cause:** `transitionHostState` guards the toast on
`prev === 'MISSING' && next === 'READY'`:

```ts
if (prev === 'MISSING' && next === 'READY' && !hasShownInstalledToast) {
  hasShownInstalledToast = true;
  persistInstalledToastFlag();
  broadcastToPopup({ type: 'HOST_INSTALLED_TOAST' });
}
```

But `connectToNativeHost()` (line 117) always calls
`transitionHostState('PROBING')` (line 121) before creating the port and
wiring up the listeners that will later deliver the READY message. The
reachable sequence on reconnect is therefore:

  MISSING  → (reconnect alarm fires)
  PROBING  → (new port opens, no READY yet)
  READY    → (NativeReadyMessage arrives)

The direct `MISSING → READY` edge is never hit, so the guard always
fails. The `hasShownInstalledToast` flag stays `false` and the toast
broadcast is never sent.

**Reproducer:** `src/extension/src/background/__tests__/service-worker.test.ts`,
test `"does NOT fire HOST_INSTALLED_TOAST on a standard MISSING → PROBING
→ READY reconnect (PHASE-4-FINDING-01)"`. The test locks the current
broken behavior (zero toasts) so that a future fix must flip the
assertion from `.toHaveLength(0)` to `.toHaveLength(1)`.

**Suggested fixes (not applied in Phase 4):**

1. **Track "was ever MISSING in this session"** — add a
   `wasMissing` boolean that flips to `true` when state enters MISSING
   and check it (not `prev`) in the guard. Dead-simple, no
   `transitionHostState` restructuring.

2. **Restructure the state machine** — don't go through PROBING on
   reconnect; preserve the previous `MISSING`/`ERROR` state until the
   outcome is known. Bigger change, higher regression risk.

Recommendation: fix via approach (1) in a follow-up Phase 4.5 or at the
top of the v2.1.0 cycle, with the test above as the verification.
Approach (1) is ~5 lines of code plus flipping the test assertion.

---

## PHASE-4-FINDING-02 — `json_writer.h` multi-line comment warning

**Severity:** low (cosmetic; warning-only, not an error).

**File:** `src/interceptor/json_writer.h` line 36.

**Symptom:** MinGW emits `warning: multi-line comment [-Wcomment]` when
the CPPTEST-02 `message_converter_tests.cpp` translation unit includes
`message_converter.h`, which in turn includes `json_writer.h`. The
existing DLL build also triggers this warning; it is pre-existing and
not introduced by Phase 4.

**Root cause:** The comment at line 36 ends a C++ line comment with a
trailing backslash just before a newline, which GCC interprets as a
continuation into the next source line:

```cpp
    // Write a MailMessage to a JSON file in %TEMP%\go-mapi\
```

The trailing `\` after `go-mapi` is a line-continuation marker inside a
`//` comment.

**Fix (not applied in Phase 4):** Change the trailing backslash to a
forward slash, drop the backslash, or wrap the path in backticks. One-line
fix. Should be bundled with the next interceptor edit.

---

## PHASE-4-FINDING-03 — `go test -race` not available on the executor sandbox

**Severity:** informational (not a project bug — toolchain limitation).

**Symptom:** `cd src/native-host && go test -race ./...` on the executor
host (a `windows/arm64` sandbox) prints
`-race is not supported on windows/arm64` and exits non-zero. This
prevents the executor from locally verifying the FOUND-01 watcher race
fix (Phase 1).

**Impact:** `.github/workflows/go-race-nightly.yml` targets
`windows-latest`, which is amd64 and does support `-race`, so the
nightly job will still run as designed. The local developer experience
on arm64 Windows dev boxes is degraded — Marc's main dev box (`marcwin`)
appears to be arm64 per the executor environment, so he may not be able
to reproduce race issues locally.

**Mitigation (not applied in Phase 4):** Document the arm64 limitation
in `CONTRIBUTING.md` or the Phase 4 handoff so future contributors know
to rely on CI for race detection. No code change needed.

---

*Document created: 2026-04-10 during Phase 4 execution*
