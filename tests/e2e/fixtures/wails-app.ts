import { test as base, chromium, type Page, type BrowserContext, type Browser } from '@playwright/test';
import { spawn, type ChildProcess } from 'node:child_process';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { existsSync } from 'node:fs';
import { createConnection } from 'node:net';
import treeKill from 'tree-kill';

import { startFakeGmail, type FakeGmailControl } from './fake-gmail';
import { startFakeOAuth, type FakeOAuthControl } from './fake-oauth';
import { WatchDirHelper } from './email';

// Phase 11 plan 06 — Playwright fixture that boots the e2e-tagged Wails app,
// connects to its WebView2 instance via CDP, and exposes helpers for tests.
//
// Boot sequence:
//   1. Start fake-gmail + fake-oauth servers on ephemeral ports.
//   2. Pick a free CDP port (try 9223..9233).
//   3. Build a one-hour-from-now OAuth token blob and stash it in env.
//   4. Spawn build/bin/go-mapi.exe with WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS
//      pointed at our chosen CDP port and the four GOMAPI_E2E_* overrides.
//   5. Poll http://127.0.0.1:$PORT/json/version until CDP responds (≤ 20s).
//   6. chromium.connectOverCDP → grab the first non-empty page.
//
// Teardown:
//   - Disconnect CDP (does NOT close WebView2 — we only borrow the channel).
//   - tree-kill the app PID with SIGKILL (Windows: spawns taskkill /T /F).
//   - Stop fake servers, remove tempdirs.
//
// One-instance constraint: the app uses a kernel-mode named mutex
// (singleinstance.go). Two e2e fixtures cannot be alive at once; Playwright
// is configured workers:1 / fullyParallel:false to enforce this.

export interface WailsAppFixture {
  page: Page;
  watchDir: WatchDirHelper;
  gmail: FakeGmailControl;
  oauth: FakeOAuthControl;
  appLogPath: string;
}

const REPO_ROOT = resolve(__dirname, '..', '..', '..');
const APP_BINARY = join(REPO_ROOT, 'src', 'app', 'build', 'bin', 'go-mapi.exe');

function isPortFree(port: number): Promise<boolean> {
  return new Promise((resolve) => {
    const socket = createConnection({ host: '127.0.0.1', port, timeout: 200 }, () => {
      socket.destroy();
      resolve(false); // something already listening
    });
    socket.on('error', () => resolve(true));
    socket.on('timeout', () => {
      socket.destroy();
      resolve(true);
    });
  });
}

async function pickCdpPort(): Promise<number> {
  for (let port = 9223; port <= 9233; port++) {
    if (await isPortFree(port)) return port;
  }
  throw new Error('e2e: no free CDP port in 9223..9233');
}

async function waitForCdp(port: number, timeoutMs: number): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  let lastErr: unknown = null;
  while (Date.now() < deadline) {
    try {
      const res = await fetch(`http://127.0.0.1:${port}/json/version`);
      if (res.ok) return;
    } catch (err) {
      lastErr = err;
    }
    await new Promise((r) => setTimeout(r, 250));
  }
  throw new Error(`e2e: CDP did not respond on 127.0.0.1:${port} within ${timeoutMs}ms (last error: ${lastErr})`);
}

function killTree(pid: number): Promise<void> {
  return new Promise((resolve) => {
    treeKill(pid, 'SIGKILL', () => resolve());
  });
}

async function pickAppPage(browser: Browser): Promise<{ context: BrowserContext; page: Page }> {
  // CDP exposes existing contexts; WebView2 typically has one. The Wails
  // page loads via wails:// scheme so any non-blank page is ours.
  const deadline = Date.now() + 10_000;
  while (Date.now() < deadline) {
    const contexts = browser.contexts();
    for (const ctx of contexts) {
      const pages = ctx.pages();
      for (const p of pages) {
        const url = p.url();
        if (url && url !== 'about:blank' && !url.startsWith('devtools://')) {
          return { context: ctx, page: p };
        }
      }
    }
    await new Promise((r) => setTimeout(r, 200));
  }
  throw new Error('e2e: no WebView2 page found via CDP within 10s');
}

export const test = base.extend<{ app: WailsAppFixture }>({
  app: async ({}, use) => {
    if (!existsSync(APP_BINARY)) {
      throw new Error(
        `e2e: ${APP_BINARY} missing — build the e2e binary first via scripts/run-e2e.ps1 or wails build -tags e2e`,
      );
    }

    const watchDir = await mkdtemp(join(tmpdir(), 'gomapi-e2e-watch-'));
    const appDataDir = await mkdtemp(join(tmpdir(), 'gomapi-e2e-appdata-'));
    const gmail = await startFakeGmail();
    const oauth = await startFakeOAuth();
    const cdpPort = await pickCdpPort();

    // Token expiry one hour out so refreshIfNeededLocked is a no-op.
    const tokenBlob = JSON.stringify({
      access_token: 'e2e-fake-token-do-not-use',
      refresh_token: 'e2e-fake-refresh-do-not-use',
      token_type: 'Bearer',
      expiry: new Date(Date.now() + 60 * 60 * 1000).toISOString(),
    });

    const env: NodeJS.ProcessEnv = {
      ...process.env,
      // GOMAPI_DEBUG_BROWSER_ARGS is honored by our vendored go-webview2 fork
      // (src/app/vendor/go-webview2-e2e/). The upstream wipes WebView2's own
      // WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS at package init so that route
      // does not work. See 11-06-SUMMARY.md for the full audit trail.
      GOMAPI_DEBUG_BROWSER_ARGS: `--remote-debugging-port=${cdpPort} --no-first-run`,
      GOMAPI_E2E_FAKE_TOKEN_JSON: tokenBlob,
      GOMAPI_E2E_GMAIL_BASE_URL: gmail.url,
      GOMAPI_E2E_TOKEN_ENDPOINT: oauth.tokenURL,
      GOMAPI_E2E_REVOKE_ENDPOINT: oauth.revokeURL,
      GOMAPI_WATCH_DIR: watchDir,
      GOMAPI_APPDATA_DIR: appDataDir,
    };

    const child: ChildProcess = spawn(APP_BINARY, [], {
      env,
      stdio: ['ignore', 'pipe', 'pipe'],
      windowsHide: false,
    });

    // Forward stdio to console for trace-on-failure visibility.
    child.stdout?.on('data', (b) => process.stdout.write(`[app] ${b}`));
    child.stderr?.on('data', (b) => process.stderr.write(`[app!] ${b}`));

    let appExitedEarly = false;
    child.on('exit', (code, sig) => {
      appExitedEarly = true;
      if (code !== 0 && code !== null) {
        process.stderr.write(`[app] exited code=${code} signal=${sig}\n`);
      }
    });

    let browser: Browser | null = null;
    let page: Page | null = null;
    try {
      await waitForCdp(cdpPort, 20_000);
      if (appExitedEarly) {
        throw new Error('e2e: app exited before CDP came up');
      }
      browser = await chromium.connectOverCDP(`http://127.0.0.1:${cdpPort}`);
      const picked = await pickAppPage(browser);
      page = picked.page;
      // Don't await full load — Wails page is already loaded by the time
      // CDP responds. waitForLoadState would hang on Wails' synthetic protocol.

      const appLogPath = join(appDataDir, 'app.log');
      await use({
        page,
        watchDir: new WatchDirHelper(watchDir),
        gmail,
        oauth,
        appLogPath,
      });
    } finally {
      try {
        if (browser) await browser.close();
      } catch {
        /* ignore — we only borrowed the CDP channel */
      }
      if (child.pid !== undefined) {
        await killTree(child.pid);
      }
      await gmail.close().catch(() => {});
      await oauth.close().catch(() => {});
      await rm(watchDir, { recursive: true, force: true }).catch(() => {});
      await rm(appDataDir, { recursive: true, force: true }).catch(() => {});
    }
  },
});

export { expect } from '@playwright/test';
