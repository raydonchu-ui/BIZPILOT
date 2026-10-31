import { expect, test, type Page } from '@playwright/test';
import { randomUUID } from 'node:crypto';
import { passStoreLock } from './storeLockHelper';
import { startBusinessTrial } from './trialHelper';

// Full business workflow through the real UI, backend and database:
// register -> business -> supplier -> product (carton unit) -> purchase & receive ->
// sale -> stock updated -> profit on dashboard -> analytics -> advisor -> persistence.
const id = randomUUID().slice(0, 6);
const email = `owner-${id}@e2e.bizpilot.local`;
const password = 'E2e-password-123!';
const shop = `Boutique E2E ${id}`;

test.describe.configure({ mode: 'serial' });

async function setEnglish(page: Page) {
  await page.addInitScript(() => localStorage.setItem('bizpilot.lang', 'en'));
}

test('register, create business and see the setup checklist', async ({ page }) => {
  await setEnglish(page);
  await page.goto('/');
  await expect(page.getByRole('heading', { level: 1 })).toContainText('Know your stock');
  await page.getByRole('link', { name: 'Start Managing Your Store' }).first().click();
  await page.getByLabel(/^Your full name/).fill('Jean Dupont');
  await page.getByLabel(/^Email address/).fill(email);
  await page.getByLabel(/^Password/).fill(password);
  await page.getByLabel(/^Confirm password/).fill(password);
  await page.getByRole('checkbox').check();
  await page.getByRole('button', { name: 'Create account' }).click();
  await expect(page.getByRole('heading', { name: 'Set up your business' })).toBeVisible();
  await page.getByLabel(/^Business name/).fill(shop);
  await page.getByLabel('Type of business').selectOption('grocery');
  await page.getByLabel('City').fill('Douala');
  await page.getByRole('button', { name: 'Create my business' }).click();
  await passStoreLock(page); // first access to the dashboard: create the Store Lock PIN
  await startBusinessTrial(email); // the later steps use paid features; a new account starts on Free
  await expect(page.getByRole('heading', { name: 'Getting started' })).toBeVisible();
  await expect(page.getByText(/of \d+ steps completed/)).toBeVisible();
});

async function login(page: Page) {
  await setEnglish(page);
  await page.goto('/login');
  await page.getByLabel(/^Email address/).fill(email);
  await page.getByLabel(/^Password/).fill(password);
  await page.getByRole('button', { name: 'Log in' }).click();
  await expect(page).toHaveURL(/\/app/);
  await passStoreLock(page); // a new sign-in starts locked
}

test('add supplier and product with carton unit', async ({ page }) => {
  await login(page);
  await page.goto('/app/suppliers?new=1');
  await page.getByLabel(/^Name/).fill('Grossiste Akwa');
  await page.getByLabel('Payment terms').fill('15');
  await page.getByRole('button', { name: 'Save' }).click();
  await expect(page.getByRole('heading', { name: 'Grossiste Akwa' })).toBeVisible();

  await page.goto('/app/products/new');
  await page.getByLabel(/^Name/).fill('Coca Cola 50cl');
  await page.getByRole('button', { name: /Product identifiers/ }).click();
  await page.getByLabel('Stock Keeping Unit (SKU)').fill(`COKE-${id}`);
  await page.getByLabel('Base unit').fill('bottle');
  await page.getByLabel(/^Selling price( \*)?$/).fill('500');
  await page.getByLabel('Minimum stock (bottle)').fill('24');
  await page.getByRole('button', { name: /More settings/ }).click();
  await page.getByRole('button', { name: 'Add unit' }).click();
  await page.getByLabel('Unit name').fill('carton');
  await page.getByLabel('Contains (in bottle)').fill('24');
  await page.getByLabel('Selling price for this unit').fill('11000');
  await page.getByRole('button', { name: 'Save' }).first().click();
  await expect(page.getByRole('heading', { name: /Coca Cola 50cl/ })).toBeVisible();
  await expect(page.getByText('1 carton = 24 bottle')).toBeVisible();
});

test('record a wholesale purchase with transport and receive it', async ({ page }) => {
  await login(page);
  await page.goto('/app/purchases/new');
  await page.getByLabel(/^Supplier/).selectOption({ label: 'Grossiste Akwa' });
  await page.getByLabel('Invoice no.').fill('INV-001');
  await page.getByPlaceholder('Add a product…').fill('Coca');
  await page.getByRole('button', { name: /Coca Cola 50cl/ }).click();
  // carton is the default purchase unit (first unit added)
  await page.getByLabel('Qty').fill('5');
  await page.getByLabel('Cost per carton').fill('7200');
  await page.getByLabel('Transport costs').fill('2400');
  await expect(page.getByText('38 400 FCFA').or(page.getByText('38,400 FCFA')).first()).toBeVisible();
  await page.getByRole('button', { name: 'Save as received' }).click();
  await expect(page.getByText('Received', { exact: true }).first()).toBeVisible();
  // 5 cartons x 24 = 120 bottles; landed cost (36,000 + 2,400) / 120 = 320 per bottle
  await expect(page.getByText(/320 FCFA\/bottle/)).toBeVisible();
  await expect(page.getByText('38,400 FCFA').first()).toBeVisible();

  await page.goto('/app/inventory');
  const row = page.getByRole('row', { name: /Coca Cola 50cl/ });
  await expect(row).toContainText('120 bottle');
  await expect(row).toContainText('38,400 FCFA');
});

test('record a sale and see stock deducted', async ({ page }) => {
  await login(page);
  await page.goto('/app/sales/new');
  await page.getByPlaceholder('Search or scan product…').fill('Coca');
  await page.getByRole('button', { name: /Coca Cola 50cl/ }).click();
  await page.getByRole('textbox', { name: 'Qty' }).fill('10');
  await expect(page.getByRole('button', { name: /Complete sale · 5,000 FCFA/ })).toBeVisible();
  await page.getByRole('button', { name: 'MTN Mobile Money' }).click();
  await page.getByRole('button', { name: /Complete sale/ }).click();
  await expect(page.getByRole('heading', { name: 'Sale completed' })).toBeVisible();

  await page.goto('/app/inventory');
  await expect(page.getByRole('row', { name: /Coca Cola 50cl/ })).toContainText('110 bottle');
});

test('dashboard shows real sales, cost-based profit and alerts; reports and advisor work', async ({ page }) => {
  await login(page);
  await page.goto('/app');
  await expect(page.getByText('Good', { exact: false }).first()).toBeVisible();
  // net sales 5,000; COGS 10 x 320 = 3,200 => gross profit 1,800
  const card = (label: string) => page.locator('section', { hasText: label }).first();
  await expect(card('Total Sales')).toContainText('5,000 FCFA');
  await expect(card('Gross Profit')).toContainText('1,800 FCFA');
  await expect(card('Total Purchases')).toContainText('38,400 FCFA');
  await expect(card('Inventory Value')).toContainText('35,200 FCFA');
  await expect(page.getByRole('heading', { name: 'Top Selling Products' })).toBeVisible();

  await page.goto('/app/reports?tab=pl');
  await expect(page.getByRole('row', { name: /Gross profit/ })).toContainText('1,800 FCFA');

  await page.goto('/app/advisor');
  await page.getByRole('button', { name: 'Which products are selling fastest?' }).click();
  await expect(page.getByText(/Coca Cola 50cl: 10 sold/)).toBeVisible();
  // No AI key is configured locally: the answer must be labelled as calculated from records
  await expect(page.getByText(/calculated directly from your records/)).toBeVisible();
  await expect(page.getByText('Calculated from your records').first()).toBeVisible();
});

test('records persist after logout and login', async ({ page }) => {
  await login(page);
  await page.getByRole('button', { name: /Jean Dupont/ }).click();
  await page.getByRole('button', { name: 'Log out' }).click();
  await expect(page).toHaveURL(/\/login/);
  await login(page);
  await page.goto('/app/sales');
  await expect(page.getByRole('row', { name: /S-00001/ })).toContainText('5,000 FCFA');
  await page.goto('/app/purchases');
  await expect(page.getByRole('row', { name: /PO-00001/ })).toContainText('Received');
});
