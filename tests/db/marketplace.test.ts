import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { randomBytes } from 'node:crypto';
import {
  addProduct, addStaff, admin, anon, closeDb, createBusiness, createUser, expectError, n, openStock, product, rpc, sell, sql, uid,
  type TestUser,
} from './helpers';

const token = () => randomBytes(24).toString('hex');
const guest = anon();

async function setupStore(owner: TestUser, name: string, extra: Record<string, unknown> = {}) {
  const biz = await createBusiness(owner, name, { category: 'fashion' });
  await rpc(owner.client, 'store_save', { p_business: biz, p: { name, phone: '677000111', whatsapp: '677000111', city: 'Douala', pickup_enabled: true, ...extra } });
  await rpc(owner.client, 'store_save_zones', { p_business: biz, p_zones: [{ name: 'Akwa', fee: 1000, eta: 'Same day' }, { name: 'Bonamoussadi', fee: 1500 }] });
  return biz;
}

async function listedProduct(owner: TestUser, biz: string, fields: Record<string, unknown> = {}, qty = 5) {
  const p = await addProduct(owner, biz, { selling_price: 5000, purchase_cost: 3000, ...fields });
  if (qty > 0) await openStock(owner, biz, p.id, qty, 3000);
  await rpc(owner.client, 'products_set_online', { p_business: biz, p_ids: [p.id], p_online: true });
  return p;
}

const order = (items: { product_id: string; quantity: number }[], extra: Record<string, unknown> = {}) => ({
  client_ref: uid(), access_token: token(), items, delivery_method: 'pickup', payment_method: 'cod',
  customer: { name: 'Awa Buyer', phone: `69${Math.floor(1e6 + Math.random() * 8.9e6)}`, email: 'awa@example.com' }, ...extra,
});

async function setConfig(patch: Record<string, unknown>) {
  await sql(`update app_config set value = value || $1::jsonb where key = 'marketplace'`, [JSON.stringify(patch)]);
}

describe('marketplace: stores, listings, checkout, stock and payments', () => {
  let owner: TestUser; let biz: string; let zones: any[]; let tee: any; let zoneAkwa: string;
  beforeAll(async () => {
    await sql(`delete from rate_limits where key like 'order_%' or key like 'pay_begin:%' or key like 'report_ip:%'`);
    await setConfig({ online_payments_enabled: false, commission_pct: 0, online_fee_pct: 0 });
    owner = await createUser('mk-owner');
    biz = await setupStore(owner, 'Mode Akwa');
    zones = await sql('select id, name, fee from store_delivery_zones where business_id = $1 order by sort', [biz]);
    zoneAkwa = zones[0].id;
    tee = await listedProduct(owner, biz, { name: 'Red T-shirt', brand: 'Kmer', description: 'Cotton tee' });
    await rpc(owner.client, 'store_set_published', { p_business: biz, p_publish: true });
  });
  afterAll(async () => {
    await setConfig({ online_payments_enabled: false, commission_pct: 0, online_fee_pct: 0 });
    await closeDb();
  });

  it('creates a store with a unique slug; publishing needs a profile, a listing, a payment method and delivery', async () => {
    const u = await createUser('mk-ready');
    const b = await createBusiness(u, 'Électro Plus');
    const st = await rpc(u.client, 'store_save', { p_business: b, p: { phone: '+237677000222' } });
    expect(st.slug).toMatch(/^lectro-plus|^electro-plus/);
    await expectError(rpc(u.client, 'store_save', { p_business: b, p: { slug: 'admin' } }), 'slug_unavailable');
    const mine = await sql('select slug from stores where business_id = $1', [biz]);
    await expectError(rpc(u.client, 'store_save', { p_business: b, p: { slug: mine[0].slug } }), 'slug_unavailable');
    const e = await expectError(rpc(u.client, 'store_set_published', { p_business: b, p_publish: true }), 'store_not_ready');
    expect(JSON.parse(e.details).products).toBe(false);
    // Another business cannot edit this store.
    await expectError(rpc(owner.client, 'store_save', { p_business: b, p: { name: 'Hijack' } }), 'permission_denied');
  });

  it('shows published listings to anonymous visitors without costs, stock values or customer data', async () => {
    const slug = (await sql('select slug from stores where business_id = $1', [biz]))[0].slug;
    const store = await rpc(guest, 'market_store', { p_slug: slug });
    expect(store.name).toBe('Mode Akwa');
    expect(store.zones.map((z: any) => z.name)).toEqual(['Akwa', 'Bonamoussadi']);
    expect(store.phone).toBeNull(); // show_phone is off by default
    expect(store.whatsapp).toBe('+237677000111');
    const res = await rpc(guest, 'market_search', { p: { q: 'red t-shirt' } });
    const hit = res.items.find((i: any) => i.id === tee.id);
    expect(hit).toBeTruthy();
    expect(n(hit.price)).toBe(5000);
    expect(n(hit.available)).toBe(5);
    const text = JSON.stringify(await rpc(guest, 'market_product', { p_id: tee.id }));
    for (const secret of ['purchase_cost', 'avg_cost', 'stock_value', 'qty_on_hand', '3000']) expect(text).not.toContain(secret);
    // Direct table access stays closed to the public.
    const direct = await guest.from('products').select('id').eq('id', tee.id);
    expect(direct.data ?? []).toHaveLength(0);
    const orders = await guest.from('market_orders').select('id');
    expect(orders.data ?? []).toHaveLength(0);
    // An unlisted product is not public.
    const hidden = await addProduct(owner, biz, { name: 'Unlisted thing' });
    expect(await rpc(guest, 'market_product', { p_id: hidden.id })).toBeNull();
  });

  it('prices the cart on the server: delivery zone fee, promotion, minimum order; one seller per order', async () => {
    await rpc(owner.client, 'promo_save', { p_business: biz, p: { code: 'tabaski10', kind: 'percent', value: 10, min_order: 5000 } });
    const q = await rpc(guest, 'market_quote', { p: { items: [{ product_id: tee.id, quantity: 2, unit_price: 1 }], delivery_method: 'delivery', zone_id: zoneAkwa, promo_code: 'TABASKI10' } });
    expect(q.errors).toEqual([]);
    expect(n(q.subtotal)).toBe(10000); // the client price is ignored
    expect(n(q.discount)).toBe(1000);
    expect(n(q.delivery_fee)).toBe(1000);
    expect(n(q.total)).toBe(10000);
    const bad = await rpc(guest, 'market_quote', { p: { items: [{ product_id: tee.id, quantity: 9 }], delivery_method: 'delivery' } });
    expect(bad.errors.map((e: any) => e.code).sort()).toEqual(['insufficient_stock', 'zone_required']);

    const other = await createUser('mk-other');
    const ob = await setupStore(other, 'Other Shop');
    const op = await listedProduct(other, ob);
    await rpc(other.client, 'store_set_published', { p_business: ob, p_publish: true });
    await expectError(rpc(guest, 'market_quote', { p: { items: [{ product_id: tee.id, quantity: 1 }, { product_id: op.id, quantity: 1 }] } }), 'one_seller_per_order');
  });

  it('a cash-on-delivery order reserves stock: no overselling online or at the counter', async () => {
    const p = await listedProduct(owner, biz, { name: 'Last jacket' }, 2);
    const tk = token();
    const buyer = { name: 'Awa Buyer', phone: '699112233', email: 'awa@example.com' };
    const o = await rpc(guest, 'market_place_order', { p: { ...order([{ product_id: p.id, quantity: 2 }], { customer: buyer }), access_token: tk } });
    expect(o.payment_status).toBe('cod_pending');
    // Retrying the same request does not create a second order.
    const again = await rpc(guest, 'market_place_order', { p: { ...order([{ product_id: p.id, quantity: 2 }], { customer: buyer }), access_token: tk, client_ref: (await sql('select client_ref from market_orders where id = $1', [o.order_id]))[0].client_ref } });
    expect(again.duplicate).toBe(true);
    const card = (await rpc(guest, 'market_product', { p_id: p.id }));
    expect(n(card.available)).toBe(0);
    const e = await expectError(rpc(guest, 'market_place_order', { p: order([{ product_id: p.id, quantity: 1 }]) }), 'checkout_invalid');
    expect(e.details).toContain('insufficient_stock');
    // The shop cannot sell reserved stock at the counter either.
    await expectError(sell(owner, biz, [{ product_id: p.id, quantity: 1 }], { payments: [{ method: 'cash', amount: 5000 }] }), 'insufficient_stock');
    // The seller's customer list gets the buyer.
    const cust = await sql(`select source from customers where business_id = $1 and phone = '+237699112233'`, [biz]);
    expect(cust[0].source).toBe('online');
    // The customer cancels: stock is free again.
    await rpc(guest, 'market_order_customer_action', { p_order: o.order_id, p_token: tk, p_action: 'cancel', p_text: 'Changed my mind' });
    expect(n((await rpc(guest, 'market_product', { p_id: p.id })).available)).toBe(2);
    await sell(owner, biz, [{ product_id: p.id, quantity: 1 }], { payments: [{ method: 'cash', amount: 5000 }] });
  });

  it('concurrent orders for the last item: exactly one succeeds', async () => {
    const p = await listedProduct(owner, biz, { name: 'Unique bag' }, 1);
    const results = await Promise.allSettled([1, 2, 3, 4].map(() => rpc(anon(), 'market_place_order', { p: order([{ product_id: p.id, quantity: 1 }], { customer: { name: 'Racer', phone: `6991${Math.floor(Math.random() * 1e5).toString().padStart(5, '0')}` } }) })));
    expect(results.filter((r) => r.status === 'fulfilled')).toHaveLength(1);
    const [{ q }] = await sql(`select coalesce(sum(quantity), 0) q from stock_reservations where product_id = $1 and released_at is null`, [p.id]);
    expect(n(q)).toBe(1);
  });

  it('order tracking needs the access token or the buyer account; other sellers see nothing', async () => {
    const tk = token();
    const o = await rpc(guest, 'market_place_order', { p: { ...order([{ product_id: tee.id, quantity: 1 }], { delivery_method: 'delivery', zone_id: zoneAkwa, address: { region: 'littoral', city: 'Douala', area: 'Akwa', line: 'Rue Joss' } }), access_token: tk } });
    const view = await rpc(guest, 'market_order_view', { p_order: o.order_id, p_token: tk });
    expect(view.number).toMatch(/^ORD-/);
    expect(n(view.total)).toBe(6000);
    await expectError(rpc(guest, 'market_order_view', { p_order: o.order_id, p_token: token() }), 'not_found');
    const other = await createUser('mk-snoop');
    await createBusiness(other, 'Snoop Shop');
    const peek = await other.client.from('market_orders').select('id').eq('id', o.order_id);
    expect(peek.data ?? []).toHaveLength(0);
    await expectError(rpc(other.client, 'market_order_action', { p_order: o.order_id, p_action: 'confirm' }), 'permission_denied');
  });

  it('confirm → dispatch → deliver (COD) creates a normal sale, moves stock and records the cash', async () => {
    const p = await listedProduct(owner, biz, { name: 'Blue jeans', selling_price: 8000 }, 3);
    const tk = token();
    const o = await rpc(guest, 'market_place_order', { p: { ...order([{ product_id: p.id, quantity: 2 }], { delivery_method: 'delivery', zone_id: zoneAkwa, address: { region: 'littoral', city: 'Douala', line: 'Akwa' } }), access_token: tk } });
    await expectError(rpc(owner.client, 'market_order_action', { p_order: o.order_id, p_action: 'deliver', p: {} }), 'invalid_order_status');
    await rpc(owner.client, 'market_order_action', { p_order: o.order_id, p_action: 'confirm' });
    await rpc(owner.client, 'market_order_action', { p_order: o.order_id, p_action: 'dispatch', p: { message: 'Rider on the way' } });
    await expectError(rpc(owner.client, 'market_order_action', { p_order: o.order_id, p_action: 'deliver', p: {} }), 'payment_method_required');
    const done = await rpc(owner.client, 'market_order_action', { p_order: o.order_id, p_action: 'deliver', p: { cod_method: 'cash', received_by: 'Awa' } });
    expect(done.status).toBe('delivered');
    expect(done.payment_status).toBe('cod_collected');
    const pr = await product(owner, p.id);
    expect(n(pr.qty_on_hand)).toBe(1);
    const [sale] = await sql('select total, cost_total, paid_total from sales where id = $1', [done.sale_id]);
    expect(n(sale.total)).toBe(16000);
    expect(n(sale.paid_total)).toBe(16000);
    expect(n(sale.cost_total)).toBe(6000);
    const [fee] = await sql(`select amount from cash_movements where business_id = $1 and note = $2`, [biz, `Delivery fee ${done.number}`]);
    expect(n(fee.amount)).toBe(1000);
    const [res] = await sql('select count(*)::int n from stock_reservations where order_id = $1 and consumed_at is not null', [o.order_id]);
    expect(res.n).toBe(1);
    // Customer sees the timeline, and can review only delivered products, once.
    const view = await rpc(guest, 'market_order_view', { p_order: o.order_id, p_token: tk });
    expect(view.events.map((e: any) => e.status).filter(Boolean)).toEqual(['pending', 'confirmed', 'dispatched', 'delivered']);
    await rpc(guest, 'market_submit_review', { p_order: o.order_id, p_token: tk, p_product: p.id, p_rating: 5, p_comment: 'Great fit' });
    await expectError(rpc(guest, 'market_submit_review', { p_order: o.order_id, p_token: tk, p_product: p.id, p_rating: 4 }), 'already_reviewed');
    const card = await rpc(guest, 'market_product', { p_id: p.id });
    expect(card.reviews[0].comment).toBe('Great fit');
    // Refund after delivery: stock comes back through a sale return.
    await rpc(owner.client, 'market_order_action', { p_order: o.order_id, p_action: 'refund', p: { reason: 'Wrong size', restock: true } });
    expect(n((await product(owner, p.id)).qty_on_hand)).toBe(3);
    const [ord] = await sql('select status, payment_status from market_orders where id = $1', [o.order_id]);
    expect(ord).toEqual({ status: 'refunded', payment_status: 'refunded' });
  });

  it('a review is refused before delivery; cashiers can handle orders but not manage the store', async () => {
    const tk = token();
    const o = await rpc(guest, 'market_place_order', { p: { ...order([{ product_id: tee.id, quantity: 1 }]), access_token: tk } });
    await expectError(rpc(guest, 'market_submit_review', { p_order: o.order_id, p_token: tk, p_product: tee.id, p_rating: 5 }), 'review_requires_delivery');
    const cashier = await addStaff(owner, biz, 'cashier');
    await rpc(cashier.client, 'market_order_action', { p_order: o.order_id, p_action: 'confirm' });
    await expectError(rpc(cashier.client, 'store_save', { p_business: biz, p: { tagline: 'x' } }), 'permission_denied');
    await rpc(cashier.client, 'market_order_action', { p_order: o.order_id, p_action: 'reject', p: { reason: 'Out of this colour' } });
    const [ord] = await sql('select status, cancelled_by, payment_status from market_orders where id = $1', [o.order_id]);
    expect(ord).toEqual({ status: 'cancelled', cancelled_by: 'seller', payment_status: 'void' });
  });

  it('unconfirmed / unpaid orders expire and release their stock', async () => {
    const p = await listedProduct(owner, biz, { name: 'Sandals' }, 1);
    const o = await rpc(guest, 'market_place_order', { p: order([{ product_id: p.id, quantity: 1 }], { customer: { name: 'Late Buyer', phone: '699000777' } }) });
    expect(n((await rpc(guest, 'market_product', { p_id: p.id })).available)).toBe(0);
    await sql(`update market_orders set expires_at = now() - interval '1 minute' where id = $1`, [o.order_id]);
    await sql(`update stock_reservations set expires_at = now() - interval '1 minute' where order_id = $1`, [o.order_id]);
    expect(n((await rpc(guest, 'market_product', { p_id: p.id })).available)).toBe(1);
    await rpc(owner.client, 'seller_market_summary', { p_business: biz });
    const [ord] = await sql('select status, cancel_reason from market_orders where id = $1', [o.order_id]);
    expect(ord).toEqual({ status: 'cancelled', cancel_reason: 'not_confirmed_in_time' });
  });

  it('buyers pay the seller directly: no BizPilot online payment; Mobile Money to the seller is seller-confirmed', async () => {
    // Fapshi is for subscriptions only: an order can never be paid through BizPilot.
    await expectError(rpc(guest, 'market_place_order', { p: order([{ product_id: tee.id, quantity: 1 }], { payment_method: 'online' }) }), 'invalid_payment_method');
    await sql('update stores set online_payment_enabled = true where business_id = $1', [biz]);
    expect((await sql('select online_payment_enabled from stores where business_id = $1', [biz]))[0].online_payment_enabled).toBe(false);
    // Mobile Money to the seller needs the seller's own number.
    await expectError(rpc(guest, 'market_place_order', { p: order([{ product_id: tee.id, quantity: 1 }], { payment_method: 'momo_direct' }) }), 'payment_method_not_available');
    await expectError(rpc(owner.client, 'store_save_payments', { p_business: biz, p: { momo_direct_enabled: true } }), 'momo_number_required');
    await expectError(rpc(owner.client, 'store_save_payments', { p_business: biz, p: { momo_direct_enabled: true, momo_mtn_number: '12345' } }), 'invalid_phone');
    const staffCashier = await addStaff(owner, biz, 'cashier');
    await expectError(rpc(staffCashier.client, 'store_save_payments', { p_business: biz, p: { momo_direct_enabled: false } }), 'permission_denied');
    await rpc(owner.client, 'store_save_payments', { p_business: biz, p: { momo_direct_enabled: true, momo_mtn_number: '+237 677 12 34 56',
      momo_mtn_name: 'Awa Mode', return_policy: 'Exchange within 3 days with receipt.', neighborhood: 'Akwa' } });
    const store = await rpc(guest, 'market_store', { p_slug: (await sql('select slug from stores where business_id = $1', [biz]))[0].slug });
    expect(store).toMatchObject({ momo_direct_enabled: true, momo_networks: ['mtn'], online_payment_enabled: false,
      return_policy: 'Exchange within 3 days with receipt.', neighborhood: 'Akwa' });
    expect(JSON.stringify(store)).not.toContain('677123456'); // the number is shown to buyers on their order

    const p = await listedProduct(owner, biz, { name: 'Wax dress', selling_price: 12000 }, 2);
    const tk = token();
    const o = await rpc(guest, 'market_place_order', { p: { ...order([{ product_id: p.id, quantity: 1 }], { payment_method: 'momo_direct' }), access_token: tk } });
    expect(o.payment_status).toBe('cod_pending');
    let view = await rpc(guest, 'market_order_view', { p_order: o.order_id, p_token: tk });
    expect(view.store.momo).toMatchObject({ mtn_number: '677123456', mtn_name: 'Awa Mode', orange_number: null });
    expect(view).toMatchObject({ can_pay: false, can_report_payment: true });
    // The buyer reports the transfer: evidence only, the order stays unpaid.
    await expectError(rpc(guest, 'market_order_report_payment', { p_order: o.order_id, p_token: token(), p_reference: 'MP2410.1234' }), 'not_found');
    await rpc(guest, 'market_order_report_payment', { p_order: o.order_id, p_token: tk, p_reference: 'MP2410.1234' });
    let [row] = await sql('select payment_status, buyer_payment_ref from market_orders where id = $1', [o.order_id]);
    expect(row).toEqual({ payment_status: 'cod_pending', buyer_payment_ref: 'MP2410.1234' });
    // Only the seller can confirm the money arrived.
    await expectError(rpc(guest, 'market_order_action', { p_order: o.order_id, p_action: 'payment_received', p: { method: 'mtn_momo' } }), /not_found|permission.denied/);
    await expectError(rpc(owner.client, 'market_order_action', { p_order: o.order_id, p_action: 'payment_received', p: {} }), 'payment_method_required');
    await rpc(owner.client, 'market_order_action', { p_order: o.order_id, p_action: 'payment_received', p: { method: 'mtn_momo' } });
    [row] = await sql('select payment_status, payment_reference, payment_confirmed_by from market_orders where id = $1', [o.order_id]);
    expect(row).toEqual({ payment_status: 'seller_confirmed', payment_reference: 'MP2410.1234', payment_confirmed_by: owner.id });
    // Once the seller has the money, the buyer cannot cancel on their own.
    await expectError(rpc(guest, 'market_order_customer_action', { p_order: o.order_id, p_token: tk, p_action: 'cancel' }), 'order_not_cancellable');
    view = await rpc(guest, 'market_order_view', { p_order: o.order_id, p_token: tk });
    expect(view).toMatchObject({ payment_status: 'seller_confirmed', paid_with: 'mtn_momo', can_report_payment: false, can_cancel: false });
    // Delivery records exactly one sale (channel: marketplace) paid by MTN MoMo, and moves stock once.
    await rpc(owner.client, 'market_order_action', { p_order: o.order_id, p_action: 'confirm' });
    const done = await rpc(owner.client, 'market_order_action', { p_order: o.order_id, p_action: 'deliver', p: {} });
    expect(done.payment_status).toBe('cod_collected');
    const sales = await sql('select id, channel, total, paid_total from sales where client_ref = $1', [o.order_id]);
    expect(sales).toHaveLength(1);
    expect(sales[0]).toMatchObject({ channel: 'marketplace' });
    expect(n(sales[0].paid_total)).toBe(12000);
    const pays = await sql(`select method, amount from payments where sale_id = $1`, [sales[0].id]);
    expect(pays.map((x: any) => [x.method, n(x.amount)])).toEqual([['mtn_momo', 12000]]);
    expect(n((await product(owner, p.id)).qty_on_hand)).toBe(1);
    await expectError(rpc(owner.client, 'market_order_action', { p_order: o.order_id, p_action: 'deliver', p: {} }), 'invalid_order_status');
    expect(await sql('select 1 from sales where client_ref = $1', [o.order_id])).toHaveLength(1);
    // No BizPilot balance is created for the seller.
    expect(await sql(`select 1 from market_ledger where order_id = $1 and kind = 'order_payment'`, [o.order_id])).toEqual([]);
    // A marketplace sale is refunded from its order, not cancelled as a shop sale.
    await expectError(rpc(owner.client, 'cancel_sale', { p_sale: sales[0].id, p_reason: 'x' }), 'use_order_refund');

    // Cancelling after the seller confirmed a payment: the seller records the refund they sent.
    const tk2 = token();
    const o2 = await rpc(guest, 'market_place_order', { p: { ...order([{ product_id: p.id, quantity: 1 }], { payment_method: 'momo_direct' }), access_token: tk2 } });
    await rpc(owner.client, 'market_order_action', { p_order: o2.order_id, p_action: 'payment_received', p: { method: 'mtn_momo', reference: 'MP-77' } });
    await rpc(owner.client, 'market_order_action', { p_order: o2.order_id, p_action: 'reject', p: { reason: 'Out of this colour' } });
    [row] = await sql('select status, payment_status from market_orders where id = $1', [o2.order_id]);
    expect(row).toEqual({ status: 'cancelled', payment_status: 'refund_pending' });
    await rpc(owner.client, 'market_order_action', { p_order: o2.order_id, p_action: 'refunded', p: { reference: 'MP-REFUND-1' } });
    [row] = await sql('select payment_status, refund_reference from market_orders where id = $1', [o2.order_id]);
    expect(row).toEqual({ payment_status: 'refunded', refund_reference: 'MP-REFUND-1' });
    expect(n((await product(owner, p.id)).qty_on_hand)).toBe(1); // the reservation was released, stock untouched
  });

  it('subscriptions can be paid with Fapshi and activate only after verification', async () => {
    await setConfig({ online_payments_enabled: true });
    const pay = await rpc(owner.client, 'billing_fapshi_begin', { p_business: biz, p_plan: 'starter', p_period: 'monthly' });
    expect(n(pay.amount)).toBe(1500);
    const t = `T${uid().slice(0, 8)}`;
    await rpc(admin, 'fapshi_attach', { p_payment: pay.payment_id, p_trans_id: t, p_link: 'https://x' });
    await rpc(admin, 'fapshi_apply', { p_trans_id: t, p_tx: { status: 'SUCCESSFUL', amount: 1500, externalId: pay.payment_id } });
    const [sub] = await sql('select plan_code, status, current_period_end > now() + interval \'27 days\' ok from business_subscriptions where business_id = $1', [biz]);
    expect(sub).toEqual({ plan_code: 'starter', status: 'active', ok: true });
    const [bp] = await sql(`select status, method from billing_payments where business_id = $1 and transaction_ref = $2`, [biz, t]);
    expect(bp).toEqual({ status: 'verified', method: 'fapshi' });
  });

  it('plan limits: free plans list up to 20 products; above the limit after expiry, the newest listings are hidden', async () => {
    const u = await createUser('mk-free');
    const b = await setupStore(u, 'Free Shop');
    await sql(`update business_subscriptions set plan_code = 'free', status = 'active', trial_ends_at = null where business_id = $1`, [b]);
    const ids: string[] = [];
    for (let i = 0; i < 20; i++) ids.push((await addProduct(u, b, { name: `Item ${i}` })).id);
    expect(await rpc(u.client, 'products_set_online', { p_business: b, p_ids: ids, p_online: true })).toBe(20);
    const extra = await addProduct(u, b, { name: 'Item 21' });
    await expectError(rpc(u.client, 'products_set_online', { p_business: b, p_ids: [extra.id], p_online: true }), 'plan_limit_reached');
    await rpc(u.client, 'store_set_published', { p_business: b, p_publish: true });
    // Simulate a lower limit (e.g. an administrator changed the plan): only the oldest stay visible.
    await sql(`update plans set limits = limits || '{"max_online_products": 5}' where code = 'free'`);
    try {
      const slug = (await sql('select slug from stores where business_id = $1', [b]))[0].slug;
      const res = await rpc(guest, 'market_search', { p: { store: slug, page_size: 60 } });
      expect(res.total).toBe(5);
    } finally {
      await sql(`update plans set limits = limits || '{"max_online_products": 20}' where code = 'free'`);
    }
  });

  it('administration: hide a listing, suspend a store, record a payout; reports and blocked contacts', async () => {
    const adm = await createUser('mk-admin2');
    await sql('insert into platform_admins (user_id) values ($1)', [adm.id]);
    await expectError(rpc(owner.client, 'admin_market_overview'), 'permission_denied');
    const p = await listedProduct(owner, biz, { name: 'Fake watch' });
    const rid = await rpc(guest, 'market_report', { p: { target_type: 'product', target_id: p.id, reason: 'counterfeit', contact: 'x@y.cm' } });
    expect(rid).toBeTruthy();
    const reports = await rpc(adm.client, 'admin_market_reports', { p_status: 'open' });
    expect(reports.some((r: any) => r.id === rid && r.target_name === 'Fake watch')).toBe(true);
    await rpc(adm.client, 'admin_market_hide_product', { p_product: p.id, p_hidden: true, p_reason: 'Counterfeit' });
    expect(await rpc(guest, 'market_product', { p_id: p.id })).toBeNull();
    // The seller cannot unhide it.
    const { error } = await owner.client.from('products').update({ admin_hidden: false }).eq('id', p.id);
    expect(error?.message).toContain('protected_field');
    await rpc(adm.client, 'admin_market_report_update', { p_report: rid, p_status: 'resolved', p_resolution: 'Listing removed' });

    const before = n((await rpc(owner.client, 'seller_payments_summary', { p_business: biz })).balance);
    await rpc(adm.client, 'admin_market_record_payout', { p_business: biz, p_amount: 1000, p_method: 'mtn_momo', p_reference: 'MP-77' });
    expect(n((await rpc(owner.client, 'seller_payments_summary', { p_business: biz })).balance)).toBe(before - 1000);

    await rpc(adm.client, 'admin_market_block', { p_kind: 'phone', p_value: '699000999', p_reason: 'Fake orders' });
    await expectError(rpc(guest, 'market_place_order', { p: order([{ product_id: tee.id, quantity: 1 }], { customer: { name: 'Faker', phone: '+237 699 000 999' } }) }), 'checkout_blocked');

    const slug = (await sql('select slug from stores where business_id = $1', [biz]))[0].slug;
    await rpc(adm.client, 'admin_market_store_update', { p_business: biz, p: { status: 'suspended', reason: 'Investigation' } });
    expect((await rpc(guest, 'market_store', { p_slug: slug })).unavailable).toBe(true);
    await expectError(rpc(owner.client, 'store_set_published', { p_business: biz, p_publish: true }), 'store_suspended');
    await rpc(adm.client, 'admin_market_store_update', { p_business: biz, p: { status: 'published', verification: 'verified' } });
    expect((await rpc(guest, 'market_store', { p_slug: slug })).verified).toBe(true);
  });

  it('fraud controls: one phone number cannot flood a store with orders', async () => {
    const p = await listedProduct(owner, biz, { name: 'Socks', selling_price: 500 }, 50);
    const customer = { name: 'Flood', phone: '699880011' };
    // At most 3 open cash-on-delivery orders per phone and store…
    for (let i = 0; i < 3; i++) await rpc(guest, 'market_place_order', { p: order([{ product_id: p.id, quantity: 1 }], { customer }) });
    await expectError(rpc(guest, 'market_place_order', { p: order([{ product_id: p.id, quantity: 1 }], { customer }) }), 'too_many_open_orders');
    // …and at most 10 placed orders per phone per hour (refused attempts are not counted).
    await setConfig({ max_open_cod_per_phone: 50 });
    try {
      for (let i = 0; i < 7; i++) await rpc(guest, 'market_place_order', { p: order([{ product_id: p.id, quantity: 1 }], { customer }) });
      await expectError(rpc(guest, 'market_place_order', { p: order([{ product_id: p.id, quantity: 1 }], { customer }) }), 'rate_limited');
    } finally { await setConfig({ max_open_cod_per_phone: 3 }); }
  });

  it('signed-in customers: saved addresses, order history, favourites; guest orders can be claimed', async () => {
    const buyer = await createUser('mk-buyer');
    const o = await rpc(buyer.client, 'market_place_order', { p: { ...order([{ product_id: tee.id, quantity: 1 }], { delivery_method: 'delivery', zone_id: zoneAkwa, address: { region: 'littoral', city: 'Douala', line: 'Bonapriso' }, save_address: true, customer: { name: 'Buyer One', phone: '699123123' } }), access_token: undefined } });
    const mine = await rpc(buyer.client, 'market_my_orders');
    expect(mine.map((x: any) => x.id)).toContain(o.order_id);
    const { data: addrs } = await buyer.client.from('customer_addresses').select('*');
    expect(addrs?.[0]).toMatchObject({ city: 'Douala', line: 'Bonapriso', is_default: true, phone: '+237699123123' });
    const { error: favErr } = await buyer.client.from('market_favorites').insert({ product_id: tee.id });
    expect(favErr).toBeNull();
    const hidden = await addProduct(owner, biz, { name: 'Not listed' });
    const { error: favBad } = await buyer.client.from('market_favorites').insert({ product_id: hidden.id });
    expect(favBad).not.toBeNull();
    // A guest order placed earlier on this device can be attached to the account.
    const tk = token();
    const g = await rpc(guest, 'market_place_order', { p: { ...order([{ product_id: tee.id, quantity: 1 }], { customer: { name: 'Buyer One', phone: '699123124' } }), access_token: tk } });
    expect(await rpc(buyer.client, 'market_claim_orders', { p_orders: [{ id: g.order_id, token: tk }, { id: o.order_id, token: 'nope' }] })).toBe(1);
    // Sellers cannot buy from their own store.
    await expectError(rpc(owner.client, 'market_place_order', { p: order([{ product_id: tee.id, quantity: 1 }]) }), 'cannot_order_from_own_store');
  });
});
