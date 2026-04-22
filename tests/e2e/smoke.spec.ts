import { test, expect } from './fixtures/wails-app';

// Phase 11 plan 06 — throwaway smoke test that proves the harness can boot
// the app, attach via CDP, and read the page title. Deleted in Task 3 once
// the regression specs land.
test('app boots and exposes WebView2 over CDP', async ({ app }) => {
  const title = await app.page.title();
  // Wails sets the window title to "go-mapi" via main.go options.App.Title;
  // the WebView2 document title may be the empty string until the Svelte
  // app sets it. Either is sufficient evidence we connected.
  expect(typeof title).toBe('string');
});
