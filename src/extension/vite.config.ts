import { defineConfig, type Plugin } from 'vite';
import react from '@vitejs/plugin-react';
import { resolve } from 'path';
import { readFileSync, writeFileSync } from 'fs';
import { execSync } from 'child_process';

function stampManifestVersion(): Plugin {
  return {
    name: 'stamp-manifest-version',
    writeBundle({ dir }) {
      const extPkg = JSON.parse(readFileSync(resolve(__dirname, 'package.json'), 'utf-8'));
      const manifestPath = resolve(dir!, 'manifest.json');
      const manifest = JSON.parse(readFileSync(manifestPath, 'utf-8'));

      // Strip any prerelease/build metadata for base version
      const baseVersion = extPkg.version.replace(/[-+].*$/, '');

      if (process.env.NODE_ENV === 'production') {
        // CWS requires integer-only semver: use base version only
        manifest.version = baseVersion;
      } else {
        // Dev builds: {version}-dev+{commithash} (per D-07)
        let hash = 'unknown';
        try {
          hash = execSync('git rev-parse --short HEAD', { encoding: 'utf-8' }).trim();
        } catch {
          // not in a git repo or git not available
        }
        manifest.version = `${baseVersion}-dev+${hash}`;
      }

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
