import { expect, test } from '@playwright/test';
import { randomUUID } from 'node:crypto';
import { passStoreLock } from './storeLockHelper';
import { addCustomer, addProduct, addSupplier, closeDb, createBusiness, createUser, rpc, sell, sql, uid } from '../tests/db/helpers';

// Visits every route with realistic data and fails on any runtime or console error.
const SHOTS = process.env.SHOT_DIR;
const routes = ['/app', '/app/setup', '/app/products', '/app/products/new', '/app/products/categories', '/app/inventory', '/app/inventory?tab=movements', '/app/inventory?tab=expiry',
  '/app/inventory/counts', '/app/import', '/app/purchases', '/app/purchases/new', '/app/suppliers', '/app/customers', '/app/sales', '/app/sales/new',
  '/app/expenses', '/app/cash', '/app/reports', '/app/reports?tab=sales', '/app/reports?tab=products', '/app/reports?tab=categories', '/app/reports?tab=valuation',
  '/app/reports?tab=restock', '/app/reports?tab=slow', '/app/reports?tab=aging', '/app/reports?tab=suppliers', '/app/reports?tab=customers',
  '/app/reports?tab=discrepancies', '/app/reports?tab=efficiency', '/app/reports?tab=payments', '/app/advisor', '/app/staff', '/app/settings',
  '/app/settings?tab=operations', '/app/settings?tab=receipts', '/app/settings?tab=data', '/app/settings?tab=audit', '/app/billing', '/app/profile',
  '/app/notifications', '/app/help', '/app/more', '/admin', '/admin/businesses', '/admin/payments', '/admin/plans', '/admin/config',
  '/admin/announcements', '/admin/support', '/admin/ai', '/admin/audit',
  '/app/store', '/app/store?tab=contact', '/app/store?tab=delivery', '/app/store?tab=payments', '/app/store?tab=appearance', '/app/store?tab=reviews',
  '/app/orders', '/app/orders?f=all', '/app/payments', '/app/promotions', '/admin/market', '/admin/stores', '/admin/listings', '/admin/reports',
  '/admin/orders', '/admin/settlements', '/market', '/market/search?q=Smoke', '/cart', '/account',
  '/', '/features', '/how-it-works', '/inventory-management', '/business-analytics', '/ai-advisor', '/pricing', '/about', '/faq', '/contact', '/privacy', '/terms', '/billing-policy'];

test('every page renders without errors', async ({ page }) => {
  test.setTimeout(300_000);
  const u = await createUser('smoke');
  await sql('select app.bootstrap_platform_admin($1)', [u.email]);
  const biz = await createBusiness(u, 'Smoke Test Store');
  const sup = await addSupplier(u, biz, { name: 'Smoke Supplier' });
  const p = await addProduct(u, biz, { name: 'Smoke Product', selling_price: 1000, min_stock: 50 });
  await rpc(u.client, 'save_purchase', { p_business: biz, p: { supplier_id: sup.id, status: 'ordered', receive_now: true, lines: [{ product_id: p.id, quantity: 60, unit_cost: 600 }] } });
  const c = await addCustomer(u, biz, { name: 'Smoke Customer' });
  await sell(u, biz, [{ product_id: p.id, quantity: 12 }], { customer_id: c.id, payments: [{ method: 'cash', amount: 5000 }], due_date: '2026-01-01' });
  await rpc(u.client, 'record_expense', { p_business: biz, p: { category: 'rent', description: 'Rent', amount: 3000, paid_amount: 3000, method: 'cash', client_ref: uid() } });
  await rpc(u.client, 'submit_billing_payment', { p_business: biz, p: { plan_code: 'business', billing_period: 'monthly', method: 'mtn_momo', transaction_ref: `SMOKE-${randomUUID().slice(0, 8)}` } });
  await rpc(u.client, 'submit_support_request', { p: { subject: 'Smoke question', message: 'Testing support flow' } });
  // Marketplace: a published store with one listing and one order.
  await rpc(u.client, 'store_save', { p_business: biz, p: { name: 'Smoke Store', phone: '677000999', pickup_enabled: true } });
  await rpc(u.client, 'products_set_online', { p_business: biz, p_ids: [p.id], p_online: true });
  await rpc(u.client, 'store_set_published', { p_business: biz, p_publish: true });
  const [{ slug }] = await sql<{ slug: string }>('select slug from stores where business_id = $1', [biz]);
  const buyer = await createUser('smoke-buyer');
  const o = await rpc(buyer.client, 'market_place_order', { p: { client_ref: uid(), items: [{ product_id: p.id, quantity: 1 }], delivery_method: 'pickup',
    payment_method: 'cod', customer: { name: 'Smoke Buyer', phone: `69${Math.floor(1e6 + Math.random() * 8.9e6)}` } } });
  routes.push(`/s/${slug}`, `/s/${slug}?tab=about`, `/s/${slug}?tab=reviews`, `/s/${slug}/p/${p.id}`, `/app/orders/${o.order_id}`);
  await closeDb();

  const errors: string[] = [];
  page.on('pageerror', (e) => errors.push(`pageerror: ${e.message}`));
  page.on('console', (m) => { if (m.type() === 'error' && !/favicon|Failed to load resource.*404|ERR_INTERNET|functions\/v1/.test(m.text())) errors.push(`console: ${m.text()}`); });
  await page.addInitScript(() => localStorage.setItem('bizpilot.lang', 'en'));
  await page.goto('/login');
  await page.getByLabel(/^Email address/).fill(u.email);
  await page.getByLabel(/^Password/).fill('Test-password-123!');
  await page.getByRole('button', { name: 'Log in' }).click();
  await expect(page).toHaveURL(/\/app/);
  await passStoreLock(page);

  for (const r of routes) {
    const before = errors.length;
    await page.goto(r);
    await page.waitForLoadState('networkidle');
    await expect(page.locator('h1').first(), `heading on ${r}`).toBeVisible();
    await expect(page.getByText('An unexpected error occurred'), `error on ${r}`).toHaveCount(0);
    if (!r.includes('audit')) await expect(page.getByText(/^\w+\.\w+(\.\w+)*$/).filter({ hasText: /^(nav|common|errors|reports|dashboard|products|insights|admin|billing|market|seller|orders|madmin|navGroups)\./ }), `untranslated key on ${r}`).toHaveCount(0);
    if (SHOTS) await page.screenshot({ path: `${SHOTS}/${r.replace(/[/?=&]+/g, '_') || 'home'}.png`, fullPage: true });
    if (errors.length > before) console.log(r, errors.slice(before));
  }
  expect(errors).toEqual([]);
});
