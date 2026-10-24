import { expect, test } from '@playwright/test';
import { randomUUID } from 'node:crypto';
import { closeDb, sql } from '../tests/db/helpers';

// The app must keep working on a database that has not run the October 2026 upgrade yet
// (deploy-before-SQL safety). Run with LEGACY_DB=1 against such a database.
test.skip(!process.env.LEGACY_DB, 'set LEGACY_DB=1 and use a database without migrations 20261024*');
test.afterAll(closeDb);

test('previous database: onboarding with a new business type, quick product, no PIN screen', async ({ page }) => {
  const email = `legacy-${randomUUID().slice(0, 6)}@e2e.bizpilot.local`;
  await page.addInitScript(() => localStorage.setItem('bizpilot.lang', 'en'));
  await page.goto('/signup');
  await page.getByLabel(/^Your full name/).fill('Legacy Owner');
  await page.getByLabel(/^Email address/).fill(email);
  await page.getByLabel(/^Password/).fill('Legacy-pass-123!');
  await page.getByLabel(/^Confirm password/).fill('Legacy-pass-123!');
  await page.getByRole('checkbox').check();
  await page.getByRole('button', { name: 'Create account' }).click();
  await page.getByLabel(/^Business name/).fill('Legacy Hair');
  await page.getByLabel('Type of business').selectOption('hair_beauty');
  await page.getByRole('button', { name: 'Create my business' }).click();
  await expect(page.getByRole('heading', { name: 'Getting started' })).toBeVisible(); // no Store Lock without the upgrade
  const [b] = await sql(`select b.category from businesses b join auth.users u on u.id = b.created_by where u.email = $1`, [email]);
  expect(b.category).toBe('cosmetics');

  await page.goto('/app/products/new');
  await page.getByLabel(/^Name/).fill('Edge control gel');
  await page.getByLabel(/^Category/).selectOption({ index: 1 });
  await page.getByLabel(/^Selling price/).fill('1500');
  await page.getByRole('button', { name: 'Save' }).first().click();
  await expect(page.getByRole('heading', { name: /Edge control gel/ })).toBeVisible();
  const [p] = await sql(`select sku from products where name = 'Edge control gel' and business_id = (select b.id from businesses b join auth.users u on u.id = b.created_by where u.email = $1)`, [email]);
  expect(p.sku).toMatch(/^SKU-/);

  await page.goto('/app/products');
  await expect(page.getByRole('row', { name: /Edge control gel/ })).toBeVisible();
  await page.goto('/app/products/categories');
  await expect(page.getByText(/database upgrade/)).toBeVisible();
});
