import { defineConfig } from 'vitest/config';
import { svelte } from '@sveltejs/vite-plugin-svelte';
import { svelteTesting } from '@testing-library/svelte/vite';

export default defineConfig({
  // svelteTesting() aliases the Svelte browser entry into test bundles and
  // wires autocleanup — required for Svelte 5 runes-mode component tests.
  plugins: [svelte({ hot: !process.env.VITEST }), svelteTesting()],
  test: {
    globals: true,
    environment: 'jsdom',
    setupFiles: ['./src/test/setup.ts'],
    include: ['src/**/*.test.{ts,svelte}'],
    exclude: ['node_modules', 'dist', 'wailsjs'],
  },
});
