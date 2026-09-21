import { test, expect } from './fixtures/wails-app';

// Phase 11 plan 06 — queue lifecycle regression coverage.
//
// Each test drives the real Wails app: an architecture-matched native harness
// calls MAPISendMail through the real interceptor DLL, the Go watcher picks up
// the resulting queue descriptor, emits
// 'queue-changed', the Svelte app re-renders, the test asserts visible
// queue rows and drives clicks. Round-trip proof that the bug class from
// the Phase 11 manual smoke (drafted rows lingering, Dismiss no-op,
// multi-arrival "overwrite") cannot regress silently.

test.describe.serial('queue lifecycle', () => {
  test('Test 1 — arrival renders a queue row within 3s', async ({ app }) => {
    const dropped = await app.nativeMapi.send('x64');

    const row = app.page.locator('[data-testid="queue-row"]').first();
    await expect(row).toBeVisible({ timeout: 3_000 });
    // Subject is the canonical user-visible content; sender renders
    // '(unknown sender)' because the MailMessage schema has no `from` field
    // in the current codebase (QueueRow reads msg.from if present; the Go
    // watcher only populates recipients). Asserting the subject proves the
    // arrival → render round-trip.
    await expect(row).toContainText('Test Email - Simple Send');
    expect(dropped.architecture).toBe('x64');
    // Sanity check that the native producer emitted a real queue file.
    expect(dropped.fullPath).toMatch(/\.json$/);
  });

  test('Test 2 — create-draft removes the row within 3s (f1221d7 regression guard)', async ({ app }) => {
    await app.nativeMapi.send('x86');

    const row = app.page.locator('[data-testid="queue-row"]').first();
    await expect(row).toBeVisible({ timeout: 3_000 });

    await row.getByTestId('queue-row-create-draft').click();

    // Row must disappear within 3s. This is the exact regression fixed in
    // internal/mapi/watcher.go f1221d7 — MarkProcessed now dispatches
    // queue-changed directly so the frontend sees the deletion.
    await expect(app.page.locator('[data-testid="queue-row"]')).toHaveCount(0, { timeout: 3_000 });

    // Fake Gmail should have received exactly one draft call.
    expect(app.gmail.drafts.length).toBe(1);
  });

  test('Test 3 — dismiss removes the row within 3s', async ({ app }) => {
    await app.nativeMapi.send('x64');

    const row = app.page.locator('[data-testid="queue-row"]').first();
    await expect(row).toBeVisible({ timeout: 3_000 });

    await row.getByTestId('queue-row-dismiss').click();

    // Same root cause as Test 2 — Delete() must dispatch queue-changed
    // after os.Remove so the Svelte app re-renders empty.
    await expect(app.page.locator('[data-testid="queue-row"]')).toHaveCount(0, { timeout: 3_000 });

    // Dismiss must NOT create a Gmail draft.
    expect(app.gmail.drafts.length).toBe(0);
  });

  test('Test 4 — multi-arrival shows BOTH rows (overwrite regression guard)', async ({ app }) => {
    await app.nativeMapi.send('x86');
    // Slight delay so fsnotify debouncing doesn't collapse the two Creates
    // into a single processFile invocation.
    await app.page.waitForTimeout(600);
    await app.nativeMapi.send('x64');

    const rows = app.page.locator('[data-testid="queue-row"]');
    await expect(rows).toHaveCount(2, { timeout: 3_000 });

    const allText = await rows.allTextContents();
    expect(allText.every((text) => text.includes('Test Email - Simple Send'))).toBe(true);
  });
});
