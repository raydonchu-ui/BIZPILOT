// Recording every sale (including WhatsApp, Facebook, phone and walk-in sales), sale-specific costs,
// cancellations, partial returns, the channel report, one-of-a-kind listings and business alerts.
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import {
  addCustomer, addProduct, addStaff, anon, closeDb, createBusiness, createUser, expectError, n, openStock, product, rpc,
  sell, sql, TestUser, uid,
} from './helpers';

const today = () => new Date(Date.now() + 3600_000).toISOString().slice(0, 10); // Africa/Douala (UTC+1)
const recordSale = (u: TestUser, biz: string, p: Record<string, unknown>) => rpc<any>(u.client, 'record_sale', { p_business: biz, p: { client_ref: uid(), ...p } });

describe('recording every sale: channels, costs, cancellations, reports and alerts', () => {
  let u: TestUser; let biz: string; let bag: any; let noCost: any;

  beforeAll(async () => {
    u = await createUser('rec');
    biz = await createBusiness(u, 'Records Shop', { category: 'fashion' });
    bag = await addProduct(u, biz, { name: 'Leather bag', selling_price: 10000, purchase_cost: 6000 });
    await openStock(u, biz, bag.id, 20, 6000);
    noCost = await addProduct(u, biz, { name: 'Bracelet', selling_price: 2000 });
    await openStock(u, biz, noCost.id, 10, 0);
  });
  afterAll(closeDb);

  it('a WhatsApp sale paid by MTN MoMo deducts stock exactly once, even when submitted repeatedly', async () => {
    const ref = uid();
    const body = { client_ref: ref, channel: 'whatsapp', lines: [{ product_id: bag.id, quantity: 2 }],
      payments: [{ method: 'mtn_momo', amount: 20000, reference: 'MP-WA-1' }] };
    const results = await Promise.all([1, 2, 3].map(() => rpc<any>(u.client, 'record_sale', { p_business: biz, p: body })));
    expect(new Set(results.map((r) => r.id)).size).toBe(1);
    expect(results.filter((r) => !r.duplicate)).toHaveLength(1);
    expect(n((await product(u, bag.id)).qty_on_hand)).toBe(18);
    const [s] = await sql('select channel, total, paid_total from sales where id = $1', [results[0].id]);
    expect(s).toMatchObject({ channel: 'whatsapp' });
    expect(n(s.paid_total)).toBe(20000);
    // Shop sales made the old way default to "in person".
    const walk = await sell(u, biz, [{ product_id: bag.id, quantity: 1 }], { payments: [{ method: 'cash', amount: 10000 }] });
    expect((await sql('select channel from sales where id = $1', [walk.id]))[0].channel).toBe('in_person');
    // The marketplace channel is only for delivered marketplace orders.
    await expectError(recordSale(u, biz, { channel: 'marketplace', lines: [{ product_id: bag.id, quantity: 1 }] }), 'invalid_channel');
    await expectError(recordSale(u, biz, { channel: 'tv', lines: [{ product_id: bag.id, quantity: 1 }] }), 'invalid_channel');
  });

  it('a delivery cost paid by the seller is recorded once as a linked, paid delivery expense', async () => {
    const ref = uid();
    const p = { client_ref: ref, channel: 'facebook', delivery_cost: 1500, delivery_cost_method: 'orange_money',
      lines: [{ product_id: bag.id, quantity: 1 }], payments: [{ method: 'orange_money', amount: 10000 }] };
    const r = await rpc<any>(u.client, 'record_sale', { p_business: biz, p });
    await rpc(u.client, 'record_sale', { p_business: biz, p }); // retried submission
    const ex = await sql('select category, amount, status, sale_id from expenses where sale_id = $1', [r.id]);
    expect(ex).toHaveLength(1);
    expect(ex[0]).toMatchObject({ category: 'delivery', status: 'paid', sale_id: r.id });
    expect(n(ex[0].amount)).toBe(1500);
    const pl = await rpc<any>(u.client, 'profit_and_loss', { p_business: biz, p_from: today(), p_to: today() });
    expect(pl.expenses_by_category.find((e: any) => e.category === 'delivery')).toMatchObject({ entries: 1 });
    await expectError(recordSale(u, biz, { delivery_cost: -5, lines: [{ product_id: bag.id, quantity: 1 }] }), 'invalid_amount');
  });

  it('a phone sale on credit tracks the outstanding balance; partial payment later reduces it', async () => {
    const c = await addCustomer(u, biz, { name: 'Mama Ngono', phone: '699112233' });
    const r = await recordSale(u, biz, { channel: 'phone', customer_id: c.id, due_date: today(),
      lines: [{ product_id: bag.id, quantity: 1 }], payments: [{ method: 'cash', amount: 4000 }] });
    let [s] = await sql('select total, paid_total from sales where id = $1', [r.id]);
    expect(n(s.total) - n(s.paid_total)).toBe(6000);
    await rpc(u.client, 'record_customer_payment', { p_business: biz, p_customer: c.id, p_amount: 2500, p_method: 'mtn_momo', p_sale: r.id });
    [s] = await sql('select paid_total from sales where id = $1', [r.id]);
    expect(n(s.paid_total)).toBe(6500);
    const ch = await rpc<any[]>(u.client, 'sales_by_channel', { p_business: biz, p_from: today(), p_to: today() });
    const phone = ch.find((x) => x.channel === 'phone');
    expect(n(phone.revenue)).toBe(10000);
    expect(n(phone.paid)).toBe(6500);
    expect(n(phone.outstanding)).toBe(3500);
  });

  it('cancelling a sale returns the stock, refunds what was paid and keeps the original sale', async () => {
    const before = n((await product(u, bag.id)).qty_on_hand);
    const r = await recordSale(u, biz, { channel: 'in_person', lines: [{ product_id: bag.id, quantity: 2 }], payments: [{ method: 'cash', amount: 20000 }] });
    expect(n((await product(u, bag.id)).qty_on_hand)).toBe(before - 2);
    const cashier = await addStaff(u, biz, 'cashier');
    await expectError(rpc(cashier.client, 'cancel_sale', { p_sale: r.id, p_reason: 'Customer changed mind' }), 'permission_denied');
    await expectError(rpc(u.client, 'cancel_sale', { p_sale: r.id, p_reason: ' ' }), 'reason_required');
    const c1 = await rpc<any>(u.client, 'cancel_sale', { p_sale: r.id, p_reason: 'Customer changed mind' });
    expect(n(c1.refund)).toBe(20000);
    const again = await rpc<any>(u.client, 'cancel_sale', { p_sale: r.id, p_reason: 'twice' });
    expect(again.already_cancelled).toBe(true);
    expect(n((await product(u, bag.id)).qty_on_hand)).toBe(before);
    const [s] = await sql('select cancelled_at is not null cancelled, cancel_reason, total, returned_total, refunded_total from sales where id = $1', [r.id]);
    expect(s).toMatchObject({ cancelled: true, cancel_reason: 'Customer changed mind' });
    expect(n(s.total)).toBe(20000); // the original sale is kept
    expect(n(s.returned_total)).toBe(20000);
    expect(n(s.refunded_total)).toBe(20000);
    const audit = await sql(`select action from audit_logs where business_id = $1 and entity_id = $2 order by created_at`, [biz, r.id]);
    expect(audit.map((a: any) => a.action)).toEqual(expect.arrayContaining(['sale.created', 'sale.cancelled']));
  });

  it('a partial, non-restockable return lowers revenue but not stock', async () => {
    const r = await recordSale(u, biz, { lines: [{ product_id: bag.id, quantity: 3 }], payments: [{ method: 'cash', amount: 30000 }] });
    const stock = n((await product(u, bag.id)).qty_on_hand);
    const [line] = await sql('select id from sale_lines where sale_id = $1', [r.id]);
    await rpc(u.client, 'create_sale_return', { p_sale: r.id, p: { client_ref: uid(), reason: 'Damaged strap', restock: false,
      lines: [{ sale_line_id: line.id, base_quantity: 1 }], refund: { amount: 10000, method: 'cash' } } });
    expect(n((await product(u, bag.id)).qty_on_hand)).toBe(stock);
    const [s] = await sql('select returned_total, refunded_total from sales where id = $1', [r.id]);
    expect(n(s.returned_total)).toBe(10000);
    expect(n(s.refunded_total)).toBe(10000);
  });

  it('profit is flagged as incomplete when a sold product has no recorded cost', async () => {
    await recordSale(u, biz, { channel: 'instagram', lines: [{ product_id: noCost.id, quantity: 1 }], payments: [{ method: 'cash', amount: 2000 }] });
    const ch = await rpc<any[]>(u.client, 'sales_by_channel', { p_business: biz, p_from: today(), p_to: today() });
    expect(ch.find((x) => x.channel === 'instagram')).toMatchObject({ missing_cost: 1 });
    const pl = await rpc<any>(u.client, 'profit_and_loss', { p_business: biz, p_from: today(), p_to: today() });
    expect(pl.data_quality.zero_cost_products_sold).toBeGreaterThanOrEqual(1);
    // Other businesses cannot read this report.
    const other = await createUser('rec-other');
    await expectError(rpc(other.client, 'sales_by_channel', { p_business: biz, p_from: today(), p_to: today() }), /permission_denied|not_member/);
  });

  it('a one-of-a-kind item is shown as sold and leaves search once it sells; history is kept', async () => {
    await rpc(u.client, 'store_save', { p_business: biz, p: { name: 'Records Shop', phone: '677000222', whatsapp: '677000222', city: 'Yaoundé', pickup_enabled: true } });
    const vintage = await addProduct(u, biz, { name: 'Vintage camera', selling_price: 45000, purchase_cost: 30000, single_item: true, condition: 'used_good' });
    await openStock(u, biz, vintage.id, 1, 30000);
    await rpc(u.client, 'products_set_online', { p_business: biz, p_ids: [vintage.id], p_online: true });
    await rpc(u.client, 'store_set_published', { p_business: biz, p_publish: true });
    const guest = anon();
    const card = await rpc<any>(guest, 'market_product', { p_id: vintage.id });
    expect(card).toMatchObject({ condition: 'used_good', sold: false, single_item: true });
    expect((await rpc<any>(guest, 'market_search', { p: { q: 'Vintage camera' } })).total).toBe(1);
    const s = await recordSale(u, biz, { channel: 'whatsapp', lines: [{ product_id: vintage.id, quantity: 1 }], payments: [{ method: 'cash', amount: 45000 }] });
    expect((await rpc<any>(guest, 'market_product', { p_id: vintage.id })).sold).toBe(true);
    expect((await rpc<any>(guest, 'market_search', { p: { q: 'Vintage camera' } })).total).toBe(0);
    // Overselling is refused and the sale history keeps the product.
    await expectError(recordSale(u, biz, { lines: [{ product_id: vintage.id, quantity: 1 }], payments: [{ method: 'cash', amount: 45000 }] }), 'insufficient_stock');
    expect(await sql('select product_id from sale_lines where sale_id = $1', [s.id])).toEqual([{ product_id: vintage.id }]);
    const { error } = await u.client.from('products').update({ condition: 'broken' }).eq('id', vintage.id);
    expect(error?.message).toMatch(/violates check constraint/);
  });

  it('alerts: duplicate-looking sales and large adjustments, with thresholds and switches per business', async () => {
    await rpc(u.client, 'save_alert_settings', { p_business: biz, p: { large_adjustment_value: 20000, disabled: ['low_stock', 'bogus'] } });
    const [st] = await sql('select alert_settings from business_settings where business_id = $1', [biz]);
    expect(st.alert_settings).toMatchObject({ large_adjustment_value: 20000, disabled: ['low_stock'], fast_selling_days: 7 });
    const lines = [{ product_id: bag.id, quantity: 1 }];
    await recordSale(u, biz, { lines, payments: [{ method: 'cash', amount: 10000 }] });
    await recordSale(u, biz, { lines, payments: [{ method: 'cash', amount: 10000 }] });
    await rpc(u.client, 'adjust_stock', { p_business: biz, p_product: bag.id, p_kind: 'damaged', p_quantity: 4, p_reason: 'Water damage' });
    await rpc(u.client, 'generate_alerts', { p_business: biz });
    const types = (await sql('select type from notifications where business_id = $1', [biz])).map((x: any) => x.type);
    expect(types).toEqual(expect.arrayContaining(['possible_duplicate_sale', 'large_adjustment']));
    expect(types).not.toContain('low_stock');
    const cashier = await addStaff(u, biz, 'cashier');
    await expectError(rpc(cashier.client, 'save_alert_settings', { p_business: biz, p: {} }), 'permission_denied');
  });
});
