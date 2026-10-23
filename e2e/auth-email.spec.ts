import { test, expect, type Page } from '@playwright/test';

// Password reset through the real email: needs the local stack's Mailpit (http://127.0.0.1:54324).
const MAILPIT = process.env.MAILPIT_URL ?? 'http://127.0.0.1:54324';
const API = process.env.SUPABASE_URL ?? 'http://127.0.0.1:54321';
const SERVICE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY
  ?? 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImV4cCI6MTk4MzgxMjk5Nn0.EGIM96RAZx35lJzdJsyH-qQwv8Hdp7fsn3W0YpN81IU'; // local demo key

async function latestLink(email: string, subjectPart: string): Promise<{ html: string; link: string }> {
  for (let i = 0; i < 20; i++) {
    const list = await (await fetch(`${MAILPIT}/api/v1/search?query=${encodeURIComponent(`to:${email}`)}`)).json() as any;
    const m = list.messages?.find((x: any) => x.Subject.includes(subjectPart));
    if (m) {
      const full = await (await fetch(`${MAILPIT}/api/v1/message/${m.ID}`)).json() as any;
      const link = (full.HTML.match(/href="([^"]*\/auth\/v1\/verify[^"]*)"/)?.[1] ?? '').replace(/&amp;/g, '&');
      return { html: full.HTML, link };
    }
    await new Promise((r) => setTimeout(r, 500));
  }
  throw new Error(`no email for ${email}`);
}

async function login(page: Page, email: string, password: string) {
  await page.goto('/login');
  await page.getByLabel(/email/i).fill(email);
  await page.getByLabel(/^password/i).fill(password);
  await page.getByRole('button', { name: /^log in$/i }).click();
}

test('forgot password: branded email, reset link, new password works', async ({ page }) => {
  const email = `reset-${Date.now()}@e2e.bizpilot.local`;
  const created = await fetch(`${API}/auth/v1/admin/users`, {
    method: 'POST', headers: { apikey: SERVICE_KEY, Authorization: `Bearer ${SERVICE_KEY}`, 'content-type': 'application/json' },
    body: JSON.stringify({ email, password: 'OldPassword1', email_confirm: true }),
  });
  expect(created.ok).toBeTruthy();

  await page.goto('/forgot-password');
  await page.getByLabel(/email/i).fill(email);
  await page.getByRole('button', { name: /send reset link/i }).click();
  await expect(page.getByText(/a reset link has been sent/i)).toBeVisible();

  const { html, link } = await latestLink(email, 'Reset your BizPilot password');
  expect(html).toContain('Réinitialisez votre mot de passe');
  expect(html).toContain(email);
  expect(link).toContain('type=recovery');
  if (process.env.SHOT_DIR) {
    await page.setContent(html);
    await page.screenshot({ path: `${process.env.SHOT_DIR}/email_recovery.png`, fullPage: true });
  }

  await page.goto(link);
  await expect(page).toHaveURL(/reset-password/);
  await page.getByLabel(/^new password/i).fill('NewPassword2');
  await page.getByLabel(/^confirm password/i).fill('NewPassword2');
  await page.getByRole('button', { name: /update password/i }).click();
  await expect(page).toHaveURL(/\/(app|onboarding)/);

  await page.context().clearCookies();
  await page.evaluate(() => localStorage.clear());
  await login(page, email, 'OldPassword1');
  await expect(page.getByRole('alert')).toBeVisible();
  await login(page, email, 'NewPassword2');
  await expect(page).toHaveURL(/\/(app|onboarding)/);
});
