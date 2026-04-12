import { defineConfig, type Plugin } from 'vite';
import react from '@vitejs/plugin-react';
import { resolve } from 'path';
import { readFileSync, writeFileSync } from 'fs';

function stampManifestVersion(): Plugin {
  return {
    name: 'stamp-manifest-version',
    writeBundle({ dir }) {
      const rootPkg = JSON.parse(readFileSync(resolve(__dirname, '../../package.json'), 'utf-8'));
      const manifestPath = resolve(dir!, 'manifest.json');
      const manifest = JSON.parse(readFileSync(manifestPath, 'utf-8'));
      manifest.version = rootPkg.version;
      writeFileSync(manifestPath, JSON.stringify(manifest, null, 2) + '\n');
    },
  };
}

export default defineConfig({
  plugins: [react(), stampManifestVersion()],
  build: {
    outDir: 'dist',
    emptyOutDir: true,
    rollupOptions: {
      input: {
        popup: resolve(__dirname, 'popup.html'),
        'service-worker': resolve(__dirname, 'src/background/service-worker.ts'),
      },
      output: {
        entryFileNames: (chunkInfo) => {
          if (chunkInfo.name === 'service-worker') {
            return 'service-worker.js';
          }
          return 'assets/[name]-[hash].js';
        },
        chunkFileNames: 'assets/[name]-[hash].js',
        assetFileNames: 'assets/[name]-[hash].[ext]',
      },
    },
  },
});
