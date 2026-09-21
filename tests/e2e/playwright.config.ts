import { defineConfig } from '@playwright/test';

// Cross-platform user-component coverage. Each worker owns an isolated queue
// directory and browser-backed Wails bridge.
//
// Trace retain-on-failure keeps debugging cheap without filling disk on
// green runs; HTML reporter is opened explicitly via `npx playwright
// show-report` so CI runs do not block on a browser launch.
export default defineConfig({
  testDir: '.',
  fullyParallel: true,
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
