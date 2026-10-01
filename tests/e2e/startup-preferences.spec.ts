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
  await checkbox.click();
  await expect(alert).toContainText('Startup preference could not be saved');
  await expect(checkbox).toBeChecked();
  await app.page.getByRole('button', { name: 'Preferences' }).click();
  await expect(alert).toContainText(warning);
  expect(writes).toBe(1);
});

// Item 11: a keyboard-activated startup write must not drop focus to the
// document. Chromium applies the HTML focus fixup rule (disabled or removed
// focused element -> body), which jsdom does not, so these run in Playwright.
// The delayed variants force the pending state across a rendering step.
const delay = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

for (const delayMs of [300, 0]) {
  test(`simulated ${delayMs ? 'delayed' : 'fast'} keyboard toggle keeps focus on the checkbox`, async ({ app }) => {
    let startup: Startup = { backend: 'standalone', requested: true, registered: true, effective: 'enabled' };
    const writes: boolean[] = [];
    await app.page.route('**/__e2e/call', async (route) => {
      const { method, args } = route.request().postDataJSON() as { method: string; args?: unknown[] };
      if (method === 'GetStartupState') return route.fulfill({ json: startup });
      if (method === 'SetAutostartEnabled') {
        const requested = Boolean(args?.[0]);
        writes.push(requested);
        if (delayMs) await delay(delayMs);
        startup = { backend: 'standalone', requested, registered: requested, effective: requested ? 'enabled' : 'disabled' };
        return route.fulfill({ json: startup });
      }
      return route.continue();
    });
    await app.page.reload();
    const preferences = app.page.getByRole('button', { name: 'Preferences' });
    const checkbox = app.page.getByRole('checkbox', { name: /Start go-mapi when I sign in/ });
    await preferences.focus();
    await app.page.keyboard.press('Enter');
    await app.page.keyboard.press('Tab');
    await expect(checkbox).toBeFocused();
    await app.page.keyboard.press('Space');
    if (delayMs) {
      await expect(checkbox).toHaveAttribute('aria-disabled', 'true');
      await expect(checkbox).toBeFocused();
      await app.page.keyboard.press('Space');
    }
    await expect(checkbox).not.toHaveAttribute('aria-disabled', 'true');
    await expect(checkbox).not.toBeChecked();
    await expect(checkbox).toBeFocused();
    expect(writes).toEqual([false]);
  });
}

for (const preferencesOpen of [false, true]) {
  test(`simulated keyboard Fix startup with Preferences ${preferencesOpen ? 'open' : 'closed'} moves focus predictably`, async ({ app }) => {
    let startup: Startup = { backend: 'standalone', requested: true, registered: false, effective: 'missing', warning: 'Startup is requested but not registered.' };
    const writes: boolean[] = [];
    await app.page.route('**/__e2e/call', async (route) => {
      const { method, args } = route.request().postDataJSON() as { method: string; args?: unknown[] };
      if (method === 'GetStartupState') return route.fulfill({ json: startup });
      if (method === 'SetAutostartEnabled') {
        writes.push(Boolean(args?.[0]));
        await delay(300);
        startup = { backend: 'standalone', requested: true, registered: true, effective: 'enabled' };
        return route.fulfill({ json: startup });
      }
      return route.continue();
    });
    await app.page.reload();
    const preferences = app.page.getByRole('button', { name: 'Preferences' });
    const checkbox = app.page.getByRole('checkbox', { name: /Start go-mapi when I sign in/ });
    const alert = app.page.getByRole('alert', { name: 'Startup warning' });
    const fix = alert.getByRole('button', { name: 'Fix startup' });
    await expect(fix).toBeVisible();
    if (preferencesOpen) {
      await preferences.click();
      await expect(checkbox).toBeChecked();
    }
    await fix.focus();
    await app.page.keyboard.press('Enter');
    await expect(fix).toHaveAttribute('aria-disabled', 'true');
    await expect(fix).toBeFocused();
    await app.page.keyboard.press('Enter');
    await expect(alert).toHaveCount(0);
    await expect(preferencesOpen ? checkbox : preferences).toBeFocused();
    expect(writes).toEqual([true]);
  });
}

test('simulated keyboard Fix startup keeps focus when the warning remains', async ({ app }) => {
  const warning = 'Windows could not register startup.';
  const startup: Startup = { backend: 'standalone', requested: true, registered: false, effective: 'error', warning };
  let writes = 0;
  await app.page.route('**/__e2e/call', async (route) => {
    const { method } = route.request().postDataJSON() as { method: string };
    if (method === 'GetStartupState') return route.fulfill({ json: startup });
    if (method === 'SetAutostartEnabled') {
      writes++;
      await delay(300);
      return route.fulfill({ json: startup });
    }
    return route.continue();
  });
  await app.page.reload();
  const fix = app.page.getByRole('alert', { name: 'Startup warning' }).getByRole('button', { name: 'Fix startup' });
  await fix.focus();
  await app.page.keyboard.press('Enter');
  await expect(fix).toHaveAttribute('aria-disabled', 'true');
  await expect(fix).not.toHaveAttribute('aria-disabled', 'true');
  await expect(fix).toBeVisible();
  await expect(fix).toBeFocused();
  expect(writes).toBe(1);
});

for (const preferencesOpen of [false, true]) {
  test(`simulated keyboard Retry startup status with Preferences ${preferencesOpen ? 'open' : 'closed'} moves focus predictably`, async ({ app }) => {
    let reads = 0;
    await app.page.route('**/__e2e/call', async (route) => {
      const { method } = route.request().postDataJSON() as { method: string };
      if (method === 'GetStartupState') {
        reads++;
        if (reads === 1) return route.fulfill({ status: 500, json: { error: 'simulated read failure' } });
        await delay(300);
        return route.fulfill({ json: { backend: 'standalone', requested: true, registered: true, effective: 'enabled' } });
      }
      return route.continue();
    });
    await app.page.reload();
    const preferences = app.page.getByRole('button', { name: 'Preferences' });
    const checkbox = app.page.getByRole('checkbox', { name: /Start go-mapi when I sign in/ });
    const alert = app.page.getByRole('alert', { name: 'Startup warning' });
    const retry = alert.getByRole('button', { name: 'Retry startup status' });
    await expect(retry).toBeVisible();
    if (preferencesOpen) {
      await preferences.click();
      await expect(checkbox).toHaveCount(0);
    }
    await retry.focus();
    await app.page.keyboard.press('Enter');
    await expect(retry).toHaveAttribute('aria-disabled', 'true');
    await expect(retry).toBeFocused();
    await app.page.keyboard.press('Enter');
    await expect(alert).toHaveCount(0);
    await expect(preferencesOpen ? checkbox : preferences).toBeFocused();
    expect(reads).toBe(2);
  });
}
