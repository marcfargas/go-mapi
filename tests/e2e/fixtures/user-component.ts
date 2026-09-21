import { test as base, chromium, type Page } from '@playwright/test';
import { createHash } from 'node:crypto';
import { createReadStream } from 'node:fs';
import { mkdtemp, readFile, readdir, rm, unlink } from 'node:fs/promises';
import { createServer, type IncomingMessage, type ServerResponse } from 'node:http';
import { tmpdir } from 'node:os';
import { extname, join, normalize, resolve } from 'node:path';
import type { AddressInfo } from 'node:net';

import { startFakeGmail, type FakeGmailControl } from './fake-gmail';
import { QueueProducer } from './queue-producer';

export interface UserComponentFixture {
  page: Page;
  queue: QueueProducer;
  gmail: FakeGmailControl;
}

const REPO_ROOT = resolve(__dirname, '..', '..', '..');
const FRONTEND_DIST = join(REPO_ROOT, 'src', 'app', 'frontend', 'dist');

type QueueItem = { id: string; filename: string; message: Record<string, unknown> };

async function queueSnapshot(queueDir: string): Promise<QueueItem[]> {
  const entries = (await readdir(queueDir, { withFileTypes: true }))
    .filter((entry) => entry.isFile() && entry.name.endsWith('.json'));
  const items = await Promise.all(entries.map(async ({ name }) => {
    const data = await readFile(join(queueDir, name));
    return {
      id: createHash('sha256').update(data).update(name).digest('hex'),
      filename: name,
      message: JSON.parse(data.toString('utf8')) as Record<string, unknown>,
    };
  }));
  items.sort((a, b) => String(a.message.timestamp).localeCompare(String(b.message.timestamp)));
  return items;
}

async function readBody(req: IncomingMessage): Promise<Record<string, unknown>> {
  const chunks: Buffer[] = [];
  for await (const chunk of req) chunks.push(Buffer.from(chunk));
  return chunks.length === 0 ? {} : JSON.parse(Buffer.concat(chunks).toString('utf8'));
}

function json(res: ServerResponse, value: unknown, status = 200) {
  res.writeHead(status, { 'content-type': 'application/json' });
  res.end(JSON.stringify(value));
}

async function startUserComponentHost(queueDir: string, gmail: FakeGmailControl) {
  const handler = async (req: IncomingMessage, res: ServerResponse) => {
    try {
      if (req.method === 'POST' && req.url === '/__e2e/call') {
        const { method, args = [] } = await readBody(req) as { method?: string; args?: unknown[] };
        const snapshot = await queueSnapshot(queueDir);
        const id = String(args[0] ?? '');
        const target = snapshot.find((item) => item.id === id);
        switch (method) {
          case 'GetQueue': return json(res, snapshot.map(({ id, message }) => ({ id, message })));
          case 'GetAuthStatus': return json(res, { authenticated: true, email: 'e2e@example.com' });
          case 'GetSettingsState': return json(res, { settings: { mode: 'manual', autostart_enabled: true, default_apps_prompted: true, update_checks_enabled: true } });
          case 'GetPausedState': return json(res, false);
          case 'GetUpdateState': return json(res, { currentVersion: '3.1.0-beta.1', enabled: false });
          case 'GetComponentHealth': return json(res, { healthy: true, issues: [] });
          case 'GetAdminInstallState': return json(res, { phase: 'healthy', retryable: false });
          case 'GetStartupState': return json(res, { backend: 'test', requested: false, registered: false, effective: 'disabled' });
          case 'DismissEmail':
            if (target) await unlink(join(queueDir, target.filename));
            return json(res, { events: [['queue-update']] });
          case 'CreateDraftForID': {
            if (!target) return json(res, null);
            let response = await fetch(`${gmail.url}/gmail/v1/users/me/drafts`, { method: 'POST', body: '{}' });
            if (response.status === 401) {
              response = await fetch(`${gmail.url}/gmail/v1/users/me/drafts`, { method: 'POST', body: '{}' });
            }
            if (response.status === 401) {
              return json(res, { events: [
                ['auth-changed', { authenticated: false }],
                ['auto-draft-result', { emailId: id, success: false, errorCategory: 'signed-out', reason: 'token expired' }],
              ] });
            }
            if (!response.ok) return json(res, { events: [['auto-draft-result', { emailId: id, success: false, errorCategory: 'gmail' }]] });
            await unlink(join(queueDir, target.filename));
            return json(res, { events: [
              ['queue-update'],
              ['auto-draft-result', { emailId: id, success: true }],
            ] });
          }
          default: return json(res, null);
        }
      }

      const requestPath = req.url === '/' ? 'index.html' : normalize((req.url ?? '').split('?')[0]).replace(/^[/\\]+/, '');
      const filePath = join(FRONTEND_DIST, requestPath);
      if (!filePath.startsWith(FRONTEND_DIST)) return json(res, { error: 'invalid path' }, 400);
      const contentTypes: Record<string, string> = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.svg': 'image/svg+xml' };
      res.writeHead(200, { 'content-type': contentTypes[extname(filePath)] ?? 'application/octet-stream' });
      createReadStream(filePath).on('error', () => { if (!res.headersSent) res.writeHead(404); res.end(); }).pipe(res);
    } catch (error) {
      json(res, { error: String(error) }, 500);
    }
  };
  const server = createServer((req, res) => void handler(req, res));
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
  const port = (server.address() as AddressInfo).port;
  return {
    url: `http://127.0.0.1:${port}`,
    close: () => new Promise<void>((resolveClose, reject) => server.close((error) => error ? reject(error) : resolveClose())),
  };
}

const bridgeScript = `
(() => {
  const listeners = new Map();
  const emit = (name, ...args) => (listeners.get(name) || []).slice().forEach((entry) => {
    entry.callback(...args);
    if (entry.remaining > 0 && --entry.remaining === 0) listeners.set(name, listeners.get(name).filter((x) => x !== entry));
  });
  const call = async (method, ...args) => {
    const response = await fetch('/__e2e/call', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ method, args }) });
    if (!response.ok) throw new Error(await response.text());
    const value = await response.json();
    if (value && Array.isArray(value.events)) value.events.forEach(([name, payload]) => emit(name, payload));
    return value && Object.prototype.hasOwnProperty.call(value, 'events') ? null : value;
  };
  window.runtime = {
    EventsOnMultiple(name, callback, remaining) { const entry = { callback, remaining }; listeners.set(name, [...(listeners.get(name) || []), entry]); return () => listeners.set(name, (listeners.get(name) || []).filter((x) => x !== entry)); },
    EventsOff(name) { listeners.delete(name); }, EventsOffAll() { listeners.clear(); }, EventsEmit: emit,
    BrowserOpenURL() {}, WindowHide() {}, WindowShow() {}, Quit() {}, LogPrint() {}, LogTrace() {}, LogDebug() {}, LogInfo() {}, LogWarning() {}, LogError() {}, LogFatal() {},
  };
  const methods = ['CheckForUpdatesNow','CreateDraftForID','DismissEmail','GetAuthStatus','GetComponentHealth','GetAdminInstallState','GetMode','GetPausedState','GetQueue','GetSettings','GetSettingsState','GetStartupState','GetUpdateState','MakeAuthenticatedGmailCall','PauseWatching','OpenDefaultAppsSettings','OpenStartupSettings','DismissDefaultAppsPrompt','ResumeWatching','SaveSettings','SetMode','SetAutostartEnabled','SetPaused','SetTrayError','SetTrayIdle','SetUpdateChecksEnabled','SignIn','StartAdminRepair','SignOut'];
  window.go = { main: { App: Object.fromEntries(methods.map((method) => [method, (...args) => call(method, ...args)])) } };
  let previous = '';
  setInterval(async () => { try { const queue = await call('GetQueue'); const next = JSON.stringify(queue); if (previous && next !== previous) emit('queue-update'); previous = next; } catch {} }, 50);
})();`;

export const test = base.extend<{ app: UserComponentFixture }>({
  app: async ({}, use) => {
    const queueDir = await mkdtemp(join(tmpdir(), 'gomapi-e2e-queue-'));
    const gmail = await startFakeGmail();
    const host = await startUserComponentHost(queueDir, gmail);
    const browser = await chromium.launch();
    const context = await browser.newContext();
    await context.addInitScript({ content: bridgeScript });
    const page = await context.newPage();
    page.on('console', (message) => {
      if (message.type() === 'error') process.stderr.write(`[browser] ${message.text()}\n`);
    });
    page.on('pageerror', (error) => process.stderr.write(`[browser] ${error.message}\n`));
    await page.goto(host.url);
    try {
      await use({
        page,
        queue: new QueueProducer(queueDir, () => page.evaluate(() => window.runtime.EventsEmit('queue-update'))),
        gmail,
      });
    } finally {
      await browser.close();
      await host.close();
      await gmail.close();
      await rm(queueDir, { recursive: true, force: true });
    }
  },
});

export { expect } from '@playwright/test';
