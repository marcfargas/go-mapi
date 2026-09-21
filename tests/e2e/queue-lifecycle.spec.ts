import { test, expect } from './fixtures/user-component';

// Cross-platform queue lifecycle coverage. The browser host implements the
// Wails binding boundary against an isolated queue directory; Go tests cover
// the real watcher/consumer and the Windows gate covers native producers.

test.describe.serial('queue lifecycle', () => {
  test('Test 1 — arrival renders a queue row within 3s', async ({ app }) => {
    const dropped = await app.queue.send({ subject: 'Arrival test' });

    const row = app.page.locator('[data-testid="queue-row"]').first();
    await expect(row).toBeVisible({ timeout: 3_000 });
    // Subject is the canonical user-visible content; sender renders
    // '(unknown sender)' because the MailMessage schema has no `from` field
    // in the current codebase (QueueRow reads msg.from if present; the Go
    // watcher only populates recipients). Asserting the subject proves the
    // arrival → render round-trip.
    await expect(row).toContainText('Arrival test');
    // Sanity check that the producer emitted a real queue file.
    expect(dropped.fullPath).toMatch(/\.json$/);
  });

  test('Test 2 — create-draft removes the row within 3s (f1221d7 regression guard)', async ({ app }) => {
    await app.queue.send({ subject: 'Draft this one' });

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
    await app.queue.send({ subject: 'Dismiss this one' });

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
    await app.queue.send({ subject: 'First arrival' });
    await app.queue.send({ subject: 'Second arrival' });

    const rows = app.page.locator('[data-testid="queue-row"]');
    await expect(rows).toHaveCount(2, { timeout: 3_000 });

    const allText = await rows.allTextContents();
    expect(allText.some((text) => text.includes('First arrival'))).toBe(true);
    expect(allText.some((text) => text.includes('Second arrival'))).toBe(true);
  });
});
