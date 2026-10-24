import { expect, test, type Browser, type Page } from '@playwright/test';
import { randomUUID } from 'node:crypto';
import { passStoreLock } from './storeLockHelper';
import { closeDb, sql } from '../tests/db/helpers';

// BizPilot Market through the real UI: a seller opens a store and lists a product, a guest buys it
// (cash on delivery and online payment through the Fapshi edge function + simulated Fapshi), the
// seller fulfils the orders, the buyer reviews, and an administrator moderates.
// Online payment needs: `supabase functions serve fapshi` with FAPSHI_BASE_URL pointing at
// e2e/fapshiMock.mjs (see docs/MARKETPLACE.md → Testing). It is skipped when the mock is not running.
const id = randomUUID().slice(0, 6);
const seller = { email: `seller-${id}@e2e.bizpilot.local`, password: 'Seller-pass-123!' };
const product = `Kente shirt ${id}`;
let slug = '';
let orderUrl = '';
let orderToken = '';

test.describe.configure({ mode: 'serial' });
test.afterAll(async () => {
  await sql(`update app_config set value = value || '{"online_payments_enabled": false}' where key = 'marketplace'`);
  await closeDb();
});

function watchErrors(page: Page) {
  const errors: string[] = [];
  page.on('pageerror', (e) => errors.push(e.message));
  page.on('console', (m) => { if (m.type() === 'error' && !/Failed to load resource|favicon/.test(m.text())) errors.push(m.text()); });
  return errors;
}

async function sellerLogin(page: Page) {
  await page.addInitScript(() => localStorage.setItem('bizpilot.lang', 'en'));
  await page.goto('/login');
  await page.getByLabel(/^Email address/).fill(seller.email);
  await page.getByLabel(/^Password/).fill(seller.password);
  await page.getByRole('button', { name: 'Log in' }).click();
  await expect(page).toHaveURL(/\/app/);
  await passStoreLock(page);
}

async function guest(browser: Browser) {
  const ctx = await browser.newContext({ viewport: { width: 1280, height: 900 } });
  const page = await ctx.newPage();
  await page.addInitScript(() => localStorage.setItem('bizpilot.lang', 'en'));
  return { ctx, page };
}

test('a seller opens an online store, lists a product and publishes', async ({ page }) => {
  const errors = watchErrors(page);
  await page.addInitScript(() => localStorage.setItem('bizpilot.lang', 'en'));
  await page.goto('/signup');
  await page.getByLabel(/^Your full name/).fill('Awa Seller');
  await page.getByLabel(/^Email address/).fill(seller.email);
  await page.getByLabel(/^Password/).fill(seller.password);
  await page.getByLabel(/^Confirm password/).fill(seller.password);
  await page.getByRole('checkbox').check();
  await page.getByRole('button', { name: 'Create account' }).click();
  await page.getByLabel(/^Business name/).fill(`Awa Mode ${id}`);
  await page.getByLabel('Type of business').selectOption('fashion');
  await page.getByRole('button', { name: 'Create my business' }).click();
  await passStoreLock(page);

  // Grouped navigation shows the online store section.
  const nav = page.getByRole('navigation', { name: 'App' });
  await expect(nav.getByText('Online store')).toBeVisible();
  await nav.getByRole('link', { name: 'My Store' }).click();
  await page.getByRole('button', { name: 'Create my store' }).click();
  await expect(page.getByText('Store setup')).toBeVisible();

  await page.getByRole('tab', { name: 'Contact & hours' }).click();
  await page.getByLabel(/^Phone number/).fill('677112233');
  await page.getByLabel(/^WhatsApp/).fill('677112233');
  await page.getByRole('button', { name: 'Save' }).click();
  await expect(page.getByText('Saved').first()).toBeVisible();

  await page.getByRole('tab', { name: 'Delivery' }).click();
  await page.getByRole('button', { name: 'Add area' }).click();
  await page.getByLabel(/^Area/).fill('Akwa');
  await page.getByLabel(/^Fee/).fill('1000');
  await page.getByLabel(/^Delivery time/).fill('Same day');
  await page.getByText('Customers can pick up at the store').click();
  await page.getByRole('button', { name: 'Save' }).click();
  await expect(page.getByText('Saved').first()).toBeVisible();

  // Publishing is refused until a product is online, with a clear list of what is missing.
  await page.getByRole('button', { name: 'Publish store' }).click();
  await expect(page.getByText('Show at least one product online')).toBeVisible();

  await page.goto('/app/products/new');
  await page.getByLabel(/^Name/).fill(product);
  await page.getByLabel(/^Selling price/).fill('8000');
  await page.getByLabel(/^Quantity on hand/).fill('5');
  await page.getByLabel(/^Cost per/).fill('5000');
  await page.getByRole('button', { name: /Online store/ }).click();
  await page.getByText('Show in my online store').click();
  await page.getByLabel(/^“Was” price/).fill('10000');
  await page.getByRole('button', { name: 'Save' }).first().click();
  await expect(page.getByRole('heading', { name: new RegExp(product) })).toBeVisible();

  await page.goto('/app/products?filter=online');
  await expect(page.getByRole('switch', { name: `Show ${product} online` })).toHaveAttribute('aria-checked', 'true');

  await page.goto('/app/store');
  await page.getByRole('button', { name: 'Publish store' }).click();
  await expect(page.getByText('Your store is live! Share the link.')).toBeVisible();
  await expect(page.getByText('Published', { exact: true })).toBeVisible();
  await expect(page.getByRole('link', { name: 'WhatsApp' })).toHaveAttribute('href', /wa\.me\/\?text=/);
  [{ slug }] = await sql<{ slug: string }>(`select s.slug from stores s join businesses b on b.id = s.business_id join auth.users u on u.id = b.created_by where u.email = $1`, [seller.email]);
  expect(slug).toMatch(/^awa-mode/);
  expect(errors).toEqual([]);
});

test('a guest finds the product, checks out with cash on delivery and can follow the order', async ({ browser }) => {
  const { ctx, page } = await guest(browser);
  const errors = watchErrors(page);
  await page.goto('/market');
  await page.getByRole('searchbox', { name: 'Search products and stores' }).fill(product);
  await page.keyboard.press('Enter');
  await expect(page.getByRole('heading', { name: `Results for “${product}”` })).toBeVisible();
  await page.getByRole('link', { name: new RegExp(product) }).first().click();
  await expect(page.getByRole('heading', { name: product })).toBeVisible();
  await expect(page.getByText('In stock')).toBeVisible();
  await expect(page.getByText(/10.000 FCFA/)).toBeVisible(); // "was" price shown
  await page.getByRole('button', { name: 'Increase' }).click();
  await page.getByRole('button', { name: 'Buy now' }).click();

  await expect(page).toHaveURL(/\/checkout/);
  await page.getByLabel(/^Full name/).fill('Boris Buyer');
  await page.getByLabel(/^Phone number/).fill('699445566');
  await page.getByLabel(/^Delivery area/).selectOption({ index: 1 });
  await page.getByLabel(/^City/).fill('Douala');
  await page.getByLabel(/^Street \/ directions/).fill('Rue Joss, near the bakery');
  await expect(page.getByText(/^17.000 FCFA$/)).toBeVisible(); // 2 × 8 000 + 1 000 delivery, computed by the server
  await page.getByRole('button', { name: 'Place order' }).click();
  await expect(page.getByText(/^Order ORD-\d+ placed$/)).toBeVisible();
  orderUrl = page.url().replace(/\?.*$/, '');
  // The order link with its access token is kept on this device only.
  orderToken = await page.evaluate(() => JSON.parse(localStorage.getItem('bizpilot.orders') ?? '[]')[0]?.token);
  expect(orderToken).toMatch(/^[0-9a-f]{48}$/);
  await expect(page.getByText('Pay on delivery').first()).toBeVisible();

  // Stock is reserved: only 3 can still be ordered.
  const [{ q }] = await sql<{ q: string }>(`select sum(r.quantity) q from stock_reservations r join products p on p.id = r.product_id where p.name = $1 and r.released_at is null`, [product]);
  expect(Number(q)).toBe(2);
  expect(errors).toEqual([]);
  await ctx.close();
});

test('the seller confirms, dispatches and delivers; delivery records a sale and moves stock', async ({ page }) => {
  const errors = watchErrors(page);
  await sellerLogin(page);
  await expect(page.getByText('Online orders')).toBeVisible(); // dashboard card
  await page.getByRole('navigation', { name: 'App' }).getByRole('link', { name: /^Orders/ }).click();
  await page.getByRole('row', { name: /Boris Buyer/ }).click();
  await page.getByRole('button', { name: 'Accept order' }).click();
  await expect(page.getByText('Order accepted')).toBeVisible();
  await page.getByRole('button', { name: 'Mark as sent' }).click();
  await page.getByRole('dialog').getByLabel(/^Message to the customer/).fill('Our rider is on the way');
  await page.getByRole('dialog').getByRole('button', { name: 'Confirm' }).click();
  await page.getByRole('button', { name: 'Mark as delivered' }).click();
  await page.getByRole('dialog').getByLabel(/^How did the customer pay/).selectOption('mtn_momo');
  await page.getByRole('dialog').getByRole('button', { name: 'Confirm' }).click();
  await expect(page.getByText('Order delivered and recorded as a sale')).toBeVisible();
  const [row] = await sql<{ qty: string; sales: string }>(`select p.qty_on_hand qty, (select count(*) from sales s where s.business_id = p.business_id) sales from products p where p.name = $1`, [product]);
  expect(Number(row.qty)).toBe(3);
  expect(Number(row.sales)).toBe(1);
  await page.getByRole('link', { name: 'View the sale' }).click();
  await expect(page).toHaveURL(/\/app\/sales\//);
  expect(errors).toEqual([]);
});

test('the buyer sees the delivery and leaves a verified review', async ({ browser }) => {
  const { ctx, page } = await guest(browser);
  const errors = watchErrors(page);
  // Without the order link (token), the order cannot be opened.
  await page.goto(orderUrl);
  await expect(page.getByRole('heading', { name: 'Order not found', level: 1 })).toBeAttached();
  await page.goto(`${orderUrl}?t=${orderToken}`);
  await expect(page.getByText('Delivered').first()).toBeVisible();
  await expect(page.getByText('Our rider is on the way')).toBeVisible();
  await page.getByRole('radio', { name: '5 stars' }).click();
  await page.getByLabel(/^Your review/).fill('Beautiful shirt, fast delivery');
  await page.getByRole('button', { name: 'Publish review' }).click();
  await expect(page.getByText('Thank you for your review').first()).toBeVisible();
  await page.goto(`/s/${slug}?tab=reviews`);
  await expect(page.getByText('Beautiful shirt, fast delivery')).toBeVisible();
  await expect(page.getByText(/Verified purchase/)).toBeVisible();
  expect(errors).toEqual([]);
  await ctx.close();
});

test('online payment: Fapshi checkout → webhook verified on the server → order paid', async ({ browser }) => {
  const mock = await fetch('http://localhost:4999/__tx').then((r) => r.ok).catch(() => false);
  test.skip(!mock, 'Fapshi mock / edge function not running');
  await sql(`update app_config set value = value || '{"online_payments_enabled": true}' where key = 'marketplace'`);
  await sql(`update stores set online_payment_enabled = true where slug = $1`, [slug]);
  const { ctx, page } = await guest(browser);
  const errors = watchErrors(page);
  await page.goto(`/s/${slug}`);
  await page.getByRole('link', { name: new RegExp(product) }).first().click();
  await page.getByRole('button', { name: 'Add to cart' }).click();
  await page.getByRole('link', { name: /Cart/ }).click();
  await page.getByRole('button', { name: 'Checkout' }).click();
  await page.getByLabel(/^Full name/).fill('Olive Online');
  await page.getByLabel(/^Phone number/).fill('670000000');
  await page.getByRole('radio', { name: /Pick up at the store/ }).click();
  await page.getByRole('radio', { name: /Pay online/ }).click();
  await page.getByRole('button', { name: /Order and pay/ }).click();
  // Simulated Fapshi hosted checkout.
  await expect(page.getByRole('heading', { name: 'Pay 8000 XAF' })).toBeVisible();
  await page.getByRole('button', { name: 'Pay now' }).click();
  // Back on BizPilot: the page asks the server, which asks Fapshi; then shows the order.
  await expect(page).toHaveURL(/\/order\//, { timeout: 30_000 });
  await expect(page.getByText('Paid online')).toBeVisible({ timeout: 30_000 });
  const [o] = await sql<{ payment_status: string; verified: boolean }>(`select o.payment_status, p.verified_at is not null verified from market_orders o join online_payments p on p.order_id = o.id where o.customer_name = 'Olive Online' order by o.created_at desc limit 1`);
  expect(o).toEqual({ payment_status: 'paid', verified: true });
  expect(errors).toEqual([]);
  await ctx.close();
});

test('an administrator verifies the store and can hide a listing', async ({ browser }) => {
  const adminEmail = `admin-${id}@e2e.bizpilot.local`;
  const { ctx, page } = await guest(browser);
  await page.goto('/signup');
  await page.getByLabel(/^Your full name/).fill('Ada Admin');
  await page.getByLabel(/^Email address/).fill(adminEmail);
  await page.getByLabel(/^Password/).fill('Admin-pass-123!');
  await page.getByLabel(/^Confirm password/).fill('Admin-pass-123!');
  await page.getByRole('checkbox').check();
  await page.getByRole('button', { name: 'Create account' }).click();
  await expect(page).toHaveURL(/onboarding/);
  await sql(`insert into platform_admins (user_id) select id from auth.users where email = $1`, [adminEmail]);
  await page.goto('/admin/market');
  await expect(page.getByText('Marketplace rules')).toBeVisible();
  await page.getByRole('link', { name: 'Stores' }).first().click();
  await page.getByRole('row', { name: new RegExp(`Awa Mode ${id}`) }).getByRole('button', { name: 'Manage' }).click();
  await page.getByRole('button', { name: 'Verify store' }).click();
  await expect(page.getByText('Saved').first()).toBeVisible();
  await page.goto('/admin/listings');
  await page.getByRole('row', { name: new RegExp(product) }).getByRole('button', { name: 'Hide' }).click();
  await page.getByLabel(/^Reason/).fill('Test moderation');
  await page.getByRole('dialog').getByRole('button', { name: 'Hide' }).click();
  await expect(page.getByRole('row', { name: new RegExp(product) }).getByText('Hidden by BizPilot')).toBeVisible();
  await page.goto(`/s/${slug}`);
  await expect(page.getByText('Verified').first()).toBeVisible();
  await expect(page.getByText('No products in this category yet.')).toBeVisible();
  await ctx.close();
});
