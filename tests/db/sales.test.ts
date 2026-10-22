import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import {
  addCustomer, addProduct, addSupplier, closeDb, createBusiness, createUser, expectError, n, openStock, product, rpc,
  sell, TestUser, uid,
} from './helpers';

describe('sales, payments, returns, units and historical costs', () => {
  let u: TestUser; let biz: string; let soap: any;

  beforeAll(async () => {
    u = await createUser('seller');
    biz = await createBusiness(u, 'Sales Test');
    soap = await addProduct(u, biz, { name: 'Sunlight Soap', selling_price: 300, purchase_cost: 200 });
    await openStock(u, biz, soap.id, 100, 200);
  });
  afterAll(closeDb);

  it('completing a sale deducts stock, records COGS and payment', async () => {
    const r = await sell(u, biz, [{ product_id: soap.id, quantity: 5 }], { payments: [{ method: 'cash', amount: 1500 }] });
    expect(n(r.total)).toBe(1500);
    const p = await product(u, soap.id);
    expect(n(p.qty_on_hand)).toBe(95);
    const { data: s } = await u.client.from('sales').select('*, sale_lines(*)').eq('id', r.id).single();
    expect(n(s!.cost_total)).toBe(1000);
    expect(n(s!.paid_total)).toBe(1500);
    expect(n(s!.sale_lines[0].cost_unit_base)).toBe(200);
    const { data: pay } = await u.client.from('payments').select('amount,method,kind').eq('sale_id', r.id);
    expect(pay).toEqual([{ amount: 1500, method: 'cash', kind: 'sale_payment' }]);
  });

  it('repeated and concurrent submissions of the same sale create exactly one sale', async () => {
    const ref = uid();
    const body = { p_business: biz, p: { client_ref: ref, lines: [{ product_id: soap.id, quantity: 2 }],
      payments: [{ method: 'orange_money', amount: 600, reference: 'OM-1' }] } };
    const before = n((await product(u, soap.id)).qty_on_hand);
    const results = await Promise.all([1, 2, 3, 4].map(() => rpc<any>(u.client, 'create_sale', body)));
    expect(new Set(results.map((r) => r.id)).size).toBe(1);
    expect(results.filter((r) => !r.duplicate).length).toBe(1);
    const again = await rpc<any>(u.client, 'create_sale', body);
    expect(again.duplicate).toBe(true);
    expect(n((await product(u, soap.id)).qty_on_hand)).toBe(before - 2);
    const { count } = await u.client.from('sales').select('id', { count: 'exact', head: true }).eq('client_ref', ref);
    expect(count).toBe(1);
  });

  it('prevents negative stock and overpayment', async () => {
    await expectError(sell(u, biz, [{ product_id: soap.id, quantity: 10000 }]), 'insufficient_stock');
    await expectError(sell(u, biz, [{ product_id: soap.id, quantity: 1 }], { payments: [{ method: 'cash', amount: 500 }] }),
      'overpayment');
    await expectError(sell(u, biz, [{ product_id: soap.id, quantity: 1.5 }]), 'fractional_quantity_not_allowed');
  });

  it('credit sales require a customer, and partial payments produce correct balances', async () => {
    await expectError(sell(u, biz, [{ product_id: soap.id, quantity: 10 }], { payments: [{ method: 'cash', amount: 1000 }] }),
      'customer_required_for_credit');
    const c = await addCustomer(u, biz, { name: 'Marie N.', credit_limit: 5000 });
    const s1 = await sell(u, biz, [{ product_id: soap.id, quantity: 10 }],
      { customer_id: c.id, payments: [{ method: 'cash', amount: 1000 }], due_date: '2026-10-01' });
    let bal = (await rpc<any[]>(u.client, 'customer_balances', { p_business: biz })).find((x) => x.id === c.id);
    expect(n(bal.balance)).toBe(2000);
    expect(n(bal.overdue)).toBe(2000);
    await expectError(sell(u, biz, [{ product_id: soap.id, quantity: 12 }], { customer_id: c.id }), 'credit_limit_exceeded');
    await rpc(u.client, 'record_customer_payment', { p_business: biz, p_customer: c.id, p_amount: 1500, p_method: 'mtn_momo',
      p_reference: 'MOMO-9' });
    bal = (await rpc<any[]>(u.client, 'customer_balances', { p_business: biz })).find((x) => x.id === c.id);
    expect(n(bal.balance)).toBe(500);
    const { data: s } = await u.client.from('sales').select('paid_total').eq('id', s1.id).single();
    expect(n(s!.paid_total)).toBe(2500);
    const stmt = await rpc<any[]>(u.client, 'party_statement', { p_business: biz, p_kind: 'customer', p_party: c.id });
    expect(n(stmt[stmt.length - 1].running_balance)).toBe(500);
  });

  it('returns restore stock at the original cost and reverse revenue; refunds are bounded', async () => {
    const r = await sell(u, biz, [{ product_id: soap.id, quantity: 4 }], { payments: [{ method: 'cash', amount: 1200 }] });
    const { data: s } = await u.client.from('sales').select('*, sale_lines(*)').eq('id', r.id).single();
    const before = n((await product(u, soap.id)).qty_on_hand);
    await expectError(rpc(u.client, 'create_sale_return', { p_sale: r.id, p: { reason: 'x',
      lines: [{ sale_line_id: s!.sale_lines[0].id, base_quantity: 5 }] } }), 'return_exceeds_sold');
    // Walk-in sale: the returned value must be refunded
    await rpc(u.client, 'create_sale_return', { p_sale: r.id, p: { reason: 'Wrong item', client_ref: uid(),
      lines: [{ sale_line_id: s!.sale_lines[0].id, base_quantity: 1 }], refund: { method: 'cash', amount: 0 } } });
    expect(n((await product(u, soap.id)).qty_on_hand)).toBe(before + 1);
    const { data: s2 } = await u.client.from('sales').select('*').eq('id', r.id).single();
    expect(n(s2!.returned_total)).toBe(300);
    expect(n(s2!.refunded_total)).toBe(300);
    expect(n(s2!.returned_cost)).toBe(200);
    const { data: ret } = await u.client.from('sale_returns').select('refund_amount').eq('sale_id', r.id);
    expect(n(ret![0].refund_amount)).toBe(300);
  });

  it('carton purchases and unit sales convert correctly and keep historical COGS', async () => {
    const coke = await addProduct(u, biz, { name: 'Coca Cola 50cl', base_unit: 'bottle', selling_price: 500, purchase_cost: 0 });
    const { data: carton } = await u.client.from('product_units').insert({
      business_id: biz, product_id: coke.id, name: 'carton', factor: 24, is_default_purchase: true, selling_price: 11000,
    }).select().single();
    const sup = await addSupplier(u, biz);
    // Buy 2 cartons at 7,200 => 300 per bottle
    await rpc(u.client, 'save_purchase', { p_business: biz, p: { supplier_id: sup.id, status: 'ordered', receive_now: true,
      lines: [{ product_id: coke.id, unit_id: carton!.id, quantity: 2, unit_cost: 7200 }] } });
    let p = await product(u, coke.id);
    expect(n(p.qty_on_hand)).toBe(48);
    expect(n(p.avg_cost)).toBe(300);
    const { data: line } = await u.client.from('purchase_lines').select('unit_name,unit_factor,qty_ordered')
      .eq('product_id', coke.id).single();
    expect(line).toMatchObject({ unit_name: 'carton', unit_factor: 24, qty_ordered: 2 });

    // Sell 10 bottles and 1 carton
    const s1 = await sell(u, biz, [{ product_id: coke.id, quantity: 10 }, { product_id: coke.id, unit_id: carton!.id, quantity: 1 }],
      { payments: [{ method: 'cash', amount: 16000 }] });
    expect(n(s1.total)).toBe(5000 + 11000);
    p = await product(u, coke.id);
    expect(n(p.qty_on_hand)).toBe(48 - 34);
    const { data: lines1 } = await u.client.from('sale_lines').select('base_quantity,cost_amount,unit_name').eq('sale_id', s1.id).order('sort');
    expect(lines1!.map((l) => [l.unit_name, n(l.base_quantity), n(l.cost_amount)])).toEqual([['bottle', 10, 3000], ['carton', 24, 7200]]);

    // A later purchase at a higher cost changes the average but not past COGS
    await rpc(u.client, 'save_purchase', { p_business: biz, p: { supplier_id: sup.id, status: 'ordered', receive_now: true,
      lines: [{ product_id: coke.id, unit_id: carton!.id, quantity: 1, unit_cost: 9600 }] } });
    p = await product(u, coke.id);
    // (14 x 300 + 24 x 400) / 38 = 363.16
    expect(n(p.qty_on_hand)).toBe(38);
    expect(n(p.avg_cost)).toBeCloseTo(363.1579, 3);
    const { data: lines1b } = await u.client.from('sale_lines').select('cost_amount').eq('sale_id', s1.id).order('sort');
    expect(lines1b!.map((l) => n(l.cost_amount))).toEqual([3000, 7200]);
    const s2 = await sell(u, biz, [{ product_id: coke.id, quantity: 38 }], { payments: [{ method: 'cash', amount: 19000 }] });
    const { data: l2 } = await u.client.from('sale_lines').select('cost_amount').eq('sale_id', s2.id).single();
    expect(n(l2!.cost_amount)).toBeCloseTo(4200 + 9600, 2); // full remaining value, no residue
    p = await product(u, coke.id);
    expect(n(p.qty_on_hand)).toBe(0);
    expect(n(p.stock_value)).toBe(0);

    // Inventory value always equals the sum of ledger movements
    const { data: mv } = await u.client.from('stock_movements').select('value').eq('product_id', coke.id);
    expect(mv!.reduce((a, m) => a + n(m.value), 0)).toBeCloseTo(0, 4);
    // Unit factor must belong to the product
    await expectError(sell(u, biz, [{ product_id: soap.id, unit_id: carton!.id, quantity: 1 }]), 'invalid_unit');
  });

  it('sale-level discounts are allocated to lines and tax is computed when configured', async () => {
    await rpc(u.client, 'update_business_settings', { p_business: biz, p: { tax_enabled: true, tax_rate: 19.25 } });
    const a = await addProduct(u, biz, { selling_price: 1000 });
    const b = await addProduct(u, biz, { selling_price: 3000 });
    await openStock(u, biz, a.id, 10, 500);
    await openStock(u, biz, b.id, 10, 2000);
    const r = await sell(u, biz, [{ product_id: a.id, quantity: 1 }, { product_id: b.id, quantity: 1 }],
      { discount_amount: 400, payments: [{ method: 'cash', amount: 3600 }] });
    const { data: lines } = await u.client.from('sale_lines').select('net_amount,sale_discount_alloc,tax_amount').eq('sale_id', r.id).order('sort');
    expect(lines!.map((l) => n(l.sale_discount_alloc))).toEqual([100, 300]);
    expect(lines!.map((l) => n(l.net_amount))).toEqual([900, 2700]);
    expect(lines!.map((l) => n(l.tax_amount))).toEqual([145, 436]);  // inclusive: 900 x 19.25/119.25
    await rpc(u.client, 'update_business_settings', { p_business: biz, p: { tax_enabled: false } });
  });
});
