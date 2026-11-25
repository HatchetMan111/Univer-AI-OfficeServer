import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

// Static SPA build. The output (dist/) is committed to the repo so the
// Proxmox LXC needs no Node.js runtime — nginx serves the prebuilt files.
// `base: './'` keeps asset URLs relative so the app works behind any path/port.
export default defineConfig({
  base: './',
  plugins: [react()],
  build: {
    outDir: 'dist',
    emptyOutDir: true,
    chunkSizeWarningLimit: 4000,
    target: 'es2020',
  },
});