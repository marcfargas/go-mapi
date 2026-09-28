import { test, expect } from './fixtures/user-component';

type Startup = { backend: string; requested: boolean; registered: boolean; effective: string; warning?: string };

test('simulated preference survives reload while disclosure resets; keyboard controls stay usable', async ({ app }) => {
  let startup: Startup = { backend: 'standalone', requested: true, registered: true, effective: 'enabled' };
  const writes: boolean[] = [];
  await app.page.route('**/__e2e/call', async (route) => {
    const { method, args } = route.request().postDataJSON() as { method: string; args?: unknown[] };
    if (method === 'GetStartupState') return route.fulfill({ json: startup });
    if (method === 'SetAutostartEnabled') {
      const requested = Boolean(args?.[0]);
      writes.push(requested);
      startup = { backend: 'standalone', requested, registered: requested, effective: requested ? 'enabled' : 'missing' };
      return route.fulfill({ json: startup });
    }
    if (method === 'SaveSettings') throw new Error('disclosure must not save settings');
    return route.continue();
  });
  await app.page.reload();
  const preferences = app.page.getByRole('button', { name: 'Preferences' });
  const checkbox = app.page.getByRole('checkbox', { name: /Start go-mapi when I sign in/ });
  await expect(preferences).toHaveAttribute('aria-expanded', 'false');
  await expect(checkbox).toHaveCount(0);
  await preferences.focus();
  await app.page.keyboard.press('Enter');
  await expect(preferences).toHaveAttribute('aria-expanded', 'true');
  await expect(checkbox).toBeChecked();
  await app.page.keyboard.press('Space');
  await expect(preferences).toHaveAttribute('aria-expanded', 'false');
  await expect(preferences).toBeFocused();
  await expect(checkbox).toHaveCount(0);
  expect(writes).toEqual([]);
  await app.page.keyboard.press('Enter');
  await preferences.press('Tab');
  await expect(checkbox).toBeFocused();
  await app.page.keyboard.press('Space');
  await expect(checkbox).not.toBeChecked();
  expect(writes).toEqual([false]);
  await preferences.click();
  await app.page.reload();
  await expect(preferences).toHaveAttribute('aria-expanded', 'false');
  await preferences.click();
  await expect(checkbox).not.toBeChecked();
  await app.page.evaluate(() => (window as unknown as { runtime: { EventsEmit: (name: string, value: unknown) => void } }).runtime.EventsEmit('auth-changed', { authenticated: false }));
  await expect(preferences).toHaveAttribute('aria-expanded', 'true');
  await expect(checkbox).not.toBeChecked();
});

test('simulated backend warning and rejected write remain visible with Preferences closed', async ({ app }) => {
  const warning = 'Windows startup registration needs attention.';
  let startup: Startup = { backend: 'machine', requested: true, registered: false, effective: 'missing', warning };
  let writes = 0;
  await app.page.route('**/__e2e/call', async (route) => {
    const { method } = route.request().postDataJSON() as { method: string };
    if (method === 'GetStartupState') return route.fulfill({ json: startup });
    if (method === 'SetAutostartEnabled') {
      writes++;
      return route.fulfill({ status: 500, json: { error: 'simulated save rejection' } });
    }
    if (method === 'OpenStartupSettings') return route.fulfill({ json: null });
    return route.continue();
  });
  await app.page.reload();
  const alert = app.page.getByRole('alert', { name: 'Startup warning' });
  await expect(alert).toContainText(warning);
  await expect(alert.getByRole('button', { name: 'Fix startup' })).toHaveCount(0);
  await expect(alert.getByRole('button', { name: 'Open Startup Apps' })).toBeVisible();
  await app.page.getByRole('button', { name: 'Preferences' }).click();
  const checkbox = app.page.getByRole('checkbox', { name: /Start go-mapi when I sign in/ });
  await checkbox.uncheck();
  await expect(alert).toContainText('Startup preference could not be saved');
  await expect(checkbox).toBeChecked();
  await app.page.getByRole('button', { name: 'Preferences' }).click();
  await expect(alert).toContainText(warning);
  expect(writes).toBe(1);
});
