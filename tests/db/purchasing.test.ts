import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import {
  addProduct, addSupplier, closeDb, createBusiness, createUser, expectError, n, product, rpc, TestUser, uid,
} from './helpers';

describe('wholesale purchasing, receiving and supplier balances', () => {
  let u: TestUser; let biz: string; let sup: any; let p1: any; let p2: any;

  const balance = async () => {
    const rows = await rpc<any[]>(u.client, 'supplier_balances', { p_business: biz });
    return n(rows.find((r) => r.id === sup.id)?.balance);
  };
  const purchase = async (id: string) =>
    (await u.client.from('purchases').select('*, purchase_lines(*)').eq('id', id).single()).data as any;

  beforeAll(async () => {
    u = await createUser('buyer');
    biz = await createBusiness(u, 'Wholesale Test');
    sup = await addSupplier(u, biz, { name: 'Douala Grossiste', payment_terms_days: 15 });
    p1 = await addProduct(u, biz, { name: 'Milo 400g', purchase_cost: 0 });
    p2 = await addProduct(u, biz, { name: 'Sunlight Soap', purchase_cost: 0 });
  });
  afterAll(closeDb);

  it('draft and ordered purchases do not change stock; drafts create no obligation', async () => {
    const id = await rpc<string>(u.client, 'save_purchase', { p_business: biz, p: {
      supplier_id: sup.id, status: 'draft', purchase_date: '2026-10-01',
      lines: [{ product_id: p1.id, quantity: 10, unit_cost: 1000 }] } });
    expect(n((await product(u, p1.id)).qty_on_hand)).toBe(0);
    expect(await balance()).toBe(0);
    const pu = await purchase(id);
    expect(pu.due_date).toBe('2026-10-16'); // payment terms applied
    await rpc(u.client, 'mark_purchase_ordered', { p_purchase: id });
    expect(n((await product(u, p1.id)).qty_on_hand)).toBe(0);
    expect(await balance()).toBe(10000);
    await rpc(u.client, 'cancel_purchase', { p_purchase: id, p_reason: 'Supplier out of stock' });
    expect(await balance()).toBe(0);
    expect((await purchase(id)).status).toBe('cancelled');
  });

  it('partial receipts add only received quantities, with transport allocated to landed cost', async () => {
    // 10 x 1000 + 20 x 500 = 20,000 subtotal; transport 2,000 => +10% on each line
    const id = await rpc<string>(u.client, 'save_purchase', { p_business: biz, p: {
      supplier_id: sup.id, status: 'ordered', purchase_date: '2026-10-02', invoice_number: 'INV-77', transport_cost: 2000,
      lines: [{ product_id: p1.id, quantity: 10, unit_cost: 1000 }, { product_id: p2.id, quantity: 20, unit_cost: 500 }] } });
    let pu = await purchase(id);
    expect(n(pu.total)).toBe(22000);
    expect(await balance()).toBe(22000);
    const l1 = pu.purchase_lines.find((l: any) => l.product_id === p1.id);
    const l2 = pu.purchase_lines.find((l: any) => l.product_id === p2.id);

    const ref = uid();
    await rpc(u.client, 'receive_purchase', { p_purchase: id, p_lines: [{ line_id: l1.id, quantity: 4 }], p_client_ref: ref });
    // retrying the same receipt does not duplicate stock
    await rpc(u.client, 'receive_purchase', { p_purchase: id, p_lines: [{ line_id: l1.id, quantity: 4 }], p_client_ref: ref });
    let prod = await product(u, p1.id);
    expect(n(prod.qty_on_hand)).toBe(4);
    expect(n(prod.avg_cost)).toBe(1100);           // 1000 + 10% transport
    expect(n(prod.stock_value)).toBe(4400);
    pu = await purchase(id);
    expect(pu.status).toBe('partially_received');

    await expectError(rpc(u.client, 'receive_purchase', { p_purchase: id, p_lines: [{ line_id: l1.id, quantity: 7 }] }),
      'over_receipt');
    await expectError(rpc(u.client, 'cancel_purchase', { p_purchase: id, p_reason: 'x' }), 'purchase_has_receipts');
    await expectError(rpc(u.client, 'save_purchase', { p_business: biz, p: { id, supplier_id: sup.id, status: 'ordered',
      lines: [{ product_id: p1.id, quantity: 1, unit_cost: 1 }] } }), 'purchase_locked');

    await rpc(u.client, 'receive_purchase', { p_purchase: id, p_lines: [
      { line_id: l1.id, quantity: 6 }, { line_id: l2.id, quantity: 20 }] });
    pu = await purchase(id);
    expect(pu.status).toBe('received');
    expect(n((await product(u, p1.id)).qty_on_hand)).toBe(10);
    prod = await product(u, p2.id);
    expect(n(prod.qty_on_hand)).toBe(20);
    expect(n(prod.avg_cost)).toBe(550);
    // receiving value equals the full purchase cost: nothing is expensed immediately
    expect(n(pu.received_value)).toBe(22000);
    await expectError(rpc(u.client, 'receive_purchase', { p_purchase: id, p_lines: [{ line_id: l2.id, quantity: 1 }] }),
      'invalid_status');
    // stock ledger traces every receipt to the purchase
    const { data: mv } = await u.client.from('stock_movements').select('quantity,ref_number,movement_type')
      .eq('ref_id', id);
    expect(mv!.length).toBe(3);
    expect(mv!.every((m) => m.movement_type === 'purchase_receipt' && m.ref_number === pu.number)).toBe(true);
  });

  it('allocates partial supplier payments and reconciles balances', async () => {
    const before = await balance();
    const id = await rpc<string>(u.client, 'save_purchase', { p_business: biz, p: {
      supplier_id: sup.id, status: 'ordered', receive_now: true, purchase_date: '2026-10-05',
      lines: [{ product_id: p2.id, quantity: 10, unit_cost: 600 }],
      payment: { amount: 2000, method: 'mtn_momo', reference: 'MP123' } } });
    let pu = await purchase(id);
    expect(pu.status).toBe('received');
    expect(n(pu.paid_total)).toBe(2000);
    expect(await balance()).toBe(before + 6000 - 2000);

    // Unallocated payment goes to the oldest outstanding purchase first
    const ref = uid();
    await rpc(u.client, 'record_supplier_payment', { p_business: biz, p_supplier: sup.id, p_amount: 25000,
      p_method: 'cash', p_client_ref: ref });
    await rpc(u.client, 'record_supplier_payment', { p_business: biz, p_supplier: sup.id, p_amount: 25000,
      p_method: 'cash', p_client_ref: ref });  // idempotent retry
    expect(await balance()).toBe(before + 6000 - 2000 - 25000);
    const { data: all } = await u.client.from('purchases').select('number,total,paid_total,status,credited_total')
      .eq('supplier_id', sup.id).order('purchase_date');
    const owed = all!.filter((p) => p.status !== 'cancelled' && p.status !== 'draft')
      .reduce((s, p) => s + n(p.total) - n(p.credited_total) - n(p.paid_total), 0);
    expect(owed).toBe(await balance());
    pu = await purchase(id);
    expect(n(pu.paid_total)).toBe(3000 + 2000);  // 22,000 oldest fully paid, remaining 3,000 here
  });

  it('closes a short shipment with a supplier credit and returns goods to the supplier', async () => {
    const before = await balance();
    const id = await rpc<string>(u.client, 'save_purchase', { p_business: biz, p: {
      supplier_id: sup.id, status: 'ordered', purchase_date: '2026-10-06',
      lines: [{ product_id: p1.id, quantity: 10, unit_cost: 1200 }] } });
    let pu = await purchase(id);
    await rpc(u.client, 'receive_purchase', { p_purchase: id, p_lines: [{ line_id: pu.purchase_lines[0].id, quantity: 8 }] });
    const credit = await rpc<number>(u.client, 'close_purchase_short', { p_purchase: id, p_reason: '2 cartons missing' });
    expect(n(credit)).toBe(2400);
    pu = await purchase(id);
    expect(pu.status).toBe('received');
    expect(await balance()).toBe(before + 12000 - 2400);

    const qtyBefore = n((await product(u, p1.id)).qty_on_hand);
    await rpc(u.client, 'return_to_supplier', { p_purchase: id, p_reason: 'Damaged on arrival',
      p_lines: [{ line_id: pu.purchase_lines[0].id, base_quantity: 3 }] });
    expect(n((await product(u, p1.id)).qty_on_hand)).toBe(qtyBefore - 3);
    expect(await balance()).toBe(before + 12000 - 2400 - 3600);
    await expectError(rpc(u.client, 'return_to_supplier', { p_purchase: id, p_reason: 'x',
      p_lines: [{ line_id: pu.purchase_lines[0].id, base_quantity: 6 }] }), 'return_exceeds_received');
  });

  it('rejects purchases for another tenant\'s supplier or product', async () => {
    const other = await createUser('other');
    const otherBiz = await createBusiness(other, 'Other');
    await expectError(rpc(other.client, 'save_purchase', { p_business: otherBiz, p: {
      supplier_id: sup.id, lines: [{ product_id: p1.id, quantity: 1, unit_cost: 1 }] } }), 'invalid_supplier');
    const s2 = await addSupplier(other, otherBiz);
    await expectError(rpc(other.client, 'save_purchase', { p_business: otherBiz, p: {
      supplier_id: s2.id, lines: [{ product_id: p1.id, quantity: 1, unit_cost: 1 }] } }), 'invalid_product');
  });
});
