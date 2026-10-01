import { test, expect } from './fixtures/user-component';

test('Send To guidance opens by keyboard, closes, and remains available', async ({ app }) => {
  const summary = app.page.getByText('Email with Send To');
  const details = app.page.locator('details.email-guidance');
  await expect(summary).toBeVisible();
  await expect(details).not.toHaveAttribute('open');
  await summary.focus();
  await app.page.keyboard.press('Enter');
  await expect(details).toHaveAttribute('open');
  await expect(details).toContainText('system component');
  await expect(details).toContainText('does not currently handle mailto links');
  await expect(app.page.getByRole('button', { name: 'Open Default Apps' })).toHaveCount(0);
  await app.page.keyboard.press('Enter');
  await expect(details).not.toHaveAttribute('open');
  await app.page.keyboard.press('Enter');
  await expect(details).toHaveAttribute('open');
});
