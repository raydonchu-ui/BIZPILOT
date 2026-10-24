// Checks whether Google allows its sign-in button on each site address for the configured
// Client ID (Google Cloud → Clients → Authorized JavaScript origins), without logging in.
// Usage: npm run build && node scripts/check-google-origins.mjs [origin ...]
// Exit code 0 = every origin allowed.
import { chromium } from '@playwright/test';
import { existsSync, readFileSync } from 'node:fs';
import { extname, join } from 'node:path';

const DIST = process.env.DIST ?? 'dist';
const origins = process.argv.slice(2).length ? process.argv.slice(2) : ['https://www.bizpilotmarket.com', 'https://bizpilotmarket.com'];
const types = { '.js': 'text/javascript', '.css': 'text/css', '.html': 'text/html', '.png': 'image/png', '.svg': 'image/svg+xml', '.ico': 'image/x-icon', '.webmanifest': 'application/manifest+json' };
const browser = await chromium.launch({ executablePath: process.env.CHROMIUM_PATH ?? '/opt/pw-browsers/chromium' });
let ok = true;
for (const origin of origins) {
  const ctx = await browser.newContext({ serviceWorkers: 'block' });
  const page = await ctx.newPage();
  // Serve the local build *as if* it were hosted at this origin.
  await page.route(`${origin}/**`, (r) => {
    const f = join(DIST, new URL(r.request().url()).pathname);
    const file = existsSync(f) && extname(f) ? f : join(DIST, 'index.html');
    return r.fulfill({ body: readFileSync(file), contentType: types[extname(file)] ?? 'text/html' });
  });
  await page.route('**/auth/v1/settings', (r) => r.fulfill({ json: { external: { google: true, email: true } } }));
  let status = 0;
  page.on('response', (res) => { if (new URL(res.url()).pathname === '/gsi/button') status = res.status(); });
  await page.goto(`${origin}/login`);
  await page.waitForTimeout(6000);
  const allowed = status === 200;
  ok &&= allowed;
  console.log(`${allowed ? 'ALLOWED    ' : 'NOT ALLOWED'} ${origin} (Google button response: ${status || 'none'})`);
  await ctx.close();
}
await browser.close();
process.exit(ok ? 0 : 1);
