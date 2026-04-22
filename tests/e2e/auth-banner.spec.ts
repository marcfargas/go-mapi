import { test, expect } from './fixtures/wails-app';

// Phase 11 plan 06 — auth-banner regression coverage.
//
// Scenario: fake Gmail returns 401 on every draft call. AuthManager
// classifies the repeated 401 as invalid_grant (after one refresh retry),
// clears the in-memory tokens, and emits auth-changed{authenticated:false}.
// App.svelte flips showReAuthBanner = true and the banner renders.

test('Test 5 — invalid_grant surfaces the re-auth banner within 3s', async ({ app }) => {
  // Configure fake Gmail to 401 the next two calls (MakeAuthenticatedGmailCall
  // forces one refresh-and-retry, so two 401s are needed to reach the
  // classified invalid_grant path).
  app.gmail.failNextWith(401);
  app.gmail.failNextWith(401);

  await app.watchDir.dropEmail({ subject: 'Trigger reauth' });

  const row = app.page.locator('[data-testid="queue-row"]').first();
  await expect(row).toBeVisible({ timeout: 3_000 });

  await row.getByTestId('queue-row-create-draft').click();

  // Banner must appear within 3s of the click. AuthManager clears tokens
  // AND emits auth-changed inline with the second 401, so the latency is
  // bounded by Gmail call timeout + Wails event dispatch.
  const banner = app.page.locator('[data-testid="reauth-banner"]');
  await expect(banner).toBeVisible({ timeout: 3_000 });
  await expect(banner).toContainText('Sign-in expired');
});
