import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import {
  uid, addProduct, addSupplier, closeDb, createBusiness, createUser, expectError, n, openStock, rpc, sell, sql, TestUser,
} from './helpers';

const ctxFor = async (u: TestUser, biz: string) =>
  (await rpc<any>(u.client, 'get_my_context')).businesses.find((b: any) => b.id === biz);

describe('subscriptions, entitlements, billing verification and admin portal', () => {
  let owner: TestUser; let adminUser: TestUser; let biz: string;

  beforeAll(async () => {
    owner = await createUser('subowner');
    adminUser = await createUser('platformadmin');
    await sql('select app.bootstrap_platform_admin($1)', [adminUser.email]);
    biz = await createBusiness(owner, 'Sub Test');
  });
  afterAll(closeDb);

  it('new businesses start on a Business-plan trial with all features', async () => {
    const b = await ctxFor(owner, biz);
    expect(b.subscription.state).toBe('trial');
    expect(b.plan.code).toBe('business');
    expect(b.plan.features).toContain('ai_advisor');
    await addSupplier(owner, biz);
  });

  it('after trial expiry, paid features are blocked server-side but records are preserved', async () => {
    const sup = await addSupplier(owner, biz, { name: 'Kept Supplier' });
    const p = await addProduct(owner, biz, { name: 'Kept Product' });
    await openStock(owner, biz, p.id, 10, 100);
    await sell(owner, biz, [{ product_id: p.id, quantity: 1 }], { payments: [{ method: 'cash', amount: 1000 }] });
    await sql(`update business_subscriptions set trial_ends_at = now() - interval '1 day' where business_id = $1`, [biz]);
    const b = await ctxFor(owner, biz);
    expect(b.subscription.state).toBe('expired');
    expect(b.plan.code).toBe('free');
    await expectError(rpc(owner.client, 'save_purchase', { p_business: biz, p: { supplier_id: sup.id,
      lines: [{ product_id: p.id, quantity: 1, unit_cost: 1 }] } }), 'feature_not_in_plan');
    await expectError(addSupplier(owner, biz), /row-level security/);
    await expectError(rpc(owner.client, 'restock_recommendations', { p_business: biz }), 'feature_not_in_plan');
    await expectError(rpc(owner.client, 'record_expense', { p_business: biz, p: { category: 'rent', description: 'r', amount: 1 } }),
      'feature_not_in_plan');
    // Basic operations still work and nothing was deleted
    await sell(owner, biz, [{ product_id: p.id, quantity: 1 }], { payments: [{ method: 'cash', amount: 1000 }] });
    const { data: sups } = await owner.client.from('suppliers').select('name').eq('business_id', biz);
    expect(sups!.map((s) => s.name)).toContain('Kept Supplier');
    const { count } = await owner.client.from('sales').select('id', { count: 'exact', head: true }).eq('business_id', biz);
    expect(count).toBe(2);
    const dash = await rpc<any>(owner.client, 'dashboard_summary', { p_business: biz, p_from: '2026-01-01', p_to: '2026-12-31' });
    expect(dash.period.transactions).toBe(2);
  });

  it('enforces the free plan product limit on the server', async () => {
    const used = (await sql<{ c: string }>(`select count(*) c from products where business_id = $1 and status = 'active'`, [biz]))[0].c;
    for (let i = Number(used); i < 30; i++) await addProduct(owner, biz);
    await expectError(addProduct(owner, biz), 'plan_limit_reached');
  });

  it('pending payments do not activate a plan; duplicate references are rejected', async () => {
    const ref = `MP241022.${uid().slice(0, 8)}.A1`;
    const pid = await rpc<string>(owner.client, 'submit_billing_payment', { p_business: biz, p: {
      plan_code: 'business', billing_period: 'monthly', method: 'mtn_momo', transaction_ref: ref } });
    let b = await ctxFor(owner, biz);
    expect(b.plan.code).toBe('free');
    expect(b.subscription.payment_pending).toBe(true);
    await expectError(rpc(owner.client, 'submit_billing_payment', { p_business: biz, p: {
      plan_code: 'business', billing_period: 'monthly', method: 'mtn_momo', transaction_ref: ref.toLowerCase() } }),
      'duplicate_transaction_reference');
    // Customers cannot verify their own payments
    await expectError(rpc(owner.client, 'admin_review_billing_payment', { p_payment: pid, p_approve: true }), 'permission_denied');
    const { data: bp } = await owner.client.from('billing_payments').select('status, expected_amount').eq('id', pid).single();
    expect(bp).toEqual({ status: 'pending', expected_amount: 3000 });

    // Platform admin verifies => plan active for one month, with audit + notification
    const res = await rpc<any>(adminUser.client, 'admin_review_billing_payment', { p_payment: pid, p_approve: true, p_note: 'Checked MoMo statement' });
    expect(res.status).toBe('verified');
    b = await ctxFor(owner, biz);
    expect(b.plan.code).toBe('business');
    expect(b.subscription.state).toBe('active');
    await expectError(rpc(adminUser.client, 'admin_review_billing_payment', { p_payment: pid, p_approve: true }), 'already_reviewed');
    const { data: notes } = await owner.client.from('notifications').select('type').eq('business_id', biz);
    expect(notes!.map((x) => x.type)).toContain('billing_payment_verified');
    const { data: logs } = await adminUser.client.from('audit_logs').select('action').eq('entity_id', pid);
    expect(logs!.map((l) => l.action)).toContain('billing.payment_verified');
  });

  it('grace period keeps access, then access drops to free', async () => {
    await sql(`update business_subscriptions set current_period_end = now() - interval '2 days' where business_id = $1`, [biz]);
    let b = await ctxFor(owner, biz);
    expect(b.subscription.state).toBe('grace');
    expect(b.plan.code).toBe('business');
    await sql(`update business_subscriptions set current_period_end = now() - interval '10 days' where business_id = $1`, [biz]);
    b = await ctxFor(owner, biz);
    expect(b.subscription.state).toBe('expired');
    expect(b.plan.code).toBe('free');
    await sql(`update business_subscriptions set current_period_end = now() + interval '3 days' where business_id = $1`, [biz]);
    b = await ctxFor(owner, biz);
    expect(b.subscription.state).toBe('renewal_due');
  });

  it('rejections require a reason and notify the customer', async () => {
    const pid = await rpc<string>(owner.client, 'submit_billing_payment', { p_business: biz, p: {
      plan_code: 'starter', billing_period: 'annual', method: 'orange_money', transaction_ref: `OM-${uid().slice(0, 8)}` } });
    await expectError(rpc(adminUser.client, 'admin_review_billing_payment', { p_payment: pid, p_approve: false }), 'reason_required');
    await rpc(adminUser.client, 'admin_review_billing_payment', { p_payment: pid, p_approve: false, p_note: 'Reference not found' });
    const { data } = await owner.client.from('billing_payments').select('status, expected_amount').eq('id', pid).single();
    expect(data).toEqual({ status: 'rejected', expected_amount: 15000 });
  });

  it('platform admins see metadata but not private business records without a support grant', async () => {
    const stats = await rpc<any>(adminUser.client, 'admin_stats');
    expect(n(stats.businesses)).toBeGreaterThan(0);
    const list = await rpc<any[]>(adminUser.client, 'admin_list_businesses', { p_search: 'Sub Test' });
    expect(list[0].name).toBe('Sub Test');
    const { data: none } = await adminUser.client.from('products').select('id').eq('business_id', biz);
    expect(none).toEqual([]);
    await expectError(rpc(adminUser.client, 'admin_open_support_session', { p_business: biz, p_reason: 'x' }), 'no_support_access');
    const g = await rpc<string>(owner.client, 'grant_support_access', { p_business: biz, p_hours: 2, p_reason: 'Help with import' });
    await rpc(adminUser.client, 'admin_open_support_session', { p_business: biz, p_reason: 'Ticket 12' });
    const { data: some } = await adminUser.client.from('products').select('id').eq('business_id', biz);
    expect(some!.length).toBeGreaterThan(0);
    // read-only: admins still cannot write business records
    await expectError(sell(adminUser, biz, [{ product_id: some![0].id, quantity: 1 }]), 'permission_denied');
    await rpc(owner.client, 'revoke_support_access', { p_grant: g });
    const { data: none2 } = await adminUser.client.from('products').select('id').eq('business_id', biz);
    expect(none2).toEqual([]);
    // non-admins cannot use admin RPCs
    await expectError(rpc(owner.client, 'admin_stats'), 'permission_denied');
    await expectError(rpc(owner.client, 'admin_upsert_plan', { p: { code: 'hack', name_en: 'x', name_fr: 'x', price_monthly: 0 } }),
      'permission_denied');
  });

  it('admins can change prices and limits without code changes', async () => {
    await rpc(adminUser.client, 'admin_upsert_plan', { p: { code: 'starter', name_en: 'Starter', name_fr: 'Starter',
      price_monthly: 2000, price_annual: 20000,
      features: ['purchases', 'suppliers', 'expenses', 'customers_credit', 'staff', 'import', 'cash_reconciliation', 'basic_analytics', 'stocktaking'],
      limits: { max_products: 300, max_sales_per_month: 2000, max_staff: 3, history_days: 365, ai_queries_per_month: 0 }, sort: 2 } });
    const { data } = await owner.client.from('plans').select('price_monthly').eq('code', 'starter').single();
    expect(n(data!.price_monthly)).toBe(2000);
    await rpc(adminUser.client, 'admin_upsert_plan', { p: { code: 'starter', name_en: 'Starter', name_fr: 'Starter',
      price_monthly: 1500, price_annual: 15000,
      features: ['purchases', 'suppliers', 'expenses', 'customers_credit', 'staff', 'import', 'cash_reconciliation', 'basic_analytics', 'stocktaking'],
      limits: { max_products: 300, max_sales_per_month: 2000, max_staff: 3, history_days: 365, ai_queries_per_month: 0 }, sort: 2 } });
  });
});
