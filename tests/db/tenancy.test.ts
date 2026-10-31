import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import {
  addProduct, addStaff, addSupplier, anon, closeDb, createBusiness, createUser, expectError, openStock, rpc, sell,
  TestUser, uid,
} from './helpers';

describe('authentication, tenancy and permissions', () => {
  let alice: TestUser, bob: TestUser;
  let shopA: string, shopB: string;
  let productA: any;

  beforeAll(async () => {
    alice = await createUser('alice');
    bob = await createUser('bob');
    shopA = await createBusiness(alice, 'Alice Store');
    shopB = await createBusiness(bob, 'Bob Store');
    productA = await addProduct(alice, shopA, { name: 'Indomie Noodles' });
    await openStock(alice, shopA, productA.id, 50, 450);
  });
  afterAll(closeDb);

  it('creates the workspace with owner role, settings, accounts, the Free plan and categories', async () => {
    const ctx = await rpc<any>(alice.client, 'get_my_context');
    const biz = ctx.businesses.find((b: any) => b.id === shopA);
    expect(biz.role).toBe('owner');
    expect(biz.currency).toBe('XAF');
    expect(biz.subscription.state).toBe('free');
    expect(biz.permissions).toContain('staff.manage');
    const { data: accounts } = await alice.client.from('cash_accounts').select('kind').eq('business_id', shopA);
    expect(accounts!.map((a) => a.kind).sort()).toEqual(['bank', 'cash', 'mtn_momo', 'orange_money', 'other']);
    const { data: cats } = await alice.client.from('categories').select('name').eq('business_id', shopA);
    expect(cats!.length).toBeGreaterThan(3);
  });

  it('rejects registration outside enabled countries', async () => {
    await expectError(rpc(alice.client, 'create_business', { p: { name: 'Lagos Shop', country_code: 'NG' } }),
      'country_not_available');
  });

  it('isolates business data between tenants', async () => {
    const { data: prods } = await bob.client.from('products').select('id').eq('business_id', shopA);
    expect(prods).toEqual([]);
    const { data: biz } = await bob.client.from('businesses').select('id').eq('id', shopA);
    expect(biz).toEqual([]);
    const { data: mv } = await bob.client.from('stock_movements').select('id').eq('business_id', shopA);
    expect(mv).toEqual([]);
    // Write attempts into another tenant are rejected
    await expectError(sell(bob, shopA, [{ product_id: productA.id, quantity: 1 }]), 'permission_denied');
    await expectError(addProduct(bob, shopA), /row-level security/);
    const { data: upd } = await bob.client.from('products').update({ selling_price: 1 }).eq('id', productA.id).select();
    expect(upd).toEqual([]);
    await expectError(rpc(bob.client, 'dashboard_summary', { p_business: shopA, p_from: '2026-01-01', p_to: '2026-12-31' }),
      'permission_denied');
    // Bob cannot reference Alice's product from his own business either
    await expectError(sell(bob, shopB, [{ product_id: productA.id, quantity: 1 }]), 'invalid_product');
  });

  it('blocks anonymous access to business data and RPCs', async () => {
    const a = anon();
    const { data, error } = await a.from('products').select('id');
    expect(data ?? []).toEqual([]);
    expect(error?.message ?? 'permission denied').toMatch(/permission denied/);
    const r = await a.rpc('create_sale', { p_business: shopA, p: {} });
    expect(r.error).toBeTruthy();
    const plans = await a.from('plans').select('code,price_monthly').order('sort');
    expect(plans.data!.map((p) => p.code)).toEqual(['free', 'starter', 'business', 'verified_premium']);
  });

  it('protects computed stock fields from direct client edits', async () => {
    const { error } = await alice.client.from('products').update({ qty_on_hand: 9999 }).eq('id', productA.id);
    expect(error?.message).toContain('protected_field');
    const { error: e2 } = await alice.client.from('products').update({ avg_cost: 1 }).eq('id', productA.id);
    expect(e2?.message).toContain('protected_field');
    // Direct inserts into ledgers are not possible
    const { error: e3 } = await alice.client.from('stock_movements').insert({
      business_id: shopA, product_id: productA.id, movement_type: 'found', quantity: 5, unit_cost: 1, value: 5,
      qty_after: 5, avg_cost_after: 1, stock_value_after: 5,
    });
    expect(e3).toBeTruthy();
    const { error: e4 } = await alice.client.from('sales').insert({ business_id: shopA, number: 'X', client_ref: uid() });
    expect(e4).toBeTruthy();
    const { error: e5 } = await alice.client.from('payments').insert({
      business_id: shopA, direction: 'in', kind: 'customer_payment', method: 'cash', amount: 1000,
    });
    expect(e5).toBeTruthy();
  });

  it('enforces role permissions for cashiers', async () => {
    const cashier = await addStaff(alice, shopA, 'cashier');
    // can sell
    const sale = await sell(cashier, shopA, [{ product_id: productA.id, quantity: 1 }],
      { payments: [{ method: 'cash', amount: 1000 }] });
    expect(sale.number).toMatch(/^S-/);
    // cannot adjust stock, see purchases, record expenses, view reports or manage staff
    await expectError(rpc(cashier.client, 'adjust_stock', {
      p_business: shopA, p_product: productA.id, p_kind: 'found', p_quantity: 5, p_reason: 'x' }), 'permission_denied');
    await expectError(rpc(cashier.client, 'dashboard_summary', { p_business: shopA, p_from: '2026-01-01', p_to: '2026-12-31' }),
      'permission_denied');
    await expectError(rpc(cashier.client, 'record_expense', { p_business: shopA, p: { category: 'rent', description: 'x', amount: 10 } }),
      'permission_denied');
    await expectError(rpc(cashier.client, 'invite_member', { p_business: shopA, p_email: 'x@y.zz', p_role: 'cashier' }),
      'permission_denied');
    await expectError(addSupplier(cashier, shopA), /row-level security/);
    const { error: upd } = await cashier.client.from('products').update({ selling_price: 1 }).eq('id', productA.id);
    const p = await alice.client.from('products').select('selling_price').eq('id', productA.id).single();
    expect(Number(p.data!.selling_price)).toBe(1000);
    expect(upd).toBeNull(); // RLS silently filters the update to zero rows
    // large discounts require approval
    await expectError(sell(cashier, shopA, [{ product_id: productA.id, quantity: 1, discount_amount: 500 }],
      { payments: [{ method: 'cash', amount: 500 }] }), 'discount_requires_approval');
    // owner can grant a permission override
    const { data: members } = await alice.client.from('business_members').select('id,user_id').eq('business_id', shopA);
    const m = members!.find((x) => x.user_id === cashier.id)!;
    await rpc(alice.client, 'update_member', { p_member: m.id, p: { permissions: { 'sales.discount_large': true } } });
    const ok = await sell(cashier, shopA, [{ product_id: productA.id, quantity: 1, discount_amount: 500 }],
      { payments: [{ method: 'cash', amount: 500 }] });
    expect(Number(ok.total)).toBe(500);
    // deactivated staff lose access immediately
    await rpc(alice.client, 'update_member', { p_member: m.id, p: { active: false } });
    await expectError(sell(cashier, shopA, [{ product_id: productA.id, quantity: 1 }]), 'permission_denied');
    const { data: after } = await cashier.client.from('products').select('id').eq('business_id', shopA);
    expect(after).toEqual([]);
  });

  it('records an audit trail of important actions', async () => {
    const { data } = await alice.client.from('audit_logs').select('action').eq('business_id', shopA);
    const actions = data!.map((a) => a.action);
    expect(actions).toContain('business.created');
    expect(actions).toContain('stock.opening');
    expect(actions).toContain('sale.created');
    expect(actions).toContain('staff.updated');
  });

  it('allows ownership transfer only by the owner', async () => {
    const mgr = await addStaff(alice, shopA, 'manager');
    const { data: members } = await alice.client.from('business_members').select('id,user_id').eq('business_id', shopA);
    const m = members!.find((x) => x.user_id === mgr.id)!;
    await expectError(rpc(mgr.client, 'transfer_ownership', { p_business: shopA, p_member: m.id }), 'permission_denied');
    await rpc(alice.client, 'transfer_ownership', { p_business: shopA, p_member: m.id });
    const ctx = await rpc<any>(mgr.client, 'get_my_context');
    expect(ctx.businesses.find((b: any) => b.id === shopA).role).toBe('owner');
    const ctxA = await rpc<any>(alice.client, 'get_my_context');
    expect(ctxA.businesses.find((b: any) => b.id === shopA).role).toBe('manager');
  });
});
