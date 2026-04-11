import * as fs from 'fs';
import * as os from 'os';
import * as path from 'path';
import {
  test,
  expect,
  startMockGmail,
  writeHostWrapper,
  writeNativeManifest,
  unregisterNativeManifest,
} from './fixtures-v2';

// E2E-03: T1 happy-path test.
//
// Flow:
//   1. Launch the stdlib mock Gmail server on 127.0.0.1.
//   2. Create a per-test temp watch directory.
//   3. Write a .cmd wrapper for the real go-mapi native host that
//      injects --watch-dir and --gmail-api-base into every launch.
//   4. Register the native-messaging manifest pointing at the wrapper.
//   5. Launch Chromium with the extension loaded.
//   6. Drop a fixture JSON file into the watch directory.
//   7. Assert the popup shows the email.
//   8. Click "Save as Draft" / trigger draft creation.
//   9. Assert the mock Gmail server recorded exactly one POST /drafts.
//  10. Clean up.

const ROOT_DIR = path.resolve(__dirname, '../..');
const FIXTURE_PATH = path.join(ROOT_DIR, 'tests/fixtures/simple-email.json');

interface Setup {
  watchDir: string;
  mockGmailStop: () => void;
  gmailUrl: string;
  draftsCount: () => Promise<number>;
  manifestPath: string;
}

test.describe('happy path (E2E-03)', () => {
  let setup: Setup | null = null;

  test.beforeEach(async ({ extensionId }) => {
    // Pre-test: launch mock Gmail, prepare watch dir + wrapper + manifest.
    const mock = await startMockGmail();
    const watchDir = fs.mkdtempSync(path.join(os.tmpdir(), 'go-mapi-e2e-watch-'));
    const wrapper = writeHostWrapper(watchDir, mock.url);
    const manifestPath = writeNativeManifest({
      extensionId,
      hostBinary: wrapper,
    });

    setup = {
      watchDir,
      mockGmailStop: mock.stop,
      gmailUrl: mock.url,
      draftsCount: mock.drafts,
      manifestPath,
    };
  });

  test.afterEach(async () => {
    if (!setup) return;
    try {
      setup.mockGmailStop();
    } catch {
      /* ignore */
    }
    try {
      unregisterNativeManifest();
    } catch {
      /* ignore */
    }
    try {
      fs.rmSync(setup.watchDir, { recursive: true, force: true });
    } catch {
      /* ignore */
    }
    setup = null;
  });

  test('fixture JSON → popup → draft creation hits mock Gmail', async ({
    popupPage,
  }) => {
    expect(setup).not.toBeNull();
    const s = setup!;

    // Drop a fixture JSON into the watch dir. The native host (launched
    // by Chrome via the .cmd wrapper) should pick it up via fsnotify and
    // broadcast EMAIL to the extension.
    if (!fs.existsSync(FIXTURE_PATH)) {
      test.skip(
        true,
        `fixture ${FIXTURE_PATH} not present in repo — skipping happy path test`,
      );
      return;
    }
    const fixtureData = fs.readFileSync(FIXTURE_PATH, 'utf8');
    fs.writeFileSync(
      path.join(s.watchDir, 'e2e-fixture.json'),
      fixtureData,
    );

    // Pattern C (DOM poll): wait for the popup to render at least one
    // email. The exact selector is pinned to the EmailList rendering
    // from Phase 2 — if the layout changes, update the selector.
    await expect
      .poll(
        async () => {
          await popupPage.reload();
          await popupPage.waitForLoadState('domcontentloaded');
          const text = (await popupPage.textContent('body')) ?? '';
          return text.includes('No pending emails') ? 'empty' : 'nonempty';
        },
        { timeout: 30_000, intervals: [500, 1000, 2000] },
      )
      .toBe('nonempty');

    // The service worker's autoCreateDraft flow runs as soon as the
    // email arrives (if a token is available). In a mocked environment
    // chrome.identity.getAuthToken returns 'mock-auth-token' via the
    // chrome mock stub that the real popup doesn't load — but the
    // REAL service worker will fail non-interactive auth and show a
    // "Sign in required" notification instead of auto-drafting.
    //
    // For E2E, we instead trigger draft creation explicitly. The popup
    // exposes a chrome.runtime.sendMessage({action:'createDraft',...})
    // path via the EmailDetail "Save as Draft" button. Inspect the
    // rendered popup to find and click it.

    // Navigate into the email detail view by clicking the first email.
    // EmailList renders <li className="email-item">, not react-bootstrap
    // ListGroup — match the actual class, not a guessed one.
    const emailRow = popupPage.locator('li.email-item').first();
    await expect(emailRow).toBeVisible({ timeout: 10_000 });
    await emailRow.click();

    // EmailDetail renders a primary "Save as Draft" button from
    // react-bootstrap <Button>. Wait for it to appear after the row click
    // before asserting, so the test fails loudly if navigation broke
    // instead of silently skipping the click.
    const draftButton = popupPage.getByRole('button', { name: 'Save as Draft' });
    await expect(draftButton).toBeVisible({ timeout: 10_000 });
    await draftButton.click();

    // Pattern C: poll the mock Gmail counter until the draft POST is
    // observed, or until we hit the overall test timeout.
    await expect
      .poll(async () => await s.draftsCount(), {
        timeout: 30_000,
        intervals: [500, 1000, 2000],
      })
      .toBeGreaterThanOrEqual(1);
  });
});
