import { test, expect, type Page } from '@playwright/test';
import { createHash } from 'node:crypto';

// Runs only against a dev server started with VITE_GOOGLE_CLIENT_ID (see GIS_BASE_URL).
// Google's script is replaced by a stand-in: a real Google login cannot run in CI.
const BASE = process.env.GIS_BASE_URL;
const CLIENT_ID = process.env.GIS_CLIENT_ID ?? 'test-client.apps.googleusercontent.com';
const API = process.env.SUPABASE_URL ?? 'http://127.0.0.1:54321';
const ANON = process.env.SUPABASE_ANON_KEY
  ?? 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6ImFub24iLCJleHAiOjE5ODM4MTI5OTZ9.CRXP1A7WOeoJeXxjNni43kdQwgnWNReilDMblYTn_I0'; // local demo key
const SERVICE = process.env.SUPABASE_SERVICE_ROLE_KEY
  ?? 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImV4cCI6MTk4MzgxMjk5Nn0.EGIM96RAZx35lJzdJsyH-qQwv8Hdp7fsn3W0YpN81IU'; // local demo key

test.skip(!BASE, 'set GIS_BASE_URL to a dev server running with VITE_GOOGLE_CLIENT_ID');
test.use({ baseURL: BASE });

const FAKE_GIS = `window.google = { accounts: { id: {
  initialize(c) { window.__gis = c; window.__gisInits = (window.__gisInits || 0) + 1; },
  renderButton(el, o) { window.__gisOpts = o; const b = document.createElement('button'); b.type = 'button';
    b.textContent = 'Google (stand-in)'; b.onclick = () => window.__gis.callback({ credential: 'aaa.bbb.ccc' }); el.appendChild(b); },
  cancel() {} } } };`;

async function enableGoogle(page: Page, gis: 'ok' | 'blocked' = 'ok') {
  await page.route('**/auth/v1/settings', async (route) => {
    const res = await route.fetch(); const body = await res.json();
    await route.fulfill({ response: res, json: { ...body, external: { ...body.external, google: true } } });
  });
  await page.route('https://accounts.google.com/gsi/client', (route) =>
    gis === 'ok' ? route.fulfill({ contentType: 'text/javascript', body: FAKE_GIS }) : route.abort());
}

test('Google button: token + nonce go to Supabase and the user ends up signed in', async ({ page }) => {
  // A real session for a new user stands in for what Supabase returns after verifying Google's token.
  const email = `gis-${Date.now()}@e2e.bizpilot.local`;
  const headers = { apikey: SERVICE, Authorization: `Bearer ${SERVICE}`, 'content-type': 'application/json' };
  await fetch(`${API}/auth/v1/admin/users`, { method: 'POST', headers, body: JSON.stringify({ email, password: 'Gis-Password1', email_confirm: true }) });
  const session = await (await fetch(`${API}/auth/v1/token?grant_type=password`, {
    method: 'POST', headers: { apikey: ANON, 'content-type': 'application/json' }, body: JSON.stringify({ email, password: 'Gis-Password1' }),
  })).json();

  await enableGoogle(page);
  let sent: any = null;
  await page.route('**/auth/v1/token?grant_type=id_token', (route) => { sent = route.request().postDataJSON(); return route.fulfill({ json: session }); });
  await page.goto('/signup');
  await page.getByRole('button', { name: 'Google (stand-in)' }).click();
  await expect(page).toHaveURL(/\/onboarding/, { timeout: 15000 });

  const gis = await page.evaluate(() => ({ id: (window as any).__gis?.client_id, nonce: (window as any).__gis?.nonce, ux: (window as any).__gis?.ux_mode, text: (window as any).__gisOpts?.text }));
  expect(gis.id).toBe(CLIENT_ID);
  expect(gis.ux).toBe('popup');
  expect(gis.text).toBe('signup_with');
  expect(sent.provider).toBe('google');
  expect(sent.id_token).toBe('aaa.bbb.ccc');
  expect(sent.nonce).toBeTruthy();
  expect(createHash('sha256').update(sent.nonce).digest('hex')).toBe(gis.nonce); // Google gets the hash, Supabase the raw value

  // The session survives a reload (stored like any other Supabase session).
  await page.reload();
  await expect(page).toHaveURL(/\/onboarding/);
});

test('if Google’s script is blocked, the current redirect sign-in is used instead', async ({ page }) => {
  await enableGoogle(page, 'blocked');
  let authorize = '';
  await page.route('**/auth/v1/authorize**', (route) => { authorize = route.request().url(); return route.abort(); });
  await page.goto('/login');
  await page.getByRole('button', { name: /continue with google/i }).click();
  await expect.poll(() => authorize).toContain('provider=google');
});

test('a rejected Google token shows an error, offers the other way, and retries with a new nonce', async ({ page }) => {
  await enableGoogle(page);
  await page.route('**/auth/v1/token?grant_type=id_token', (route) => route.fulfill({
    status: 400, json: { code: 400, error_code: 'bad_jwt', msg: 'Bad ID token' },
  }));
  await page.goto('/login');
  await page.getByRole('button', { name: 'Google (stand-in)' }).click();
  await expect(page.getByRole('alert')).toContainText(/google sign-in is not available/i);
  await expect(page.getByRole('button', { name: /another way/i })).toBeVisible();
  await expect.poll(() => page.evaluate(() => (window as any).__gisInits)).toBeGreaterThanOrEqual(2);
  await expect(page).toHaveURL(/\/login/);
});
