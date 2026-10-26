import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
import { VitePWA } from 'vite-plugin-pwa';

// Vercel system variables (available during Vercel builds). Public build facts only, shown on
// /auth/diagnostics so a deployment can be identified. No secrets.
const env = process.env;
const buildInfo = {
  env: env.VERCEL_ENV ?? 'local',
  commit: (env.VERCEL_GIT_COMMIT_SHA ?? '').slice(0, 7),
  branch: env.VERCEL_GIT_COMMIT_REF ?? '',
  projectDomain: env.VERCEL_PROJECT_PRODUCTION_URL ?? '',
  deploymentUrl: env.VERCEL_URL ?? '',
  builtAt: new Date().toISOString(),
};
// Preview deployments must never be served from an older cached copy: there the service
// worker removes itself instead of caching. Production keeps the offline-capable app.
const isPreview = env.VERCEL_ENV === 'preview';

export default defineConfig({
  define: { __BUILD_INFO__: JSON.stringify(buildInfo) },
  plugins: [
    react(),
    VitePWA({
      selfDestroying: isPreview,
      registerType: 'prompt',
      includeAssets: ['favicon.ico', 'apple-touch-icon.png', 'brand/*.png', 'brand/*.svg'],
      manifest: {
        name: 'BizPilot',
        short_name: 'BizPilot',
        description: 'Retail management, inventory and profit analytics for shop owners.',
        theme_color: '#0f3f24',
        background_color: '#ffffff',
        display: 'standalone',
        start_url: '/app',
        scope: '/',
        icons: [
          { src: '/pwa-192.png', sizes: '192x192', type: 'image/png' },
          { src: '/pwa-512.png', sizes: '512x512', type: 'image/png' },
          { src: '/pwa-maskable-512.png', sizes: '512x512', type: 'image/png', purpose: 'maskable' },
        ],
      },
      workbox: {
        // A new deployment's service worker takes over at once instead of waiting until every
        // tab is closed or "Update" is clicked; otherwise returning visitors keep running the
        // previous version. PwaPrompt decides when the page itself reloads.
        skipWaiting: true,
        clientsClaim: true,
        // Shows message notifications when push arrives while the app is closed (public/push-sw.js).
        importScripts: ['push-sw.js'],
        cleanupOutdatedCaches: true,
        // Only the application shell and static assets are cached. Business data
        // (Supabase API responses) is never cached by the service worker.
        globPatterns: ['**/*.{js,css,html,ico,png,svg,woff2}'],
        navigateFallback: '/index.html',
        navigateFallbackDenylist: [/^\/api/, /^\/auth/],
        runtimeCaching: [
          {
            urlPattern: /^https:\/\/fonts\.(googleapis|gstatic)\.com\/.*/i,
            handler: 'CacheFirst',
            options: { cacheName: 'fonts', expiration: { maxEntries: 20, maxAgeSeconds: 60 * 60 * 24 * 365 } },
          },
        ],
      },
    }),
  ],
  server: { port: 5173, host: true },
  preview: { port: 4173, host: true },
  build: { chunkSizeWarningLimit: 1200 },
});
