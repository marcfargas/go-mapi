import {
  test,
  expect,
  writeNativeManifest,
  unregisterNativeManifest,
} from './fixtures-v2';
import * as path from 'path';
import * as fs from 'fs';

// E2E-04: T2 install-UX test.
//
// Flow:
//   1. Ensure no native-messaging host manifest is registered for
//      com.gomapi.host (clear HKCU before the test starts).
//   2. Launch Chromium with the extension loaded.
//   3. Open the popup — assert the InstallPrompt heading appears,
//      classifying the host as MISSING.
//   4. Write a manifest pointing at tests/e2e/mock-host/mock-host.exe.
//   5. Trigger the reconnect alarm via chrome.runtime.sendMessage from
//      the popup page context (action: 'reconnect' is handled by
//      service-worker.ts line ~372).
//   6. Assert the popup transitions out of the install prompt — the
//      success toast is NOT asserted here because PHASE-4-FINDING-01
//      documents that the toast does not fire in production; the test
//      locks the reachable behavior (the prompt dismisses, the queue UI
//      renders).

const ROOT_DIR = path.resolve(__dirname, '../..');
const MOCK_HOST_BINARY = path.join(
  ROOT_DIR,
  'tests/e2e/mock-host/mock-host.exe',
);

test.describe('install UX (E2E-04)', () => {
  test.beforeEach(async () => {
    // Make sure no leftover registration from a prior run exists.
    unregisterNativeManifest();
  });

  test.afterEach(async () => {
    unregisterNativeManifest();
  });

  test('no manifest → InstallPrompt → write manifest → READY', async ({
    extensionId,
    popupPage,
  }) => {
    if (!fs.existsSync(MOCK_HOST_BINARY)) {
      test.skip(
        true,
        `mock-host.exe not present at ${MOCK_HOST_BINARY} — run go build in tests/e2e/mock-host first`,
      );
      return;
    }

    // Step 3: assert InstallPrompt is visible.
    await expect(
      popupPage.getByText('Install the go-mapi host'),
    ).toBeVisible({ timeout: 15_000 });

    // Step 4: write the manifest pointing at the mock host.
    writeNativeManifest({
      extensionId,
      hostBinary: MOCK_HOST_BINARY,
    });

    // Step 5: trigger the reconnect alarm directly from the popup
    // page. This is Pattern D from 04-E2E-SPIKE — faster than the
    // 6-second natural reconnect and avoids timing flake.
    //
    // Use the popup's own chrome.runtime context which the extension
    // page has access to.
    await popupPage.evaluate(() => {
      // Type-cast to any because the test runtime doesn't have the
      // chrome.* types — they exist only inside the extension.
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      const c = (globalThis as any).chrome;
      if (c?.runtime?.sendMessage) {
        c.runtime.sendMessage({ action: 'reconnect' });
      }
    });

    // Step 6: poll until the InstallPrompt text is no longer present.
    // Pattern C — DOM poll with explicit intervals so we don't spin.
    //
    // Reload the popup periodically because the service worker state
    // may be updated without the popup re-rendering if the HOST_STATE
    // broadcast races with the popup's listener wiring.
    await expect
      .poll(
        async () => {
          await popupPage.reload();
          await popupPage.waitForLoadState('domcontentloaded');
          return (await popupPage.textContent('body')) ?? '';
        },
        { timeout: 30_000, intervals: [500, 1000, 2000] },
      )
      .not.toContain('Install the go-mapi host');
  });
});
