import { defineConfig } from '@playwright/test';

// Phase 11 plan 06 — Playwright config for the WebView2/CDP harness.
//
// Single worker / non-parallel: WebView2 only exposes one CDP endpoint per
// process and the e2e binary is not safe to run in parallel against the same
// keyring service entry. Locked decision D-E2E-03.
//
// Trace retain-on-failure keeps debugging cheap without filling disk on
// green runs; HTML reporter is opened explicitly via `npx playwright
// show-report` so CI runs do not block on a browser launch.
export default defineConfig({
  testDir: '.',
  fullyParallel: false,
  workers: 1,
  retries: 0,
  timeout: 30_000,
  expect: { timeout: 5_000 },
  reporter: [
    ['list'],
    ['html', { open: 'never' }],
  ],
  use: {
    trace: 'retain-on-failure',
  },
});
