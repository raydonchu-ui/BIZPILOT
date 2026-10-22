import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import {
  addCustomer, addProduct, addSupplier, closeDb, createBusiness, createUser, expectError, n, openStock, product, rpc,
  sell, sql, TestUser, uid,
} from './helpers';

const today = () => new Date(Date.now() + 3600_000).toISOString().slice(0, 10); // Africa/Douala (UTC+1)

describe('analytics, cash, expenses, imports and stocktaking', () => {
  let u: TestUser; let biz: string; let noodles: any; let cement: any; let milo: any; let sup: any;

  beforeAll(async () => {
    u = await createUser('analyst');
    biz = await createBusiness(u, 'Analytics Test');
    sup = await addSupplier(u, biz, { name: 'Wholesaler', lead_time_days: 2 });
    noodles = await addProduct(u, biz, { name: 'Indomie Noodles', selling_price: 300, min_stock: 20 });
    cement = await addProduct(u, biz, { name: 'Dangote Cement', selling_price: 5000 });
    milo = await addProduct(u, biz, { name: 'Milo 400g', selling_price: 1200 });
    await rpc(u.client, 'save_purchase', { p_business: biz, p: { supplier_id: sup.id, status: 'ordered', receive_now: true,
      lines: [{ product_id: noodles.id, quantity: 100, unit_cost: 200 }, { product_id: cement.id, quantity: 10, unit_cost: 4800 },
              { product_id: milo.id, quantity: 30, unit_cost: 900 }] } });
    // Backdate the stock so "no recent sales" analysis has a full window of history
    await sql(`update stock_movements set occurred_at = now() - interval '45 days' where business_id = $1`, [biz]);
    await sql(`update products set created_at = now() - interval '45 days' where business_id = $1`, [biz]);
    for (let i = 0; i < 8; i++) {
      await sell(u, biz, [{ product_id: noodles.id, quantity: 10 }], { payments: [{ method: 'cash', amount: 3000 }] });
    }
    await sell(u, biz, [{ product_id: cement.id, quantity: 2 }], { payments: [{ method: 'mtn_momo', amount: 10000 }] });
  });
  afterAll(closeDb);

  it('dashboard metrics reconcile with the underlying transactions', async () => {
    const d = await rpc<any>(u.client, 'dashboard_summary', { p_business: biz, p_from: today(), p_to: today() });
    expect(d.period.transactions).toBe(9);
    expect(n(d.period.net_sales)).toBe(24000 + 10000);
    expect(n(d.period.cogs)).toBe(80 * 200 + 2 * 4800);
    expect(n(d.period.gross_profit)).toBe(34000 - 25600);
    expect(n(d.period.gross_margin_pct)).toBeCloseTo(24.7, 1);
    expect(n(d.inventory_value)).toBe(20 * 200 + 8 * 4800 + 30 * 900);
    expect(n(d.period.units_sold)).toBe(82);
    expect(n(d.period.cash_received)).toBe(34000);
    // A date range without sales shows zero, not stale data
    const empty = await rpc<any>(u.client, 'dashboard_summary', { p_business: biz, p_from: '2026-01-01', p_to: '2026-01-31' });
    expect(empty.period.transactions).toBe(0);
    expect(n(empty.period.net_sales)).toBe(0);
  });

  it('ranks bestsellers and most profitable products from real transactions', async () => {
    const top = await rpc<any[]>(u.client, 'top_products', { p_business: biz, p_from: today(), p_to: today() });
    expect(top[0].name).toBe('Indomie Noodles');
    const perf = await rpc<any[]>(u.client, 'product_performance', { p_business: biz, p_from: today(), p_to: today() });
    const byGp = [...perf].sort((a, b) => n(b.gross_profit) - n(a.gross_profit));
    expect(byGp[0].name).toBe('Indomie Noodles');                 // 8,000 GP
    expect(n(perf.find((p) => p.name === 'Dangote Cement').margin_pct)).toBe(4); // weak margin
    const cats = await rpc<any[]>(u.client, 'category_performance', { p_business: biz, p_from: today(), p_to: today() });
    expect(cats.reduce((s, c) => s + n(c.revenue), 0)).toBe(34000);
  });

  it('recommends restocking from sales velocity and flags slow movers', async () => {
    const rec = await rpc<any[]>(u.client, 'restock_recommendations', { p_business: biz, p_lookback: 30 });
    const r = rec.find((x) => x.name === 'Indomie Noodles');
    expect(r).toBeTruthy();
    // 80 units over 30 observed days, lead 2 + safety 3 + planning 14 days
    expect(n(r.avg_daily)).toBeCloseTo(2.667, 2);
    expect(n(r.recommended_qty)).toBe(Math.ceil(80 / 30 * 19 - 20));
    expect(r.confidence).toBe('medium');
    const slow = await rpc<any[]>(u.client, 'slow_moving_products', { p_business: biz });
    const cls = Object.fromEntries(slow.map((s) => [s.name, s.classification]));
    expect(cls).toEqual({ 'Milo 400g': 'no_sales', 'Dangote Cement': 'slow' }); // 8 left at 2 per 30 days = 120 days cover
    expect(n(slow.find((s) => s.name === 'Dangote Cement').days_of_cover)).toBe(120);
    const ins = await rpc<any[]>(u.client, 'business_insights', { p_business: biz, p_from: today(), p_to: today() });
    const codes = ins.map((i) => i.code);
    expect(codes).toContain('restock_needed');
    expect(codes).toContain('weak_margin');
    expect(codes).toContain('slow_moving_capital');
    expect(codes).toContain('top_profit_product');
    for (const i of ins) {
      expect(i.period.from).toBeTruthy();
      expect(Array.isArray(i.limitations)).toBe(true);
    }
    const ctx = await rpc<any>(u.client, 'advisor_context', { p_business: biz, p_from: today(), p_to: today() });
    expect(ctx.summary.transactions).toBe(9);
    expect(ctx.business.currency).toBe('XAF');
  });

  it('discloses insufficient data instead of inventing conclusions', async () => {
    const ins = await rpc<any[]>(u.client, 'business_insights', { p_business: biz, p_from: '2026-01-01', p_to: '2026-01-31' });
    expect(ins.map((i) => i.code)).toContain('insufficient_data');
  });

  it('expenses reduce operating profit; inventory purchases are never expensed twice', async () => {
    const eid = await rpc<string>(u.client, 'record_expense', { p_business: biz, p: {
      category: 'rent', description: 'October rent', amount: 5000, paid_amount: 5000, method: 'cash', client_ref: uid() } });
    await rpc(u.client, 'record_expense', { p_business: biz, p: { category: 'utilities', description: 'ENEO', amount: 2000 } });
    await expectError(rpc(u.client, 'record_expense', { p_business: biz, p: { category: 'stock', description: 'x', amount: 1 } }),
      /violates check constraint/);
    const pl = await rpc<any>(u.client, 'profit_and_loss', { p_business: biz, p_from: today(), p_to: today() });
    expect(n(pl.operating_expenses)).toBe(7000);
    expect(n(pl.operating_profit)).toBe(8400 - 7000);
    expect(n(pl.expenses_paid)).toBe(5000);
    // the 95,000 stock purchase is inventory (cost flows through COGS when sold), never an operating expense
    expect(n(pl.purchases_total)).toBe(95000);
    expect(n(pl.cogs)).toBe(25600);
    await rpc(u.client, 'void_expense', { p_expense: eid, p_reason: 'Entered twice' });
    const pl2 = await rpc<any>(u.client, 'profit_and_loss', { p_business: biz, p_from: today(), p_to: today() });
    expect(n(pl2.operating_expenses)).toBe(2000);
    const { data: e } = await u.client.from('expenses').select('status,paid_amount').eq('id', eid).single();
    expect(e).toEqual({ status: 'voided', paid_amount: 0 });
  });

  it('cash position separates transfers from revenue and shows reconciliation differences', async () => {
    const { data: accts } = await u.client.from('cash_accounts').select('id,kind').eq('business_id', biz);
    const cash = accts!.find((a) => a.kind === 'cash')!; const bank = accts!.find((a) => a.kind === 'bank')!;
    const pos0 = await rpc<any[]>(u.client, 'cash_position', { p_business: biz, p_date: today() });
    const c0 = pos0.find((p) => p.kind === 'cash');
    // 24,000 cash sales - rent paid 5,000 + void reversal 5,000
    expect(n(c0.expected)).toBe(24000);
    await rpc(u.client, 'record_cash_movement', { p_business: biz, p_kind: 'transfer', p_from: cash.id, p_to: bank.id,
      p_amount: 10000, p_note: 'Bank deposit' });
    await expectError(rpc(u.client, 'record_cash_movement', { p_business: biz, p_kind: 'withdrawal', p_from: cash.id, p_to: null,
      p_amount: 1000, p_note: '' }), 'reason_required');
    const pos = await rpc<any[]>(u.client, 'cash_position', { p_business: biz, p_date: today() });
    expect(n(pos.find((p) => p.kind === 'cash').expected)).toBe(14000);
    expect(n(pos.find((p) => p.kind === 'bank').expected)).toBe(10000);
    const pl = await rpc<any>(u.client, 'profit_and_loss', { p_business: biz, p_from: today(), p_to: today() });
    expect(n(pl.net_sales)).toBe(34000); // transfer not counted as revenue
    const rid = await rpc<string>(u.client, 'save_cash_reconciliation', { p_business: biz, p_date: today(),
      p_lines: [{ account_id: cash.id, counted: 13500 }], p_notes: 'Evening count' });
    const { data: rec } = await u.client.from('cash_reconciliations').select('total_expected,total_counted,total_difference')
      .eq('id', rid).single();
    expect(rec).toEqual({ total_expected: 14000, total_counted: 13500, total_difference: -500 });
    // the discrepancy does not change any transaction
    const pos2 = await rpc<any[]>(u.client, 'cash_position', { p_business: biz, p_date: today() });
    expect(n(pos2.find((p) => p.kind === 'cash').expected)).toBe(14000);
  });

  it('stocktaking records discrepancies with reasons and adjusts through the ledger', async () => {
    const cid = await rpc<string>(u.client, 'create_stock_count', { p_business: biz, p_product_ids: [noodles.id, milo.id] });
    await rpc(u.client, 'save_stock_count_lines', { p_count: cid, p_lines: [
      { product_id: noodles.id, counted_qty: 18 }, { product_id: milo.id, counted_qty: 30 }] });
    await expectError(rpc(u.client, 'complete_stock_count', { p_count: cid }), 'reason_required_for_discrepancy');
    await rpc(u.client, 'save_stock_count_lines', { p_count: cid, p_lines: [
      { product_id: noodles.id, counted_qty: 18, reason: 'Two packs missing' }] });
    const res = await rpc<any>(u.client, 'complete_stock_count', { p_count: cid });
    expect(res.adjusted_lines).toBe(1);
    expect(n(res.value_difference)).toBe(-400);
    expect(n((await product(u, noodles.id)).qty_on_hand)).toBe(18);
    const pl = await rpc<any>(u.client, 'profit_and_loss', { p_business: biz, p_from: today(), p_to: today() });
    expect(n(pl.stock_losses)).toBe(400);
    const disc = await rpc<any>(u.client, 'inventory_discrepancies', { p_business: biz, p_from: today(), p_to: today() });
    expect(disc.count_differences[0].reason).toBe('Two packs missing');
    await expectError(rpc(u.client, 'adjust_stock', { p_business: biz, p_product: milo.id, p_kind: 'damaged', p_quantity: 2,
      p_reason: '' }), 'reason_required');
    await rpc(u.client, 'adjust_stock', { p_business: biz, p_product: milo.id, p_kind: 'damaged', p_quantity: 2,
      p_reason: 'Torn packaging' });
    expect(n((await product(u, milo.id)).qty_on_hand)).toBe(28);
  });

  it('imports products with preview, duplicate detection and safe rollback', async () => {
    const rows = [
      { name: 'Maggi Cube', sku: 'MAG-1', selling_price: '200', purchase_cost: '150', opening_qty: '50', category: 'Condiments' },
      { name: 'Duplicate', sku: 'mag-1' },
      { name: '', sku: 'X' },
      { name: 'Bad number', sku: 'BAD', selling_price: 'abc' },
      { name: 'Tomato Paste', sku: '', opening_qty: '12' },
    ];
    const pv = await rpc<any>(u.client, 'preview_product_import', { p_business: biz, p_rows: rows });
    expect(pv.valid).toBe(2);
    expect(pv.rows[1].errors).toContain('duplicate_sku_in_file');
    expect(pv.rows[2].errors).toContain('name_required');
    expect(pv.rows[3].errors).toContain('invalid_number:selling_price');
    const res = await rpc<any>(u.client, 'import_products', { p_business: biz, p_rows: rows, p_file_name: 'stock.csv' });
    expect(res.created).toBe(2);
    expect(res.skipped).toBe(3);
    const { data: maggi } = await u.client.from('products').select('id,qty_on_hand,avg_cost').eq('sku', 'MAG-1').single();
    expect(n(maggi!.qty_on_hand)).toBe(50);
    const { data: est } = await u.client.from('stock_movements').select('cost_estimated').eq('product_id', maggi!.id).single();
    expect(est!.cost_estimated).toBe(true); // no opening cost given => flagged as estimate
    const again = await rpc<any>(u.client, 'preview_product_import', { p_business: biz, p_rows: [rows[0]] });
    expect(again.rows[0].errors).toContain('duplicate_sku');
    await rpc(u.client, 'rollback_import', { p_batch: res.batch_id });
    const { data: gone } = await u.client.from('products').select('id').eq('sku', 'MAG-1');
    expect(gone).toEqual([]);
    // rollback is blocked once imported products have real activity
    const res2 = await rpc<any>(u.client, 'import_products', { p_business: biz, p_rows: [rows[0]] });
    const { data: m2 } = await u.client.from('products').select('id').eq('sku', 'MAG-1').single();
    await sell(u, biz, [{ product_id: m2!.id, quantity: 1 }], { payments: [{ method: 'cash', amount: 200 }] });
    await expectError(rpc(u.client, 'rollback_import', { p_batch: res2.batch_id }), 'import_has_activity');
  });

  it('generates alerts from real records and exports all business data', async () => {
    const c = await addCustomer(u, biz);
    await sell(u, biz, [{ product_id: cement.id, quantity: 1 }], { customer_id: c.id, due_date: '2026-01-01' });
    await rpc(u.client, 'generate_alerts', { p_business: biz });
    await rpc(u.client, 'generate_alerts', { p_business: biz }); // deduplicated
    const { data } = await u.client.from('notifications').select('type').eq('business_id', biz);
    const types = data!.map((x) => x.type);
    expect(types).toContain('low_stock');
    expect(types).toContain('customer_overdue');
    expect(types.filter((t) => t === 'low_stock').length).toBe(1);
    const exp = await rpc<any>(u.client, 'export_business_data', { p_business: biz });
    expect(exp.business.name).toBe('Analytics Test');
    expect(exp.sales.length).toBeGreaterThan(9);
    expect(exp.stock_movements.length).toBeGreaterThan(5);
  });
});
