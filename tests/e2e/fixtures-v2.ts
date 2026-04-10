import {
  test as base,
  chromium,
  type BrowserContext,
  type Page,
} from '@playwright/test';
import { execSync, spawn } from 'child_process';
import * as fs from 'fs';
import * as path from 'path';
import * as os from 'os';

// E2E-03/04: Playwright fixtures for the Phase 4 specs.
//
// This file lives alongside the pre-existing `fixtures.ts` (consumed by
// `extension.spec.ts`) and does NOT modify it — phase 4 specs use this
// v2 version which:
//  - drives native-manifest registration from the test body, not from
//    the fixture initializer, so install-ux.spec.ts can assert the
//    "no manifest registered" state before writing one;
//  - launches a stdlib mock Gmail server (tests/e2e/mock-gmail) so the
//    go-mapi native host hits a deterministic endpoint via FOUND-04's
//    --gmail-api-base flag;
//  - uses the per-test GOMAPI_WATCH_DIR env var to isolate file drops
//    without touching %TEMP%\go-mapi\.
//
// Stable wait patterns from 04-E2E-SPIKE.md apply throughout.

const ROOT_DIR = path.resolve(__dirname, '../..');
const EXTENSION_PATH = path.join(ROOT_DIR, 'src/extension/dist');
const NATIVE_HOST_PATH = path.join(
  ROOT_DIR,
  'src/native-host/build/go-mapi-host.exe',
);
const MOCK_GMAIL_PATH = path.join(
  ROOT_DIR,
  'tests/e2e/mock-gmail/mock-gmail.exe',
);
const MOCK_HOST_PATH = path.join(
  ROOT_DIR,
  'tests/e2e/mock-host/mock-host.exe',
);

const CHROME_HOST_REG =
  'HKCU\\Software\\Google\\Chrome\\NativeMessagingHosts\\com.gomapi.host';
const EDGE_HOST_REG =
  'HKCU\\Software\\Microsoft\\Edge\\NativeMessagingHosts\\com.gomapi.host';

function findBrowser(): string {
  const candidates = [
    'C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe',
    'C:\\Program Files\\Microsoft\\Edge\\Application\\msedge.exe',
    'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe',
    'C:\\Program Files (x86)\\Google\\Chrome\\Application\\chrome.exe',
  ];
  for (const p of candidates) {
    if (fs.existsSync(p)) return p;
  }
  throw new Error('No Chrome or Edge browser found');
}

export interface MockGmailHandle {
  url: string;
  stop: () => void;
  drafts: () => Promise<number>;
}

/** Launch the stdlib Go mock Gmail server as a child process. */
export async function startMockGmail(): Promise<MockGmailHandle> {
  if (!fs.existsSync(MOCK_GMAIL_PATH)) {
    throw new Error(
      `mock-gmail.exe not found at ${MOCK_GMAIL_PATH} — run 'go build' in tests/e2e/mock-gmail first`,
    );
  }

  const child = spawn(MOCK_GMAIL_PATH, ['--port', '0'], {
    stdio: ['ignore', 'pipe', 'pipe'],
  });

  // Parse "LISTENING <url>\n" from stdout to learn the bound port.
  const url = await new Promise<string>((resolve, reject) => {
    const timer = setTimeout(() => {
      child.kill();
      reject(new Error('mock-gmail did not emit LISTENING line within 5s'));
    }, 5_000);

    let buf = '';
    child.stdout.on('data', (chunk: Buffer) => {
      buf += chunk.toString('utf8');
      const match = buf.match(/LISTENING\s+(\S+)/);
      if (match) {
        clearTimeout(timer);
        resolve(match[1]);
      }
    });
    child.on('error', (err) => {
      clearTimeout(timer);
      reject(err);
    });
  });

  return {
    url,
    stop: () => {
      // SIGKILL on Windows because Go's signal handling for SIGTERM is
      // not reliable there. Best-effort — failing to kill is tolerable.
      try {
        child.kill('SIGKILL');
      } catch {
        /* ignore */
      }
    },
    drafts: async () => {
      const res = await fetch(url + '/__count');
      const body = (await res.json()) as { drafts: number };
      return body.drafts;
    },
  };
}

export interface NativeHostManifestOptions {
  extensionId: string;
  hostBinary: string;
  args?: string[];
}

/**
 * Write a native-messaging manifest JSON file and register it in HKCU
 * for both Chrome and Edge. Returns the manifest path for cleanup.
 */
export function writeNativeManifest(opts: NativeHostManifestOptions): string {
  const manifestDir = fs.mkdtempSync(
    path.join(os.tmpdir(), 'go-mapi-e2e-manifest-'),
  );
  const manifestPath = path.join(manifestDir, 'com.gomapi.host.json');

  const manifest = {
    name: 'com.gomapi.host',
    description: 'go-mapi Native Messaging Host (e2e)',
    path: opts.hostBinary,
    type: 'stdio',
    allowed_origins: [`chrome-extension://${opts.extensionId}/`],
    // Chrome reads `path` as the executable and passes remaining args
    // from the manifest? Actually Chrome does NOT support "args" — flags
    // must be baked into the executable path via a .bat/.cmd wrapper on
    // Windows. For the native host we therefore write a small wrapper.
  };

  fs.writeFileSync(manifestPath, JSON.stringify(manifest, null, 2));

  const cmds = [
    `reg add "${CHROME_HOST_REG}" /ve /t REG_SZ /d "${manifestPath}" /f`,
    `reg add "${EDGE_HOST_REG}" /ve /t REG_SZ /d "${manifestPath}" /f`,
  ];
  for (const cmd of cmds) {
    try {
      execSync(cmd, { stdio: 'pipe' });
    } catch {
      /* ignore — browser may not be installed */
    }
  }

  return manifestPath;
}

/**
 * Write a batch wrapper for the real go-mapi native host that passes
 * `--watch-dir` and `--gmail-api-base` on every invocation. Chrome
 * invokes the manifest `path` directly with no arg injection; wrapping
 * in .cmd is the canonical workaround.
 */
export function writeHostWrapper(
  watchDir: string,
  gmailAPIBase: string,
): string {
  const wrapperDir = fs.mkdtempSync(
    path.join(os.tmpdir(), 'go-mapi-e2e-wrapper-'),
  );
  const wrapperPath = path.join(wrapperDir, 'go-mapi-host.cmd');
  const content = [
    '@echo off',
    `"${NATIVE_HOST_PATH}" --watch-dir "${watchDir}" --gmail-api-base "${gmailAPIBase}" %*`,
  ].join('\r\n');
  fs.writeFileSync(wrapperPath, content);
  return wrapperPath;
}

/** Remove the HKCU native-messaging host registration for both browsers. */
export function unregisterNativeManifest(): void {
  for (const key of [CHROME_HOST_REG, EDGE_HOST_REG]) {
    try {
      execSync(`reg delete "${key}" /f`, { stdio: 'pipe' });
    } catch {
      /* ignore — key may already be missing */
    }
  }
}

// --- Playwright fixtures ---

type PhaseFourFixtures = {
  extensionContext: BrowserContext;
  extensionId: string;
  popupPage: Page;
};

export const test = base.extend<PhaseFourFixtures>({
  extensionContext: async ({}, use) => {
    if (!fs.existsSync(EXTENSION_PATH)) {
      throw new Error(
        `Extension dist not found at ${EXTENSION_PATH} — run 'npm run build:extension' first`,
      );
    }
    const userDataDir = fs.mkdtempSync(
      path.join(os.tmpdir(), 'go-mapi-e2e-userdata-'),
    );

    // Pattern A from 04-E2E-SPIKE: explicit browser args to avoid
    // first-run prompts that can steal focus on windows-latest.
    const context = await chromium.launchPersistentContext(userDataDir, {
      headless: false,
      executablePath: findBrowser(),
      args: [
        `--disable-extensions-except=${EXTENSION_PATH}`,
        `--load-extension=${EXTENSION_PATH}`,
        '--no-first-run',
        '--disable-default-apps',
        '--no-default-browser-check',
      ],
    });

    await use(context);

    await context.close();
    fs.rmSync(userDataDir, { recursive: true, force: true });
  },

  extensionId: async ({ extensionContext }, use) => {
    // Pattern A: always await the service-worker event if not present.
    let sw = extensionContext.serviceWorkers()[0];
    if (!sw) {
      sw = await extensionContext.waitForEvent('serviceworker', {
        timeout: 15_000,
      });
    }
    const extensionId = sw.url().split('/')[2];
    await use(extensionId);
  },

  popupPage: async ({ extensionContext, extensionId }, use) => {
    const popupUrl = `chrome-extension://${extensionId}/popup.html`;
    const page = await extensionContext.newPage();
    await page.goto(popupUrl);
    // Pattern B: wait for networkidle so React has committed first render.
    await page.waitForLoadState('domcontentloaded');
    await page.waitForLoadState('networkidle').catch(() => {
      /* networkidle can race on extension pages; tolerated */
    });
    await use(page);
    await page.close();
  },
});

export { expect } from '@playwright/test';
