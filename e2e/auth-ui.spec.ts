import { test, expect } from '@playwright/test';

const API = process.env.SUPABASE_URL ?? 'http://127.0.0.1:54321';
const SERVICE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY
  ?? 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImV4cCI6MTk4MzgxMjk5Nn0.EGIM96RAZx35lJzdJsyH-qQwv8Hdp7fsn3W0YpN81IU'; // local demo key

test('password fields have a show/hide button', async ({ page }) => {
  await page.goto('/signup');
  const pw = page.getByLabel(/^password/i);
  await pw.fill('Secret123');
  await expect(pw).toHaveAttribute('type', 'password');
  const toggles = page.getByRole('button', { name: /show password/i });
  await expect(toggles).toHaveCount(2);
  await toggles.first().click();
  await expect(pw).toHaveAttribute('type', 'text');
  await page.getByRole('button', { name: /hide password/i }).click();
  await expect(pw).toHaveAttribute('type', 'password');

  await page.goto('/login');
  await expect(page.getByRole('button', { name: /show password/i })).toHaveCount(1);
});

test('Google button is hidden until Google is enabled, then starts the Google flow', async ({ page }) => {
  await page.goto('/login');
  await expect(page.getByRole('heading', { level: 1 })).toBeVisible();
  await expect(page.getByRole('button', { name: /continue with google/i })).toHaveCount(0);

  await page.route('**/auth/v1/settings', async (route) => {
    const res = await route.fetch();
    const body = await res.json();
    await route.fulfill({ response: res, json: { ...body, external: { ...body.external, google: true } } });
  });
  let authorizeUrl = '';
  await page.route('**/auth/v1/authorize**', (route) => { authorizeUrl = route.request().url(); return route.abort(); });
  const logs: string[] = [];
  page.on('console', (m) => logs.push(m.text()));
  await page.goto('/signup');
  await expect(page.getByText(/by continuing with google you agree/i)).toBeVisible();
  // This build has no VITE_GOOGLE_CLIENT_ID: the redirect flow is used, and the reason is stated.
  await expect(page.locator('[data-google-mode]')).toHaveAttribute('data-google-mode', 'redirect');
  await expect(page.locator('[data-google-mode]')).toHaveAttribute('data-google-reason', 'missing');
  await expect.poll(() => logs.some((l) => l.includes('Supabase redirect flow (client_id_missing)'))).toBe(true);
  await page.getByRole('button', { name: /continue with google/i }).click();
  await expect.poll(() => authorizeUrl).toContain('provider=google');
  const u = new URL(authorizeUrl);
  expect(u.searchParams.get('redirect_to')).toMatch(/\/auth\/callback$/);
});

test('sign-in callback finishes the session and continues to onboarding', async ({ page, baseURL }) => {
  const email = `oauth-${Date.now()}@e2e.bizpilot.local`;
  const headers = { apikey: SERVICE_KEY, Authorization: `Bearer ${SERVICE_KEY}`, 'content-type': 'application/json' };
  await fetch(`${API}/auth/v1/admin/users`, { method: 'POST', headers, body: JSON.stringify({ email, email_confirm: true, user_metadata: { full_name: 'Google Person' } }) });
  // A magic link lands on /auth/callback exactly like the Google redirect does (session in the URL).
  const link = await (await fetch(`${API}/auth/v1/admin/generate_link`, {
    method: 'POST', headers, body: JSON.stringify({ type: 'magiclink', email, redirect_to: `${baseURL}/auth/callback` }),
  })).json() as any;
  await page.goto(link.action_link ?? link.properties?.action_link);
  await expect(page).toHaveURL(/\/onboarding/, { timeout: 15000 });
});

test('a failed Google sign-in shows a clear message', async ({ page }) => {
  await page.goto('/auth/callback?error=access_denied&error_description=User+cancelled');
  await expect(page.getByRole('alert')).toContainText(/did not complete/i);
});

test('email sending failure shows a clear message instead of a generic error', async ({ page }) => {
  await page.route('**/auth/v1/signup**', (route) => route.fulfill({
    status: 500, contentType: 'application/json',
    body: JSON.stringify({ code: 500, error_code: 'unexpected_failure', msg: 'Error sending confirmation email' }),
  }));
  await page.goto('/signup');
  await page.getByLabel(/full name/i).fill('Test Person');
  await page.getByLabel(/email/i).fill(`x-${Date.now()}@e2e.bizpilot.local`);
  await page.getByLabel(/^password/i).fill('Password123');
  await page.getByLabel(/^confirm password/i).fill('Password123');
  await page.getByRole('checkbox').check();
  await page.getByRole('button', { name: /create account/i }).click();
  await expect(page.getByRole('alert')).toContainText(/could not send the confirmation email/i);
});

test('phone form fields use 16px text so iPhone Safari does not zoom in', async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 });
  await page.goto('/signup');
  const size = await page.getByLabel(/^password/i).evaluate((el) => getComputedStyle(el).fontSize);
  expect(size).toBe('16px');
  expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(390);
});

test('diagnostics page explains a build without a Google client ID', async ({ page }) => {
  await page.goto('/auth/diagnostics');
  await expect(page.getByTestId('diagnostics')).toContainText('MISSING');
  await expect(page.getByTestId('diagnostics')).toContainText(/VITE_GOOGLE_CLIENT_ID was not set when this deployment was built|Google provider is off/);
});

test('an invalid Google client ID falls back to the redirect flow and says why', async ({ page }) => {
  test.skip(!process.env.INVALID_GIS_BASE_URL, 'set INVALID_GIS_BASE_URL to a server built with an invalid VITE_GOOGLE_CLIENT_ID');
  const base = process.env.INVALID_GIS_BASE_URL!;
  await page.route('**/auth/v1/settings', async (route) => {
    const res = await route.fetch(); const body = await res.json();
    await route.fulfill({ response: res, json: { ...body, external: { ...body.external, google: true } } });
  });
  let gisRequested = false;
  await page.route('https://accounts.google.com/gsi/client', (route) => { gisRequested = true; return route.abort(); });
  await page.goto(`${base}/login`);
  await expect(page.locator('[data-google-mode]')).toHaveAttribute('data-google-mode', 'redirect');
  await expect(page.locator('[data-google-mode]')).toHaveAttribute('data-google-reason', 'invalid');
  await page.goto(`${base}/auth/diagnostics`);
  await expect(page.getByTestId('diagnostics')).toContainText('INVALID (looks_like_secret)');
  expect(gisRequested).toBe(false);
});

test('creators have their own sign-up link: no seller or buyer choice, and it leads to the creator space', async ({ page }) => {
  await page.addInitScript(() => localStorage.setItem('bizpilot.lang', 'en'));
  await page.goto('/login');
  await page.getByRole('link', { name: 'Become a creator' }).click();
  await expect(page).toHaveURL(/\/signup\?for=creator/);
  await expect(page.getByRole('heading', { name: 'Create your creator account' })).toBeVisible();
  await expect(page.getByRole('radiogroup')).toHaveCount(0);
});
