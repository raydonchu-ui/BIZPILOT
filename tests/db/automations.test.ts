// Premium automations: switched on or off by the seller, run on demand or on schedule, recorded, retried on failure,
// and never changing stock, prices, sales or money. Alerts are not repeated on the same day.
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { addProduct, addStaff, closeDb, createBusiness, createUser, expectError, n, openStock, rpc, sell, sql, type TestUser } from './helpers';

describe('premium automations', () => {
  let owner: TestUser; let outsider: TestUser; let biz: string; let low: any; let tee: any; let runId: string;

  const snapshot = async () => ({
    stock: (await sql<any>('select id, qty_on_hand, selling_price from products where business_id = $1 order by id', [biz])),
    sales: (await sql<{ n: number }>('select count(*)::int n from sales where business_id = $1', [biz]))[0].n,
    purchases: (await sql<{ n: number }>('select count(*)::int n from purchases where business_id = $1', [biz]))[0].n,
    ledger: (await sql<{ n: number }>('select count(*)::int n from cash_movements where business_id = $1', [biz]))[0].n,
    messages: (await sql<{ n: number }>('select count(*)::int n from messages m join conversations c on c.id = m.conversation_id where c.business_id = $1', [biz]))[0].n,
  });

  beforeAll(async () => {
    owner = await createUser('auto-owner');
    outsider = await createUser('auto-outsider');
    biz = await createBusiness(owner, 'Automation Shop', { category: 'fashion' });
    low = await addProduct(owner, biz, { name: 'Auto low item', selling_price: 4000, min_stock: 5 });
    await openStock(owner, biz, low.id, 2, 1000);
    tee = await addProduct(owner, biz, { name: 'Auto tee', selling_price: 6000, min_stock: 1 });
    await openStock(owner, biz, tee.id, 10, 2000);
    await sell(owner, biz, [{ product_id: tee.id, quantity: 2 }], { payments: [{ method: 'cash', amount: 12000 }] });
  });
  afterAll(closeDb);

  it('automations need the premium entitlement; the Business plan cannot switch them on', async () => {
    await expectError(rpc(owner.client, 'automation_set', { p_business: biz, p_kind: 'low_stock_alert', p_enabled: true }), 'feature_not_in_plan');
    await sql(`update business_subscriptions set plan_code = 'verified_premium', status = 'active', billing_period = 'monthly',
               current_period_start = now(), current_period_end = now() + interval '30 days' where business_id = $1`, [biz]);
  });

  it('a seller switches an automation on, sets its frequency, and sees it in the list', async () => {
    await rpc(owner.client, 'automation_set', { p_business: biz, p_kind: 'low_stock_alert', p_enabled: true, p_frequency: 'daily' });
    await rpc(owner.client, 'automation_set', { p_business: biz, p_kind: 'weekly_summary', p_enabled: true, p_frequency: 'weekly' });
    const list = await rpc<any[]>(owner.client, 'automation_list', { p_business: biz });
    expect(list.find((a: any) => a.kind === 'low_stock_alert')).toMatchObject({ enabled: true, frequency: 'daily' });
    expect(list.find((a: any) => a.kind === 'weekly_summary')).toMatchObject({ enabled: true, frequency: 'weekly' });
    expect(list.find((a: any) => a.kind === 'restock_list')).toMatchObject({ enabled: false });
  });

  it('a low-stock run tells the seller once a day; a second run the same day adds nothing', async () => {
    const before = await snapshot();
    const first = await rpc<any>(owner.client, 'automation_run', { p_business: biz, p_kind: 'low_stock_alert' });
    expect(first.status).toBe('succeeded');
    const count = async () => (await sql<{ n: number }>(`select count(*)::int n from notifications where business_id = $1 and type = 'low_stock'`, [biz]))[0].n;
    const once = await count();
    expect(once).toBeGreaterThanOrEqual(1);
    await rpc(owner.client, 'automation_run', { p_business: biz, p_kind: 'low_stock_alert' });
    expect(await count()).toBe(once);
    const after = await snapshot();
    expect(after.stock).toEqual(before.stock);
  });

  it('a weekly summary is built from recorded sales and is labelled with its period', async () => {
    const r = await rpc<any>(owner.client, 'automation_run', { p_business: biz, p_kind: 'weekly_summary' });
    expect(r.status).toBe('succeeded');
    expect(n(r.result.revenue)).toBe(12000);
    const [note] = await sql<any>(`select params from notifications where business_id = $1 and type = 'automation_summary'`, [biz]);
    expect(n(note.params.revenue)).toBe(12000);
    expect(note.params).toHaveProperty('period_from');
  });

  it('a restock list is saved as a draft; it changes no stock, purchase or payment', async () => {
    await rpc(owner.client, 'automation_set', { p_business: biz, p_kind: 'restock_list', p_enabled: true });
    const before = await snapshot();
    const r = await rpc<any>(owner.client, 'automation_run', { p_business: biz, p_kind: 'restock_list' });
    expect(r.result.products_below_minimum).toBeGreaterThanOrEqual(1);
    const drafts = await sql<any>(`select status, lines from supplier_draft_lists where business_id = $1 and title like 'Automatic restock%'`, [biz]);
    expect(drafts).toHaveLength(1);
    expect(drafts[0].lines.map((l: any) => l.name)).toContain('Auto low item');
    const after = await snapshot();
    expect(after.purchases).toBe(before.purchases);
    expect(after.ledger).toBe(before.ledger);
    expect(after.stock).toEqual(before.stock);
  });

  it('the follow-up and order reminders never message a customer; they only notify the seller', async () => {
    const before = await snapshot();
    await rpc(owner.client, 'automation_set', { p_business: biz, p_kind: 'customer_followup', p_enabled: true });
    await rpc(owner.client, 'automation_run', { p_business: biz, p_kind: 'customer_followup' });
    await rpc(owner.client, 'automation_set', { p_business: biz, p_kind: 'pending_order_reminder', p_enabled: true });
    await rpc(owner.client, 'automation_run', { p_business: biz, p_kind: 'pending_order_reminder' });
    expect((await snapshot()).messages).toBe(before.messages);
  });

  it('a switched-off automation does not run', async () => {
    await rpc(owner.client, 'automation_set', { p_business: biz, p_kind: 'low_stock_alert', p_enabled: false });
    await expectError(rpc(owner.client, 'automation_run', { p_business: biz, p_kind: 'low_stock_alert' }), 'automation_disabled');
  });

  it('a failed run is recorded and can be retried; retries stop after three attempts', async () => {
    const [failed] = await sql<{ id: string }>(`insert into automation_runs (business_id, kind, attempt, status, trigger, error, finished_at)
      values ($1, 'weekly_summary', 1, 'failed', 'manual', 'simulated outage', now()) returning id`, [biz]);
    runId = failed.id;
    const retry = await rpc<any>(owner.client, 'automation_retry', { p_run: runId });
    expect(retry).toMatchObject({ status: 'succeeded', attempt: 2 });
    await expectError(rpc(owner.client, 'automation_retry', { p_run: runId }), 'invalid_status');
    const [f2] = await sql<{ id: string }>(`insert into automation_runs (business_id, kind, attempt, status, trigger, error, finished_at)
      values ($1, 'weekly_summary', 3, 'failed', 'retry', 'still failing', now()) returning id`, [biz]);
    await expectError(rpc(owner.client, 'automation_retry', { p_run: f2.id }), 'retry_limit_reached');
    const history = await rpc<any[]>(owner.client, 'automation_history', { p_business: biz });
    expect(history.length).toBeGreaterThanOrEqual(3);
  });

  it('the scheduler runs only the automations that are due, and moves their next run forward', async () => {
    await rpc(owner.client, 'automation_set', { p_business: biz, p_kind: 'weekly_summary', p_enabled: true, p_frequency: 'weekly' });
    await sql(`update seller_automations set next_run_at = now() - interval '1 minute' where business_id = $1 and kind = 'weekly_summary'`, [biz]);
    const ran = await sql<{ n: number }>('select app.run_due_automations() as n');
    expect(ran[0].n).toBeGreaterThanOrEqual(1);
    const [row] = await sql<any>(`select next_run_at > now() + interval '6 days' as later from seller_automations where business_id = $1 and kind = 'weekly_summary'`, [biz]);
    expect(row.later).toBe(true);
  });

  it('another business cannot see or run this seller’s automations; staff without settings rights cannot change them', async () => {
    await expectError(rpc(outsider.client, 'automation_list', { p_business: biz }), 'permission_denied');
    await expectError(rpc(outsider.client, 'automation_run', { p_business: biz, p_kind: 'weekly_summary' }), 'permission_denied');
    const cashier = await addStaff(owner, biz, 'cashier');
    await expectError(rpc(cashier.client, 'automation_set', { p_business: biz, p_kind: 'restock_list', p_enabled: false }), 'permission_denied');
  });
});
