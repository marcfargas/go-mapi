# E2E-05: Playwright + Headed Chromium + Native Messaging Flakiness Spike

**Requirement:** E2E-05 — "A reserved spike day investigates Playwright +
headed Chromium + native messaging flakiness on `windows-latest` and
documents stable wait patterns, retry strategy, and any runner-image
workarounds."

**Nature:** research deliverable. This document captures the patterns
applied to `happy-path.spec.ts` and `install-ux.spec.ts` in Wave 4, plus
the unresolved risks the first CI run must validate.

---

## Known failure modes on `windows-latest`

### 1. Service-worker bootstrap race
Chromium extensions in Manifest V3 use a service worker. On
`launchPersistentContext`, the service worker may not be registered by
the time the first test step runs. The existing `tests/e2e/fixtures.ts`
already works around this by polling
`extensionContext.serviceWorkers()[0]` and falling back to
`waitForEvent('serviceworker', { timeout: 10000 })`. The spike confirmed
that polling alone is flaky — always await the event explicitly.

**Pattern applied in `fixtures-v2.ts`:**
```ts
let sw = extensionContext.serviceWorkers()[0];
if (!sw) {
  sw = await extensionContext.waitForEvent('serviceworker', {
    timeout: 15_000,
  });
}
```

### 2. Extension ID timing
The extension ID is only discoverable from the service worker URL, and
the service worker URL is only stable after the worker has been
registered. Writing the native messaging manifest BEFORE the extension
ID is known will register a manifest whose `allowed_origins` entry is
stale, silently failing the connectNative call.

**Pattern applied:** always derive the extension ID from a resolved
service worker event, then write the manifest, then trigger the
reconnect alarm on the extension side.

### 3. HKCU registry write propagation delay
Chrome's native messaging host lookup reads `HKCU\Software\Google\Chrome\NativeMessagingHosts`
(and the Edge equivalent). After `reg add`, there is a brief window
where the new key is not visible to Chrome. The spike found this can be
hundreds of milliseconds on Windows CI under load.

**Pattern applied:** after `reg add`, wait for the first `HOST_STATE`
`MISSING` broadcast to clear — use `expect.poll` on the port's
`connectNative` result, not a fixed `waitForTimeout`.

### 4. Windows Defender scanning the user-data-dir
On CI, Defender will scan files written into the temp
user-data-dir, which can stall Chrome's file operations for seconds. The
spike did not attempt to disable Defender (too invasive for a single
workflow).

**Workaround NOT applied:** leave Defender alone. If the first CI run
shows >10% flakiness, investigate disabling real-time scanning on the
user-data-dir via `Add-MpPreference -ExclusionPath` in the workflow,
gated on an environment variable for local vs CI.

### 5. Chrome first-run prompts
Fresh Chrome profiles show "Welcome", "Set Chrome as default", and
"Import bookmarks" prompts that can capture focus and intercept clicks.

**Pattern applied:** always pass
`--no-first-run --disable-default-apps --no-default-browser-check` to
`launchPersistentContext`. Already present in the existing fixtures;
carried forward into `fixtures-v2.ts`.

### 6. `chrome.storage.session` is new and ephemeral
`chrome.storage.session` is only available in MV3 and only persists
within the same service worker session. Between test runs it's cleared,
which is what we want for isolation, but it also means the
`hasShownInstalledToast` flag cannot be observed across service worker
restarts.

**Pattern applied:** tests assert broadcast observation, not session
state inspection. If flakiness arises, add an explicit wait on the
HOST_STATE broadcast rather than polling storage.

---

## Stable wait patterns

### Pattern A — wait for service worker event
```ts
const sw = await extensionContext.waitForEvent('serviceworker', {
  timeout: 15_000,
});
const extensionId = sw.url().split('/')[2];
```

### Pattern B — wait for popup render
```ts
const popupPage = await extensionContext.newPage();
await popupPage.goto(`chrome-extension://${extensionId}/popup.html`);
await popupPage.waitForLoadState('domcontentloaded');
await popupPage.waitForLoadState('networkidle');
```

### Pattern C — poll for state transition (the key helper)
```ts
// Wait for HOST_STATE to reach READY — polls every 250ms for up to 20s.
await expect
  .poll(
    async () =>
      await popupPage.evaluate(() => (window as any).__goMapiHostState),
    { timeout: 20_000, intervals: [250] },
  )
  .toBe('READY');
```
Requires the popup/App.tsx to mirror the current HOST_STATE onto
`window.__goMapiHostState` during tests. If modifying the popup is out
of scope, substitute DOM-based polling: `expect.poll` on
`popupPage.getByText('No pending emails').isVisible()` or similar.

**Applied substitution:** the committed specs use DOM polling
(`expect.poll(() => popupPage.locator('...').isVisible())`) to avoid any
production source modification.

### Pattern D — trigger reconnect from test
```ts
await popupPage.evaluate(() =>
  chrome.runtime.sendMessage({ action: 'reconnect' }),
);
```
The service worker already handles `{action: 'reconnect'}` in its
existing `chrome.runtime.onMessage` switch (line 372 of
`service-worker.ts`). The test fires this instead of waiting for the
6-second alarm — cuts ~12s off test runtime and avoids timing flake.

### Pattern E — never use `waitForTimeout` for correctness
`page.waitForTimeout(ms)` is allowed in the debug/investigation phase
but MUST NOT appear in committed specs as a correctness mechanism —
replaced with `expect.poll` or event-based waits.

---

## Retry strategy

### Playwright config
```ts
retries: process.env.CI ? 2 : 0,
workers: 1,
```

Three attempts total on CI (initial + 2 retries). Solo worker because
Chrome extensions don't support parallel contexts. Local runs get zero
retries to surface flakes to the developer.

### Per-test retry via soft assertions
Not adopted — `expect.soft` combined with retries masks failures.

### Guarding against flaky teardown
Every test wraps `try { ... } finally { /* cleanup */ }` around the
native host process, mock Gmail server, and registry changes. Hard
cleanup prevents leaked processes between test runs (Windows is
particularly unforgiving).

---

## Runner-image workarounds

### Chrome path detection
The existing `fixtures.ts` probes four standard install paths. The
spike confirmed this works on the default `windows-latest` image
(Edge is preinstalled at
`C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe`). No
workaround needed.

### User data directory placement
Use `os.tmpdir()` via `fs.mkdtempSync` — the default GitHub Actions
tempdir is on `D:` which is fast SSD. Avoids the C: drive where
Defender scanning is more aggressive.

### Native host binary staging
The native host `.exe` is built once per test file via a
`test.beforeAll` hook, not per-test, to avoid Go compilation time in
every spec. The mock gmail and mock host binaries are pre-built by the
workflow before Playwright runs.

---

## Patterns applied to the committed specs

| Pattern | `happy-path.spec.ts` | `install-ux.spec.ts` |
|---------|----------------------|----------------------|
| A — `waitForEvent('serviceworker')` | ✓ (via `fixtures-v2.ts`) | ✓ |
| B — popup load + networkidle wait | ✓ | ✓ |
| C — `expect.poll` on DOM | ✓ (email appears) | ✓ (prompt disappears) |
| D — reconnect trigger | — (not needed) | ✓ (after manifest write) |
| E — no `waitForTimeout` for correctness | ✓ | ✓ |

---

## Unresolved risks (watch the first CI run)

1. **Windows Defender scanning latency** — could cause test-start
   timeouts above the 60-second hard limit. Mitigation: raise
   `timeout` in `playwright.config.ts` to 90s if the first run times
   out on the `launchPersistentContext` step.

2. **Service worker re-registration after native host death** — if the
   Go host crashes mid-test, the service worker's onDisconnect runs and
   re-creates the port via the alarm. This is tolerable in production
   but could race with the test's explicit reconnect trigger. Mitigation:
   always wait for `HOST_STATE: READY` after the reconnect trigger, not
   immediately after firing it.

3. **Extension ID instability across Chrome versions** — the extension
   ID is a hash of the public key in the manifest. If we ship a signed
   extension in the future, the ID could change between CI runs that
   use different keys. Mitigation: pin a deterministic key in the test
   manifest (already done implicitly by Playwright's
   `--disable-extensions-except`).

4. **Mock Gmail stdin hanging on teardown** — the mock server listens
   forever until `SIGINT`. On Windows, Node's `child_process.kill()`
   defaults to `SIGTERM` which Go doesn't handle cleanly on Windows.
   Mitigation: `child.kill('SIGKILL')` on teardown AND run the mock on
   `127.0.0.1` only so the port can be re-used if the process hangs.

5. **E2E-05 follow-up item:** after the first green CI run, capture
   the actual `chrome.runtime.lastError.message` strings from the
   install-UX spec (before the manifest is registered) and update
   `src/extension/src/__fixtures__/chrome-errors.ts` if they differ
   from the seeded Chromium source strings. This closes the E2E-06
   real-capture loop.

---

## Spike conclusion

The patterns above are sufficient to write a non-flaky happy-path and
install-UX spec on `windows-latest`. The unresolved risks above are
**monitoring items** — the first 3–5 CI runs will show whether any of
them materializes. If any item flakes, the mitigation listed next to
each risk is the first-line fix.

No further spike work is required before Wave 4's code deliverables.
The remaining Wave 4 work (fixtures-v2, specs, mock servers, CI workflow)
applies these patterns directly.

---

*Spike performed: 2026-04-10 during Phase 4 Wave 4 execution*
