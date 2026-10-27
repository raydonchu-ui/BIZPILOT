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

  // Buyers pay the seller directly: cash on delivery and the seller's own MTN MoMo number.
  await page.getByRole('tab', { name: 'Payments & policies' }).click();
  await expect(page.getByText('Buyers pay you directly')).toBeVisible();
  await page.getByText('Mobile Money to the seller').click();
  await page.getByLabel(/^Mobile Money number/).first().fill('677 99 88 77');
  await page.getByLabel(/^Name on the account/).first().fill('Awa Mode');
  await page.getByLabel(/^Returns and exchanges policy/).fill('Exchange within 3 days.');
  await page.getByRole('button', { name: 'Save' }).click();
  await expect(page.getByText('Saved').first()).toBeVisible();

  await page.getByRole('tab', { name: 'Delivery' }).click();
  await page.getByRole('button', { name: 'Add area' }).click();
  await page.getByLabel(/^Area/).fill('Akwa');
  await page.getByLabel(/^Fee/).fill('1000');
  await page.getByLabel(/^Delivery time/).fill('Same day');
  // A delivery area says where it delivers: here the whole Littoral region.
  await page.getByLabel('Littoral', { exact: true }).check();
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
  await expect(page.getByText('In stock').first()).toBeVisible();
  await expect(page.getByText(/10.000 XAF/)).toBeVisible(); // "was" price shown
  await page.getByRole('button', { name: 'Increase' }).click();
  await page.getByRole('button', { name: 'Buy now' }).click();

  await expect(page).toHaveURL(/\/checkout/);
  await page.getByLabel(/^Full name/).fill('Boris Buyer');
  await page.getByLabel(/^Phone number/).fill('699445566');
  // Region and town first: the delivery areas offered depend on the location.
  await page.getByLabel(/^Region/).selectOption('littoral');
  await page.getByLabel(/^Town or locality/).fill('Douala');
  await page.getByLabel(/^Delivery area/).selectOption({ index: 1 });
  await page.getByLabel(/^Street \/ directions/).fill('Rue Joss, near the bakery');
  await expect(page.getByText(/^17.000 XAF$/)).toBeVisible(); // 2 × 8 000 + 1 000 delivery, computed by the server
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

const MOCK = 'http://localhost:4999';
async function mockRunning() { return fetch(`${MOCK}/__tx`).then((r) => r.ok).catch(() => false); }
/** The newest direct-pay request the simulated Fapshi received for this phone. */
async function lastPhoneRequest(phone: string) {
  const all = await fetch(`${MOCK}/__tx`).then((r) => r.json()) as Record<string, { phone?: string; amount: number; status: string; medium?: string }>;
  const ids = Object.keys(all).filter((k) => all[k].phone === phone);
  return ids.length ? { id: ids[ids.length - 1], ...all[ids[ids.length - 1]] } : null;
}

test('a buyer pays the seller directly by Mobile Money; only the seller confirms it; the sale is recorded once', async ({ browser }) => {
  const { ctx, page } = await guest(browser);
  const errors = watchErrors(page);
  await page.goto(`/s/${slug}`);
  await page.getByRole('tab', { name: 'About' }).click();
  await expect(page.getByText('Mobile Money to the seller (MTN MoMo)').first()).toBeVisible();
  await expect(page.getByText('Exchange within 3 days.')).toBeVisible();
  await page.getByRole('tab', { name: 'Products' }).click();
  await page.getByRole('link', { name: new RegExp(product) }).first().click();
  // WhatsApp order message carries the product, quantity, price and link.
  const wa = await page.getByRole('link', { name: 'Order on WhatsApp' }).getAttribute('href');
  expect(decodeURIComponent(wa ?? '')).toContain(`1 × ${product}`);
  expect(decodeURIComponent(wa ?? '')).toContain(`/s/${slug}/p/`);
  await page.getByRole('button', { name: 'Add to cart' }).click();
  await page.getByRole('link', { name: /Cart/ }).click();
  await page.getByRole('button', { name: 'Checkout' }).click();
  await page.getByLabel(/^Full name/).fill('Olive Momo');
  await page.getByLabel(/^Phone number/).fill('670000001');
  await page.getByRole('radio', { name: /Pick up at the store/ }).click();
  await expect(page.getByRole('radio', { name: /Pay online/ })).toHaveCount(0);
  await page.getByRole('radio', { name: /Mobile Money to the seller/ }).click();
  await expect(page.getByText(/BizPilot never receives or holds the money/)).toBeVisible();
  await page.getByRole('button', { name: 'Place order' }).click();
  await expect(page).toHaveURL(/\/order\//);
  await expect(page.getByText(/Pay 8,000 XAF to Awa Mode/)).toBeVisible();
  await expect(page.getByText('677998877')).toBeVisible();
  await expect(page.getByText('Name on the account: Awa Mode')).toBeVisible();
  await page.getByLabel(/^Transaction ID/).fill('MP251026.1111');
  await page.getByRole('button', { name: 'I have paid' }).click();
  await expect(page.getByText('Payment reported: waiting for the seller')).toBeVisible();
  await expect(page.getByText('Not paid yet').first()).toBeVisible();
  const orderPath = new URL(page.url()).pathname + new URL(page.url()).search;
  const [ord] = await sql<{ id: string; number: string; payment_status: string }>(`select id, number, payment_status from market_orders where customer_name = 'Olive Momo' order by created_at desc limit 1`);
  expect(ord.payment_status).toBe('cod_pending');

  // The seller checks their own account and confirms, then hands over the goods.
  const sctx = await browser.newContext({ viewport: { width: 1280, height: 900 } });
  const sp = await sctx.newPage();
  const serrors = watchErrors(sp);
  await sellerLogin(sp);
  await sp.goto(`/app/orders/${ord.id}`);
  await expect(sp.getByText('The buyer says they paid (reference MP251026.1111)')).toBeVisible();
  await sp.getByRole('button', { name: 'Payment received' }).click();
  await expect(sp.getByRole('dialog').getByLabel(/^How did the customer pay/)).toHaveValue('mtn_momo');
  await sp.getByRole('button', { name: 'I received the money' }).click();
  await expect(sp.getByText('Payment confirmed').first()).toBeVisible();
  await sp.getByRole('button', { name: 'Accept order' }).click();
  await sp.getByRole('button', { name: 'Collected by customer' }).click();
  await expect(sp.getByText(/You confirmed the payment/).first()).toBeVisible();
  await sp.getByRole('dialog').getByRole('button', { name: 'Confirm', exact: true }).click();
  await expect(sp.getByText(/Delivered on/)).toBeVisible();
  const sales = await sql<{ channel: string; paid_total: string; method: string }>(
    `select s.channel, s.paid_total, p.method from sales s join payments p on p.sale_id = s.id where s.client_ref = $1`, [ord.id]);
  expect(sales).toEqual([{ channel: 'marketplace', paid_total: '8000.00', method: 'mtn_momo' }]);
  expect(serrors).toEqual([]);
  await sctx.close();

  await page.goto(orderPath);
  await expect(page.getByText('Payment confirmed by the seller')).toBeVisible();
  expect(errors).toEqual([]);
  await ctx.close();
});

test('the seller records a WhatsApp sale with a delivery cost, then cancels it', async ({ browser }) => {
  const ctx = await browser.newContext({ viewport: { width: 390, height: 844 } });
  const page = await ctx.newPage();
  const errors = watchErrors(page);
  await sellerLogin(page);
  const [{ qty: before }] = await sql<{ qty: string }>(`select qty_on_hand qty from products where name = $1`, [product]);
  await page.goto('/app');
  await page.getByRole('link', { name: 'Record a sale' }).first().click();
  await page.getByPlaceholder('Search or scan product…').fill(product.slice(0, 12));
  await page.getByRole('button', { name: new RegExp(product) }).first().click();
  await page.getByRole('radio', { name: 'WhatsApp' }).click();
  await page.getByRole('button', { name: 'MTN Mobile Money' }).click();
  await page.getByText('I paid for delivery (courier, moto-taxi…)').click();
  await page.getByLabel(/^Delivery cost/).fill('1000');
  await page.getByRole('button', { name: /Complete sale/ }).click();
  await expect(page.getByRole('heading', { name: 'Sale completed' })).toBeVisible();
  const [sale] = await sql<{ id: string; channel: string }>(`select s.id, s.channel from sales s join sale_lines l on l.sale_id = s.id join products p on p.id = l.product_id
    where p.name = $1 and s.channel = 'whatsapp' order by s.created_at desc limit 1`, [product]);
  expect(sale.channel).toBe('whatsapp');
  expect(await sql(`select category, amount from expenses where sale_id = $1`, [sale.id])).toEqual([{ category: 'delivery', amount: '1000.00' }]);
  expect(Number((await sql<{ qty: string }>(`select qty_on_hand qty from products where name = $1`, [product]))[0].qty)).toBe(Number(before) - 1);

  await page.goto(`/app/sales/${sale.id}`);
  await expect(page.getByText('WhatsApp').first()).toBeVisible();
  await page.getByRole('button', { name: 'Cancel sale' }).click();
  await page.getByRole('dialog').getByLabel(/^Reason/).fill('Customer cancelled on WhatsApp');
  await page.getByRole('dialog').getByRole('button', { name: 'Cancel sale' }).click();
  await expect(page.getByText('Sale cancelled').first()).toBeVisible();
  expect(Number((await sql<{ qty: string }>(`select qty_on_hand qty from products where name = $1`, [product]))[0].qty)).toBe(Number(before));
  const [c] = await sql<{ cancelled: boolean }>(`select cancelled_at is not null cancelled from sales where id = $1`, [sale.id]);
  expect(c.cancelled).toBe(true);
  await page.goto('/app/reports?tab=channels');
  await expect(page.getByRole('row', { name: /WhatsApp/ })).toBeVisible();
  expect(errors).toEqual([]);
  await ctx.close();
});

test('subscription: the owner pays by phone and the plan activates; the admin sees the money', async ({ browser }) => {
  test.skip(!(await mockRunning()), 'Fapshi mock / edge function not running');
  await fetch(`${MOCK}/__direct/on`, { method: 'POST' });
  // Fapshi is for BizPilot subscriptions only.
  await sql(`update app_config set value = value || '{"online_payments_enabled": true}' where key = 'marketplace'`);
  const ctx = await browser.newContext({ viewport: { width: 1280, height: 900 } });
  const page = await ctx.newPage();
  const errors = watchErrors(page);
  await sellerLogin(page);
  await page.goto('/app/billing');
  const card = page.locator('div.relative', { has: page.getByRole('heading', { name: 'Business', exact: true }) });
  await card.getByRole('button', { name: 'Pay for this plan' }).click();
  const dialog = page.getByRole('dialog');
  await dialog.getByLabel(/^Mobile Money number/).fill('670000003');
  await expect(dialog.getByText('MTN Mobile Money number')).toBeVisible();
  await dialog.getByRole('button', { name: /Send payment request/ }).click();
  await expect(dialog.getByText('Approve the payment on your phone')).toBeVisible();
  const req = await lastPhoneRequest('670000003');
  expect(req?.status).toBe('PENDING');
  await fetch(`${MOCK}/__phone/${req!.id}/pay`, { method: 'POST' });
  await expect(page.getByText('Payment confirmed. Your plan is now active.')).toBeVisible({ timeout: 30_000 });
  const [b] = await sql<{ plan_code: string; status: string; method: string; verified: boolean }>(
    `select s.plan_code, s.status, bp.method, bp.status = 'verified' verified from business_subscriptions s join businesses b on b.id = s.business_id
       join auth.users u on u.id = b.created_by join billing_payments bp on bp.business_id = b.id
      where u.email = $1 order by bp.submitted_at desc limit 1`, [seller.email]);
  expect(b).toMatchObject({ plan_code: 'business', status: 'active', method: 'fapshi', verified: true });
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
  // The verified mark is an icon with an accessible name (as in the storefront design), not visible text.
  await expect(page.getByLabel('Verified').first()).toBeVisible();
  await expect(page.getByText('No products in this category yet.')).toBeVisible();
  // Mobile Money: payments confirmed with Fapshi appear on the admin dashboard by themselves.
  await page.goto('/admin');
  await expect(page.getByText('Mobile Money today')).toBeVisible();
  if (await mockRunning()) {
    await page.goto('/admin/fapshi');
    await expect(page.getByRole('heading', { name: 'Mobile Money' })).toBeVisible();
    await expect(page.getByRole('row', { name: /Subscription business/ }).first()).toContainText(`Awa Mode ${id}`);
    // Marketplace orders are paid to sellers directly, so only subscription payments appear here.
    // Balance read on the server from the (simulated) Fapshi account.
    await expect(page.getByText('Live from your Fapshi account')).toBeVisible();
    // The last direct-pay answer from Fapshi (accepted in the last test) is shown to the admin.
    await expect(page.getByText(/Phone requests \(live\): working/)).toBeVisible();
  }
  await ctx.close();
});
