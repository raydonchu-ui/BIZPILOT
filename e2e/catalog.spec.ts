import { expect, test, type Page } from '@playwright/test';
import { randomUUID } from 'node:crypto';
import { passStoreLock } from './storeLockHelper';
import { closeDb, sql } from '../tests/db/helpers';

// Flexible catalogue through the real UI: business-type categories at onboarding, quick product
// entry with only the required fields, generated SKU, category-specific details, variants,
// barcode check and category management.
const id = randomUUID().slice(0, 6);
const email = `catalog-${id}@e2e.bizpilot.local`;
const password = 'Catalog-pass-123!';

test.describe.configure({ mode: 'serial' });
test.afterAll(closeDb);

async function login(page: Page) {
  await page.addInitScript(() => localStorage.setItem('bizpilot.lang', 'en'));
  await page.goto('/login');
  await page.getByLabel(/^Email address/).fill(email);
  await page.getByLabel(/^Password/).fill(password);
  await page.getByRole('button', { name: 'Log in' }).click();
  await expect(page).toHaveURL(/\/app/);
  await passStoreLock(page);
}

test('onboarding suggests categories for the business type; the owner keeps only what they sell', async ({ page }) => {
  await page.addInitScript(() => localStorage.setItem('bizpilot.lang', 'en'));
  await page.goto('/signup');
  await page.getByLabel(/^Your full name/).fill('Grace Boutique');
  await page.getByLabel(/^Email address/).fill(email);
  await page.getByLabel(/^Password/).fill(password);
  await page.getByLabel(/^Confirm password/).fill(password);
  await page.getByRole('checkbox').check();
  await page.getByRole('button', { name: 'Create account' }).click();
  await page.getByLabel(/^Business name/).fill(`Grace Mode ${id}`);
  await page.getByLabel('Type of business').selectOption('fashion');
  await expect(page.getByRole('checkbox', { name: 'Men', exact: true })).toBeChecked();
  await expect(page.getByRole('checkbox', { name: 'Cargo pants' }).first()).toBeChecked();
  await page.getByRole('checkbox', { name: 'Workwear', exact: true }).uncheck();
  await page.getByRole('checkbox', { name: 'Traditional clothing', exact: true }).uncheck();
  await page.getByRole('button', { name: 'Create my business' }).click();
  await passStoreLock(page);
  await expect(page.getByRole('heading', { name: 'Getting started' })).toBeVisible();

  const [{ biz }] = await sql<{ biz: string }>(`select b.id biz from businesses b join auth.users u on u.id = b.created_by where u.email = $1`, [email]);
  const tops = await sql<{ name: string }>(`select name from categories where business_id = $1 and parent_id is null order by sort_order`, [biz]);
  expect(tops.map((r) => r.name)).toEqual(['Men', 'Women', 'Kids', 'Baby', 'Unisex', 'Sportswear', 'Footwear', 'Accessories']);
  const [{ n }] = await sql<{ n: number }>(`select count(*)::int n from categories c join categories p on p.id = c.parent_id where c.business_id = $1 and p.name = 'Men'`, [biz]);
  expect(n).toBeGreaterThan(10);
});

test('a product can be saved with only a name and price; a stable SKU is created', async ({ page }) => {
  await login(page);
  await page.goto('/app/products/new');
  await expect(page.getByRole('button', { name: /Product identifiers/ })).toHaveAttribute('aria-expanded', 'false');
  await page.getByLabel(/^Name/).fill('Plain white tee');
  await page.getByLabel(/^Selling price/).fill('3500');
  await page.getByRole('button', { name: 'Save' }).first().click();
  await expect(page.getByRole('heading', { name: /Plain white tee/ })).toBeVisible();
  const mine = `(select b.id from businesses b join auth.users u on u.id = b.created_by where u.email = $1)`;
  const [p] = await sql(`select sku, barcode, category_id, attributes from products where name = 'Plain white tee' and business_id = ${mine}`, [email]);
  expect(p.sku).toMatch(/^SKU-\d{5}$/);
  expect(p.barcode).toBeNull();
  expect(p.category_id).toBeNull();
  expect(p.attributes).toEqual({});
  await expect(page.getByText(p.sku).first()).toBeVisible();

  // Editing without touching the SKU keeps it.
  await page.getByRole('link', { name: 'Edit' }).click();
  await page.getByLabel(/^Name/).fill('Plain white tee (cotton)');
  await page.getByRole('button', { name: 'Save' }).first().click();
  await expect(page.getByRole('heading', { name: /cotton/ })).toBeVisible();
  const [q] = await sql(`select sku from products where name = 'Plain white tee (cotton)' and business_id = ${mine}`, [email]);
  expect(q.sku).toBe(p.sku);
});

test('clothing details, subcategory, barcode check and size × colour variants', async ({ page }) => {
  await login(page);
  await page.goto('/app/products/new');
  await page.getByLabel(/^Name/).fill('Slim jeans');
  await page.getByLabel(/^Selling price/).fill('12000');
  await page.getByLabel(/^Category/).selectOption({ label: 'Men' });
  await page.getByLabel(/^Subcategory/).fill('Jeans');
  await page.getByLabel(/^Purchase cost/).fill('7000');

  await page.getByRole('button', { name: /Product identifiers/ }).click();
  await page.getByLabel(/^Barcode/).fill('4006381333932');
  await expect(page.getByText(/last digit does not match/)).toBeVisible();
  await page.getByLabel(/^Barcode/).fill('4006381333931');
  await expect(page.getByText(/last digit does not match/)).toHaveCount(0);

  await page.getByRole('button', { name: /Additional details/ }).click();
  await expect(page.getByLabel(/^Gender \/ age group/)).toBeVisible(); // clothing fields for a clothing category
  await page.getByLabel(/^Material/).fill('Denim');

  await page.getByRole('button', { name: /^Variants/ }).click();
  await page.getByRole('checkbox', { name: 'Create variants' }).check();
  await page.getByLabel('Option name').first().fill('Size');
  await page.getByLabel(/Values/).first().fill('30, 32');
  await page.getByRole('button', { name: 'Add another option' }).click();
  await page.getByLabel('Option name').nth(1).fill('Colour');
  await page.getByLabel(/Values/).nth(1).fill('Blue, Black');
  await expect(page.getByText('4 variant(s) will be created')).toBeVisible();
  await page.getByLabel('Price 32 / Black').fill('13000');
  await page.getByLabel('Opening stock 30 / Blue').fill('5');
  await page.getByLabel('Opening stock 32 / Black').fill('2');
  await page.getByRole('button', { name: 'Save' }).first().click();
  await expect(page.getByRole('heading', { name: /Slim jeans/ })).toBeVisible();
  await expect(page.getByRole('link', { name: '32 / Black' })).toBeVisible();
  await expect(page.getByTestId('product-attributes')).toContainText('Denim');

  const rows = await sql(`select v.variant_label, v.selling_price, v.qty_on_hand, v.avg_cost, v.attributes, v.subcategory from products v join products p on p.id = v.variant_of
    where p.name = 'Slim jeans' and p.business_id = (select b.id from businesses b join auth.users u on u.id = b.created_by where u.email = $1)
    order by v.variant_label`, [email]);
  expect(rows.map((r) => [r.variant_label, Number(r.selling_price), Number(r.qty_on_hand)])).toEqual([
    ['30 / Black', 12000, 0], ['30 / Blue', 12000, 5], ['32 / Black', 13000, 2], ['32 / Blue', 12000, 0]]);
  expect(Number(rows[1].avg_cost)).toBe(7000);
  expect(rows[2].attributes).toMatchObject({ size: '32', color: 'Black', material: 'Denim' });
  expect(rows[0].subcategory).toBe('Jeans');

  // Filter the list by subcategory.
  await page.goto('/app/products');
  await page.getByLabel('Category', { exact: true }).selectOption({ label: 'Men' });
  await page.getByLabel(/^Subcategory/).selectOption('Jeans');
  await expect(page.getByRole('row', { name: /Slim jeans — 32 \/ Black/ })).toBeVisible();
  await expect(page.getByRole('row', { name: /Plain white tee/ })).toHaveCount(0);
});

test('owners add, rename, reorder, archive and restore categories', async ({ page }) => {
  await login(page);
  await page.goto('/app/products/categories');
  await page.getByRole('button', { name: 'Add category', exact: true }).click();
  await page.getByLabel('Category name').fill('Second-hand');
  await page.getByRole('button', { name: 'Add', exact: true }).click();
  await expect(page.getByTestId('category-Second-hand')).toBeVisible();

  await page.getByRole('button', { name: 'Rename Second-hand' }).click();
  await page.getByRole('textbox', { name: 'Rename', exact: true }).fill('Thrift');
  await page.getByRole('button', { name: 'Save' }).click();
  await expect(page.getByTestId('category-Thrift')).toBeVisible();

  // Renaming a subcategory updates the products that use it.
  await page.getByRole('button', { name: 'Rename Jeans' }).first().click();
  await page.getByRole('textbox', { name: 'Rename', exact: true }).fill('Denim jeans');
  await page.getByRole('button', { name: 'Save' }).click();
  await expect(page.getByTestId('category-Denim jeans')).toBeVisible();
  await expect.poll(async () => (await sql(`select count(*)::int n from products p join businesses b on b.id = p.business_id join auth.users u on u.id = b.created_by
    where u.email = $1 and p.subcategory = 'Denim jeans'`, [email]))[0].n).toBe(5); // parent + 4 variants

  const order = async () => (await sql<{ name: string }>(`select c.name from categories c join businesses b on b.id = c.business_id join auth.users u on u.id = b.created_by
    where u.email = $1 and c.parent_id is null order by c.sort_order`, [email])).map((r) => r.name);
  await page.getByTestId('category-Men').getByRole('button', { name: 'Move down' }).click();
  await expect.poll(async () => (await order()).slice(0, 2)).toEqual(['Women', 'Men']);

  await page.getByRole('button', { name: 'Archive Thrift' }).click();
  await expect(page.getByTestId('category-Thrift')).toHaveCount(0);
  await page.goto('/app/products/new');
  await expect(page.getByLabel(/^Category/).locator('option', { hasText: 'Thrift' })).toHaveCount(0);
  await page.goto('/app/products/categories');
  await page.getByRole('checkbox', { name: 'Show archived' }).check();
  await page.getByTestId('category-Thrift').getByRole('button', { name: 'Restore' }).click();
  await page.getByRole('checkbox', { name: 'Show archived' }).uncheck();
  await expect(page.getByTestId('category-Thrift')).toBeVisible();

  // Suggestions from another business type can be added later.
  await page.getByLabel('Suggestions for').selectOption('jewelry');
  await page.getByRole('checkbox', { name: 'Rings', exact: true }).check();
  await page.getByRole('button', { name: 'Add selected' }).click();
  await expect(page.getByTestId('category-Rings')).toBeVisible();
});
