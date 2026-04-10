import { defineConfig } from '@playwright/test';

// E2E-01: Playwright configuration for Phase 4.
//
// Chromium extensions require `launchPersistentContext` + headed mode,
// which in turn forces `workers: 1` (parallel contexts don't work with
// extensions). CI retries are enabled per the E2E-05 spike findings;
// local runs surface flakes immediately with retries: 0.

export default defineConfig({
  testDir: '.',
  testMatch: '**/*.spec.ts',
  timeout: 90_000, // 90s — leaves headroom for service-worker bootstrap
  retries: process.env.CI ? 2 : 0,
  workers: 1, // Extensions require single worker — Playwright limitation.

  use: {
    headless: false, // Chrome extensions require headed mode
    viewport: { width: 400, height: 600 },
    trace: process.env.CI ? 'retain-on-failure' : 'off',
  },

  reporter: [['list'], ['html', { outputFolder: 'playwright-report', open: 'never' }]],
});
