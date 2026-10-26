// Storefront: stock status on product cards, read-only storefront for customers, and store editing
// only for owners and managers (cashiers and strangers are refused, by the database).
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import {
  addProduct, addStaff, anon, closeDb, createBusiness, createUser, expectError, n, openStock, rpc, sql, uid, type TestUser,
} from './helpers';

describe('storefront: stock status, read-only for customers, editing by authorised staff', () => {
  let owner: TestUser; let biz: string; let slug: string;
  let plenty: any; let few: any; let none: any;

  beforeAll(async () => {
    owner = await createUser('sf-owner');
    biz = await createBusiness(owner, 'Storefront Shop', { category: 'fashion' });
    await rpc(owner.client, 'store_save', { p_business: biz, p: { name: 'Storefront Shop', phone: '677000111', whatsapp: '677000111', city: 'Yaoundé',
      pickup_enabled: true, opening_hours: { mon: { open: '08:00', close: '19:00' } } } });
    [{ slug }] = await sql<{ slug: string }>('select slug from stores where business_id = $1', [biz]);
    plenty = await addProduct(owner, biz, { name: 'Plenty dress', selling_price: 9000, min_stock: 3 });
    await openStock(owner, biz, plenty.id, 10, 4000);
    few = await addProduct(owner, biz, { name: 'Few sneakers', selling_price: 28000, min_stock: 3 });
    await openStock(owner, biz, few.id, 2, 15000);
    none = await addProduct(owner, biz, { name: 'Gone sunglasses', selling_price: 15000, min_stock: 3 });
    await openStock(owner, biz, none.id, 1, 9000);
    for (const p of [plenty, few, none]) {
      await rpc(owner.client, 'products_set_online', { p_business: biz, p_ids: [p.id], p_online: true });
    }
    await rpc(owner.client, 'store_set_published', { p_business: biz, p_publish: true });
  });
  afterAll(closeDb);

  it('product cards carry a stock status from recorded stock: in, low or out', async () => {
    const page = await rpc<any>(anon(), 'market_search', { p: { store: slug, sort: 'newest' } });
    const byName = Object.fromEntries(page.items.map((x: any) => [x.name, x.stock]));
    expect(byName['Plenty dress']).toBe('in');
    expect(byName['Few sneakers']).toBe('low');
    // The last unit was sold: sell it through a counter sale so the stock is really zero.
    await rpc(owner.client, 'create_sale', { p_business: biz, p: { client_ref: uid(), lines: [{ product_id: none.id, quantity: 1 }],
      payments: [{ method: 'cash', amount: 15000 }] } });
    const after = await rpc<any>(anon(), 'market_search', { p: { store: slug, sort: 'newest' } });
    expect(after.items.find((x: any) => x.name === 'Gone sunglasses')?.stock).toBe('out');
    const card = await rpc<any>(anon(), 'market_product', { p_id: none.id });
    expect(card.stock).toBe('out');
    expect(card.available).toBe(0);
  });

  it('the public storefront shows no costs, stock values or supplier data', async () => {
    const store = await rpc<any>(anon(), 'market_store', { p_slug: slug });
    const text = JSON.stringify(store);
    expect(text).not.toMatch(/purchase_cost|cost_|stock_value|supplier|qty_on_hand/);
    expect(store.opening_hours).toEqual({ mon: { open: '08:00', close: '19:00' } });
    expect(store.city).toBe('Yaoundé');
  });

  it('customers cannot change a store: direct writes change nothing and the store editor refuses them', async () => {
    const shopper = await createUser('sf-shopper');
    // Refused outright (error) or matching no rows: either way the store is untouched.
    const { data } = await shopper.client.from('stores').update({ name: 'Hacked' }).eq('business_id', biz).select('business_id');
    expect(data ?? []).toEqual([]);
    expect((await sql('select name from stores where business_id = $1', [biz]))[0].name).toBe('Storefront Shop');
    await expectError(rpc(shopper.client, 'store_save', { p_business: biz, p: { name: 'Hacked' } }), /permission_denied|not_member/);
    await expectError(rpc(shopper.client, 'store_set_published', { p_business: biz, p_publish: false }), /permission_denied|not_member/);
    await expectError(rpc(shopper.client, 'store_save_payments', { p_business: biz, p: { cod_enabled: false } }), /permission_denied|not_member/);
  });

  it('a cashier cannot edit the store; a manager can', async () => {
    const cashier = await addStaff(owner, biz, 'cashier');
    await expectError(rpc(cashier.client, 'store_save', { p_business: biz, p: { name: 'Cashier edit' } }), 'permission_denied');
    const manager = await addStaff(owner, biz, 'manager');
    await rpc(manager.client, 'store_save', { p_business: biz, p: { tagline: 'Managed by the manager' } });
    expect((await sql('select tagline from stores where business_id = $1', [biz]))[0].tagline).toBe('Managed by the manager');
  });

  it('the storefront read is the only public access to product data', async () => {
    const rows = await sql(`select count(*)::int n from products where business_id = $1`, [biz]);
    expect(rows[0].n).toBeGreaterThan(0);
    const { data, error } = await anon().from('products').select('id,name,purchase_cost').eq('business_id', biz);
    expect(data ?? []).toEqual([]);
    expect(error === null || typeof error.message === 'string').toBe(true);
  });
});
