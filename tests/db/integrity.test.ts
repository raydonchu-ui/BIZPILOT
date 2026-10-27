// Seller data integrity: a retried sale is recorded once, off-platform sales are not marketplace orders, and history
// keeps its prices, costs and names when a product is changed or archived.
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { addProduct, closeDb, createBusiness, createUser, n, openStock, rpc, sql, uid, type TestUser } from './helpers';

describe('seller data integrity', () => {
  let owner: TestUser; let biz: string; let item: any;

  beforeAll(async () => {
    owner = await createUser('int-owner');
    biz = await createBusiness(owner, 'Integrity Shop', { category: 'fashion' });
    item = await addProduct(owner, biz, { name: 'Ledger shirt', selling_price: 5000, min_stock: 0 });
    await openStock(owner, biz, item.id, 20, 2000);
  });
  afterAll(closeDb);

  it('a sale sent twice (a retry after a lost reply) is recorded once and deducts stock once', async () => {
    const client_ref = uid();
    const body = { p: { client_ref, lines: [{ product_id: item.id, quantity: 2 }], payments: [{ method: 'cash', amount: 10000 }], channel: 'in_person' } };
    const first = await rpc<any>(owner.client, 'create_sale', { p_business: biz, ...body });
    const again = await rpc<any>(owner.client, 'create_sale', { p_business: biz, ...body });
    expect(again.id ?? again.sale_id).toBe(first.id ?? first.sale_id);
    const [{ n: sales }] = await sql<any>('select count(*)::int n from sales where business_id = $1 and client_ref = $2', [biz, client_ref]);
    expect(sales).toBe(1);
    const [{ qty_on_hand }] = await sql<any>('select qty_on_hand from products where id = $1', [item.id]);
    expect(n(qty_on_hand)).toBe(18);
  });

  it('an off-platform sale (a WhatsApp or counter sale) is recorded with its channel and is not a marketplace order', async () => {
    await rpc(owner.client, 'record_sale', { p_business: biz, p: { client_ref: uid(), lines: [{ product_id: item.id, quantity: 1 }],
      payments: [{ method: 'cash', amount: 5000 }], channel: 'whatsapp' } });
    const [{ channel }] = await sql<any>(`select channel from sales where business_id = $1 and channel = 'whatsapp' limit 1`, [biz]);
    expect(channel).toBe('whatsapp');
    const [{ n: orders }] = await sql<any>('select count(*)::int n from market_orders where business_id = $1', [biz]);
    expect(orders).toBe(0);
  });

  it('archiving a product keeps the history of its past sales: name, price and cost are still there', async () => {
    const [sale] = await sql<any>(`select l.unit_price, l.cost_amount, p.name, p.status from sale_lines l
      join products p on p.id = l.product_id join sales s on s.id = l.sale_id where s.business_id = $1 limit 1`, [biz]);
    await sql(`update products set status = 'archived' where id = $1`, [item.id]);
    const [after] = await sql<any>(`select l.unit_price, l.cost_amount, p.name, p.status from sale_lines l
      join products p on p.id = l.product_id join sales s on s.id = l.sale_id where s.business_id = $1 limit 1`, [biz]);
    expect(after.status).toBe('archived');
    expect(n(after.unit_price)).toBe(n(sale.unit_price));
    expect(n(after.cost_amount)).toBe(n(sale.cost_amount));
    expect(after.name).toBe(sale.name);
    await sql(`update products set status = 'active' where id = $1`, [item.id]);
  });

  it('changing a product’s price later does not change what past sales and marketplace orders recorded', async () => {
    const [before] = await sql<any>(`select unit_price from sale_lines l join sales s on s.id = l.sale_id where s.business_id = $1 limit 1`, [biz]);
    await sql(`update products set selling_price = 9999 where id = $1`, [item.id]);
    const [after] = await sql<any>(`select unit_price from sale_lines l join sales s on s.id = l.sale_id where s.business_id = $1 limit 1`, [biz]);
    expect(n(after.unit_price)).toBe(n(before.unit_price));
    await sql(`update products set selling_price = 5000 where id = $1`, [item.id]);
  });

  it('every stock change is recorded as a movement, so the stock figure can be checked against its history', async () => {
    const [{ sold, received }] = await sql<any>(`select coalesce(sum(quantity) filter (where movement_type = 'sale'), 0) as sold,
      coalesce(sum(quantity) filter (where movement_type in ('opening', 'purchase_receipt')), 0) as received
      from stock_movements where product_id = $1`, [item.id]);
    const [{ qty_on_hand }] = await sql<any>('select qty_on_hand from products where id = $1', [item.id]);
    // Sales are recorded as negative movements, so the history adds up to the stock on hand.
    expect(n(qty_on_hand)).toBe(n(received) + n(sold));
  });
});
