// Administrator financial control centre: figures reconcile with the records behind them, only administrators can
// see them, and the location list can be corrected without breaking saved delivery areas.
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { anon, closeDb, createBusiness, createUser, expectError, n, rpc, sql, uid, type TestUser } from './helpers';

describe('admin financial control centre', () => {
  let admin: TestUser; let outsider: TestUser; let owner: TestUser; let biz: string;
  const today = () => new Date().toISOString().slice(0, 10);
  const ref = () => `MP-FIN.${uid().slice(0, 8)}.Q1`;

  beforeAll(async () => {
    admin = await createUser('fin-admin');
    await sql('select app.bootstrap_platform_admin($1)', [admin.email]);
    outsider = await createUser('fin-outsider');
    owner = await createUser('fin-owner');
    biz = await createBusiness(owner, 'Finance Shop', { category: 'fashion' });
    for (let i = 0; i < 2; i++) {
      const pid = await rpc<string>(owner.client, 'submit_billing_payment', { p_business: biz, p: {
        plan_code: 'business', billing_period: 'monthly', method: 'mtn_momo', transaction_ref: ref() } });
      await rpc(admin.client, 'admin_review_billing_payment', { p_payment: pid, p_approve: true });
    }
  });
  afterAll(closeDb);

  it('only platform administrators can open the finance overview, the drill-down or the health view', async () => {
    await expectError(rpc(outsider.client, 'admin_finance_overview', { p_from: today(), p_to: today() }), 'permission_denied');
    await expectError(rpc(owner.client, 'admin_finance_payments', { p_from: today(), p_to: today() }), 'permission_denied');
    await expectError(rpc(outsider.client, 'admin_platform_health'), 'permission_denied');
  });

  it('gross collections are the verified subscription payments in the period, broken down by plan', async () => {
    const o = await rpc<any>(admin.client, 'admin_finance_overview', { p_from: today(), p_to: today() });
    // Collections are payments approved in the period, including those refunded since (they were collected).
    const [{ s, c }] = await sql<any>(`select coalesce(sum(amount),0) s, count(*)::int c from billing_payments
      where status in ('verified', 'refunded') and reviewed_at >= app.range_start(null, $1::date) and reviewed_at < app.range_end(null, $1::date)`, [today()]);
    expect(n(o.collections.gross)).toBe(n(s));
    expect(o.collections.count).toBe(c);
    const planSum = o.collections.by_plan.reduce((a: number, p: any) => a + n(p.amount), 0);
    expect(planSum).toBe(n(o.collections.gross));
    expect(o.collections.first_payments + o.collections.renewals).toBe(o.collections.count);
  });

  it('a refund is shown as a refund, and net is collections minus refunds minus commission; it is labelled as not profit', async () => {
    const [{ id }] = await sql<any>(`select id from billing_payments where status = 'verified' and business_id = $1 order by reviewed_at desc limit 1`, [biz]);
    await rpc(admin.client, 'admin_refund_billing_payment', { p_payment: id, p_reason: 'Finance test refund' });
    const o = await rpc<any>(admin.client, 'admin_finance_overview', { p_from: today(), p_to: today() });
    expect(o.collections.refunded.count).toBeGreaterThanOrEqual(1);
    const expectedNet = n(o.collections.gross) - n(o.collections.refunded.amount) - (n(o.commissions.accrued) - n(o.commissions.reversed));
    expect(n(o.net.after_refunds_and_commission)).toBe(expectedNet);
    expect(o.net.is_profit).toBe(false);
    expect(o.not_recorded).toContain('hosting');
  });

  it('the drill-down lists the payments behind the numbers, with their status', async () => {
    const rows = await rpc<any[]>(admin.client, 'admin_finance_payments', { p_from: today(), p_to: today() });
    expect(rows.length).toBeGreaterThanOrEqual(2);
    expect(rows.map((r) => r.status)).toEqual(expect.arrayContaining(['verified']));
    const refunded = await rpc<any[]>(admin.client, 'admin_finance_payments', { p_from: today(), p_to: today(), p_status: 'refunded' });
    expect(refunded.length).toBeGreaterThanOrEqual(1);
  });

  it('the health view counts what needs attention, and every count is zero or more', async () => {
    const h = await rpc<any>(admin.client, 'admin_platform_health');
    for (const k of ['open_support', 'open_reports', 'open_disputes', 'stale_pending_payments', 'verifications_waiting',
      'failed_automation_runs_7d', 'failed_online_payments_7d', 'failed_payouts']) {
      expect(h[k]).toBeGreaterThanOrEqual(0);
    }
  });

  it('an invalid period is refused', async () => {
    await expectError(rpc(admin.client, 'admin_finance_overview', { p_from: today(), p_to: '2000-01-01' }), 'invalid_period');
  });

  it('a locality can be added, hidden, and corrected for accents only; a change that would alter its key is refused', async () => {
    // Names are unique per run (the database keeps them), so the test uses letters only.
    const slug = Math.random().toString(36).replace(/[^a-z]/g, '').slice(0, 6);
    const town = `Ndokotti ${slug}`;
    await expectError(rpc(outsider.client, 'admin_add_locality', { p_region: 'littoral', p_name: town }), 'permission_denied');
    await expectError(rpc(admin.client, 'admin_add_locality', { p_region: 'mars', p_name: 'Nowhere' }), 'region_not_found');
    const id = await rpc<string>(admin.client, 'admin_add_locality', { p_region: 'littoral', p_name: town });
    const [{ key }] = await sql<any>('select key from cameroon_localities where id = $1', [id]);
    const list = await rpc<any>(anon(), 'market_locations');
    expect(list.localities).toEqual(expect.arrayContaining([expect.objectContaining({ region: 'littoral', name: town, key })]));
    await expectError(rpc(admin.client, 'admin_add_locality', { p_region: 'littoral', p_name: town.toUpperCase() }), 'locality_exists');
    await expectError(rpc(admin.client, 'admin_update_locality', { p_id: id, p_name: `Bonaberi ${slug}` }), 'locality_key_change_not_allowed');
    await rpc(admin.client, 'admin_update_locality', { p_id: id, p_name: town.toLowerCase() });
    await rpc(admin.client, 'admin_update_locality', { p_id: id, p_active: false });
    const after = await rpc<any>(anon(), 'market_locations');
    expect(after.localities.find((l: any) => l.key === key)).toBeUndefined();
    const all = await rpc<any>(admin.client, 'admin_locations_list');
    expect(all.localities.find((l: any) => l.id === id)).toMatchObject({ active: false, key });
  });

  it('region names can be corrected by an administrator and the change is recorded', async () => {
    await rpc(admin.client, 'admin_set_region_names', { p_code: 'west', p_en: 'West', p_fr: 'Ouest' });
    await expectError(rpc(admin.client, 'admin_set_region_names', { p_code: 'west', p_en: 'W', p_fr: 'O' }), 'invalid_request');
    const [{ name_fr }] = await sql<any>(`select name_fr from cameroon_regions where code = 'west'`);
    expect(name_fr).toBe('Ouest');
  });
});
