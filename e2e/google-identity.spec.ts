import { test, expect, type Page } from '@playwright/test';
import { createHash } from 'node:crypto';
import { passStoreLock } from './storeLockHelper';

// Runs only against a dev/preview server built with VITE_GOOGLE_CLIENT_ID (GIS_BASE_URL).
// Google's script is replaced by a stand-in (a real Google login cannot run in CI). The token
// exchange answer is a real Supabase session for a test user, so everything after Google —
// session storage, refresh, dashboard, sign-out — runs for real.
const BASE = process.env.GIS_BASE_URL;
const CLIENT_ID = process.env.GIS_CLIENT_ID ?? '123456789012-teststandin.apps.googleusercontent.com';
const API = process.env.SUPABASE_URL ?? 'http://127.0.0.1:54321';
const ANON = process.env.SUPABASE_ANON_KEY
  ?? 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6ImFub24iLCJleHAiOjE5ODM4MTI5OTZ9.CRXP1A7WOeoJeXxjNni43kdQwgnWNReilDMblYTn_I0'; // local demo key
const SERVICE = process.env.SUPABASE_SERVICE_ROLE_KEY
  ?? 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImV4cCI6MTk4MzgxMjk5Nn0.EGIM96RAZx35lJzdJsyH-qQwv8Hdp7fsn3W0YpN81IU'; // local demo key

test.skip(!BASE, 'set GIS_BASE_URL to a server built with VITE_GOOGLE_CLIENT_ID');
test.use({ baseURL: BASE });

// Stand-in for https://accounts.google.com/gsi/client. Clicking its button calls the page's
// callback like Google does; "double" fires it twice to simulate a double submit.
const FAKE_GIS = `window.google = { accounts: { id: {
  initialize(c) { window.__gis = c; window.__gisInits = (window.__gisInits || 0) + 1; },
  renderButton(el, o) { window.__gisOpts = o;
    const b = document.createElement('button'); b.type = 'button'; b.textContent = 'Google (stand-in)';
    b.onclick = () => window.__gis.callback({ credential: 'aaa.bbb.ccc' }); el.appendChild(b);
    const d = document.createElement('button'); d.type = 'button'; d.textContent = 'Google double (stand-in)';
    d.onclick = () => { window.__gis.callback({ credential: 'aaa.bbb.ccc' }); window.__gis.callback({ credential: 'aaa.bbb.ccc' }); }; el.appendChild(d); },
  cancel() {} } } };`;

type GisMode = 'ok' | 'blocked' | 'slow' | 'blocked-then-ok';
async function setup(page: Page, gis: GisMode = 'ok') {
  await page.route('**/auth/v1/settings', async (route) => {
    const res = await route.fetch(); const body = await res.json();
    await route.fulfill({ response: res, json: { ...body, external: { ...body.external, google: true } } });
  });
  let calls = 0;
  await page.route('https://accounts.google.com/gsi/client', async (route) => {
    calls++;
    if (gis === 'blocked' || (gis === 'blocked-then-ok' && calls <= 2)) return route.abort();
    if (gis === 'slow') await new Promise((r) => setTimeout(r, 4000));
    return route.fulfill({ contentType: 'text/javascript', body: FAKE_GIS });
  });
  const oauth: string[] = [];
  await page.route('**/auth/v1/authorize**', (route) => { oauth.push(route.request().url()); return route.abort(); });
  return { oauth };
}

async function testUser(withBusiness: boolean) {
  const email = `gis-${Date.now()}-${Math.random().toString(36).slice(2, 6)}@e2e.bizpilot.local`;
  const password = 'Gis-Password1';
  const headers = { apikey: SERVICE, Authorization: `Bearer ${SERVICE}`, 'content-type': 'application/json' };
  await fetch(`${API}/auth/v1/admin/users`, { method: 'POST', headers, body: JSON.stringify({ email, password, email_confirm: true, user_metadata: { full_name: 'Gis Person' } }) });
  const session = async () => (await fetch(`${API}/auth/v1/token?grant_type=password`, {
    method: 'POST', headers: { apikey: ANON, 'content-type': 'application/json' }, body: JSON.stringify({ email, password }),
  })).json();
  if (withBusiness) {
    const s = await session();
    await fetch(`${API}/rest/v1/rpc/create_business`, {
      method: 'POST', headers: { apikey: ANON, Authorization: `Bearer ${s.access_token}`, 'content-type': 'application/json' },
      body: JSON.stringify({ p: { name: 'GIS Test Shop', owner_name: 'Gis Person', country_code: 'CM', language: 'en', category: 'grocery' } }),
    });
  }
  return { session };
}

// Answers Supabase's id_token exchange with a real session; records what the page sent.
async function answerTokenExchange(page: Page, session: () => Promise<unknown>) {
  const sent: any[] = [];
  await page.route('**/auth/v1/token?grant_type=id_token', async (route) => {
    sent.push(route.request().postDataJSON());
    await new Promise((r) => setTimeout(r, 300));
    return route.fulfill({ json: await session() });
  });
  return sent;
}

test('Google button runs GIS (not the redirect flow); token + nonce reach Supabase; session survives refresh, sign-out and sign-in again', async ({ page }) => {
  const user = await testUser(true);
  const { oauth } = await setup(page);
  const sent = await answerTokenExchange(page, user.session);

  await page.goto('/login');
  await expect(page.locator('[data-google-mode]')).toHaveAttribute('data-google-mode', 'gis');
  await page.getByRole('button', { name: 'Google (stand-in)' }).click();
  await expect(page).toHaveURL(/\/app$/, { timeout: 15000 });
  await passStoreLock(page);
  await expect(page.getByRole('heading', { level: 1 })).toBeVisible();

  const gis = await page.evaluate(() => ({ id: (window as any).__gis?.client_id, nonce: (window as any).__gis?.nonce, ux: (window as any).__gis?.ux_mode }));
  expect(gis.id).toBe(CLIENT_ID);
  expect(gis.ux).toBe('popup');
  expect(sent).toHaveLength(1);
  expect(sent[0]).toMatchObject({ provider: 'google', id_token: 'aaa.bbb.ccc' });
  expect(createHash('sha256').update(sent[0].nonce).digest('hex')).toBe(gis.nonce); // hash to Google, raw value to Supabase
  expect(oauth).toEqual([]); // the old Supabase-hosted OAuth flow never started
  // No Google credential is kept in browser storage.
  expect(await page.evaluate(() => JSON.stringify({ ...localStorage, ...sessionStorage }).includes('aaa.bbb.ccc'))).toBe(false);

  await page.reload();
  await expect(page).toHaveURL(/\/app$/);
  await expect(page.getByRole('heading', { level: 1 })).toBeVisible();

  await page.getByRole('button', { name: /Gis Person/ }).click();
  await page.getByRole('button', { name: 'Log out' }).click();
  await expect(page).toHaveURL(/\/login/);
  await page.getByRole('button', { name: 'Google (stand-in)' }).click();
  await expect(page).toHaveURL(/\/app$/, { timeout: 15000 });
  await passStoreLock(page);
  expect(sent).toHaveLength(2);
  expect(sent[1].nonce).not.toBe(sent[0].nonce); // new nonce per page/attempt
  expect(oauth).toEqual([]);
});

test('a new Google user is sent to onboarding', async ({ page }) => {
  const user = await testUser(false);
  await setup(page);
  await answerTokenExchange(page, user.session);
  await page.goto('/signup');
  await expect(page.getByRole('button', { name: 'Google (stand-in)' })).toBeVisible();
  expect(await page.evaluate(() => (window as any).__gisOpts?.text)).toBe('signup_with');
  await page.getByRole('button', { name: 'Google (stand-in)' }).click();
  await expect(page).toHaveURL(/\/onboarding/, { timeout: 15000 });
});

test('a double callback sends only one sign-in request', async ({ page }) => {
  const user = await testUser(true);
  await setup(page);
  const sent = await answerTokenExchange(page, user.session);
  await page.goto('/login');
  await page.getByRole('button', { name: 'Google double (stand-in)' }).click();
  await expect(page).toHaveURL(/\/app$/, { timeout: 15000 });
  await passStoreLock(page);
  expect(sent).toHaveLength(1);
});

test('blocked Google script: explains why, never redirects on its own, and Retry recovers', async ({ page }) => {
  const { oauth } = await setup(page, 'blocked-then-ok');
  await page.goto('/login');
  await expect(page.getByText(/could not load/i)).toBeVisible({ timeout: 20000 });
  await expect(page.locator('[data-google-mode]')).toHaveAttribute('data-google-mode', 'failed');
  await page.waitForTimeout(500);
  expect(oauth).toEqual([]); // no silent fallback
  await page.getByRole('button', { name: /try again/i }).click();
  await expect(page.getByRole('button', { name: 'Google (stand-in)' })).toBeVisible({ timeout: 20000 });
  expect(oauth).toEqual([]);
});

test('blocked Google script: the standard Google sign-in runs only when the user chooses it', async ({ page }) => {
  const { oauth } = await setup(page, 'blocked');
  await page.goto('/login');
  await page.getByRole('button', { name: /standard google sign-in/i }).click({ timeout: 20000 });
  await expect.poll(() => oauth.length).toBe(1);
  expect(oauth[0]).toContain('provider=google');
});

test('a slow Google script still loads', async ({ page }) => {
  await setup(page, 'slow');
  await page.goto('/login');
  await expect(page.getByRole('button', { name: 'Google (stand-in)' })).toBeVisible({ timeout: 20000 });
});

test('a rejected Google token shows an error and retries with a new nonce', async ({ page }) => {
  await setup(page);
  await page.route('**/auth/v1/token?grant_type=id_token', (route) => route.fulfill({ status: 400, json: { code: 400, error_code: 'bad_jwt', msg: 'Bad ID token' } }));
  await page.goto('/login');
  const first = await page.evaluate(() => (window as any).__gis?.nonce);
  await page.getByRole('button', { name: 'Google (stand-in)' }).click();
  await expect(page.getByRole('alert')).toContainText(/google sign-in is not available/i);
  await expect(page.getByRole('button', { name: /another way/i })).toBeVisible();
  await expect.poll(() => page.evaluate(() => (window as any).__gis?.nonce)).not.toBe(first);
  await expect(page).toHaveURL(/\/login/);
});

test('diagnostics page reports the build’s Google sign-in setup without secrets', async ({ page }) => {
  await setup(page);
  await page.goto('/auth/diagnostics');
  const d = page.getByTestId('diagnostics');
  await expect(d).toContainText('Google Identity Services');
  await expect(d).toContainText('configured: 1234…9012-test….apps.googleusercontent.com');
  await expect(d).toContainText(new URL(BASE!).origin);
  await expect(d).not.toContainText(CLIENT_ID);
});
