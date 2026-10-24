import { test, expect, chromium } from '@playwright/test';
import http from 'node:http';
import { existsSync, readFileSync } from 'node:fs';
import { extname, join } from 'node:path';

// Returning visitors must not keep running an old deployment (that kept the old Google
// sign-in on screen). Serves two production builds on one origin, like a Vercel redeploy.
// Build them first, e.g.:  npx vite build --outDir /tmp/a && npx vite build --outDir /tmp/b
const A = process.env.PWA_BUILD_A;
const B = process.env.PWA_BUILD_B;
test.skip(!A || !B, 'set PWA_BUILD_A and PWA_BUILD_B to two production builds');

const types: Record<string, string> = { '.js': 'text/javascript', '.css': 'text/css', '.html': 'text/html', '.png': 'image/png', '.svg': 'image/svg+xml', '.ico': 'image/x-icon', '.webmanifest': 'application/manifest+json' };
function serve(port: number, dir: () => string) {
  return http.createServer((req, res) => {
    const path = new URL(req.url ?? '/', 'http://x').pathname;
    let f = join(dir(), path);
    if (!existsSync(f) || !extname(f)) f = join(dir(), 'index.html');
    res.writeHead(200, { 'content-type': types[extname(f)] ?? 'text/html', 'cache-control': path.startsWith('/assets/') ? 'public, max-age=31536000, immutable' : 'public, max-age=0, must-revalidate' });
    res.end(readFileSync(f));
  }).listen(port);
}

test('a new deployment replaces the saved version on public pages without the user clicking Update', async () => {
  let dir = A!;
  const server = serve(4192, () => dir);
  const ctx = await chromium.launchPersistentContext('', { executablePath: '/opt/pw-browsers/chromium' });
  try {
    const page = ctx.pages()[0] ?? await ctx.newPage();
    // The page may reload itself while we look (that is the behaviour under test).
    const bundle = () => page.evaluate(() => [...document.scripts].map((s) => s.src).find((s) => s.includes('/assets/index-'))?.split('/').pop())
      .catch(() => 'reloading');
    await page.goto('http://localhost:4192/login');
    await page.evaluate(() => navigator.serviceWorker.ready);
    await page.reload();
    expect(await page.evaluate(() => Boolean(navigator.serviceWorker.controller))).toBe(true);
    const before = await bundle();

    dir = B!; // redeploy
    await page.evaluate(() => navigator.serviceWorker.getRegistration().then((r) => r?.update()));
    await expect.poll(async () => { const b = await bundle(); return b !== before && b !== 'reloading'; }, { timeout: 15000 }).toBe(true);
    await page.goto('http://localhost:4192/signup');
    await expect.poll(async () => { const b = await bundle(); return b !== before && b !== 'reloading'; }).toBe(true);
  } finally {
    await ctx.close();
    server.close();
  }
});
