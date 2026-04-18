// Vitest global setup for the Wails Svelte 5 frontend.
// - jest-dom matchers for @testing-library/svelte assertions
// - localStorage.clear between tests (auth.hasSeenPreAuthExplainer reads it)
// - vi.clearAllMocks after each test to avoid cross-test leakage
//
// Intentionally NO chrome.* stubs: Svelte app uses wailsjs bindings, not Chrome APIs.
// Intentionally NO default fetch stub: auth.ts and queue.ts call wailsjs, not fetch.
import '@testing-library/jest-dom';
import { beforeEach, afterEach, vi } from 'vitest';

beforeEach(() => {
  localStorage.clear();
});

afterEach(() => {
  vi.clearAllMocks();
});
