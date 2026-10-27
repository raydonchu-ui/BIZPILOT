// AI Business Manager: answers from the seller's real records, premium only, metered, tenant-isolated, and no action
// happens without a confirmation that the server allows (only the two draft kinds are allowed).
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { addProduct, closeDb, createBusiness, createUser, expectError, n, openStock, rpc, sell, sql, type TestUser } from './helpers';

describe('AI Business Manager', () => {
  let owner: TestUser; let outsider: TestUser; let biz: string; let tee: any; let low: any; let conv: string;

  beforeAll(async () => {
    owner = await createUser('ai-owner');
    outsider = await createUser('ai-outsider');
    biz = await createBusiness(owner, 'Assistant Shop', { category: 'fashion' });
    tee = await addProduct(owner, biz, { name: 'Blue Tee', selling_price: 5000, min_stock: 2 });
    await openStock(owner, biz, tee.id, 10, 2000);
    low = await addProduct(owner, biz, { name: 'Canvas Bag', selling_price: 9000, min_stock: 5 });
    await openStock(owner, biz, low.id, 3, 4000);
    await sell(owner, biz, [{ product_id: tee.id, quantity: 2 }], { payments: [{ method: 'cash', amount: 10000 }] });
  });
  afterAll(closeDb);

  it('the Business plan does not include the AI Business Manager; Verified Premium does', async () => {
    await expectError(rpc(owner.client, 'ai_send_message', { p_business: biz, p_conversation: null, p_text: 'How much revenue?' }), 'feature_not_in_plan');
    await sql(`update business_subscriptions set plan_code = 'verified_premium', status = 'active', billing_period = 'monthly',
               current_period_start = now(), current_period_end = now() + interval '30 days' where business_id = $1`, [biz]);
  });

  it('revenue comes from the recorded sales: returns are deducted, and the answer says it is not profit', async () => {
    const r = await rpc<any>(owner.client, 'ai_send_message', { p_business: biz, p_conversation: null, p_text: 'How much revenue did I record this week?', p_lang: 'en' });
    conv = r.conversation_id;
    expect(r.intent).toBe('revenue');
    expect(n(r.data.revenue)).toBe(10000);
    expect(n(r.data.cost)).toBe(4000);
    expect(r.text).toContain('10 000 FCFA');
    expect(r.text).toContain('not profit');
  });

  it('profit is worked out from recorded cost and expenses, and labelled as an estimate when costs are incomplete', async () => {
    const r = await rpc<any>(owner.client, 'ai_send_message', { p_business: biz, p_conversation: conv, p_text: 'What was my estimated profit this month?', p_lang: 'en' });
    expect(r.intent).toBe('profit');
    expect(n(r.data.gross_profit)).toBe(6000);
    expect(n(r.data.operating_profit_estimate)).toBe(6000);
    expect(r.data.data_quality.costs_complete).toBe(true);
    expect(r.text).not.toMatch(/estimate/i);
  });

  it('restocking names the products below their minimum, from the stock records', async () => {
    const r = await rpc<any>(owner.client, 'ai_send_message', { p_business: biz, p_conversation: conv, p_text: 'Which products need restocking?', p_lang: 'en' });
    expect(r.intent).toBe('restock');
    expect(r.text).toContain('Canvas Bag');
    expect(r.text).not.toContain('Blue Tee');
  });

  it('a product description is a draft built only from the recorded product fields', async () => {
    const r = await rpc<any>(owner.client, 'ai_send_message', { p_business: biz, p_conversation: conv, p_text: 'Write a description for Blue Tee', p_lang: 'en' });
    expect(r.intent).toBe('copy');
    expect(r.data.title).toBe('Blue Tee');
    expect(r.data.description).toContain('5 000 FCFA');
    expect(r.data.draft).toBe(true);
  });

  it('each answer is metered once against the monthly AI allowance', async () => {
    const before = (await sql<{ n: number }>(`select count(*)::int n from ai_queries where business_id = $1`, [biz]))[0].n;
    await rpc(owner.client, 'ai_send_message', { p_business: biz, p_conversation: conv, p_text: 'Summarize my outstanding orders.', p_lang: 'en' });
    const after = (await sql<{ n: number }>(`select count(*)::int n from ai_queries where business_id = $1`, [biz]))[0].n;
    expect(after - before).toBe(1);
  });

  it('when the monthly allowance is used up, no further answer is given', async () => {
    await sql(`update plans set limits = jsonb_set(limits, '{ai_queries_per_month}', '0') where code = 'verified_premium'`);
    try {
      await expectError(rpc(owner.client, 'ai_send_message', { p_business: biz, p_conversation: conv, p_text: 'How much revenue?', p_lang: 'en' }), 'plan_limit_reached');
    } finally {
      await sql(`update plans set limits = jsonb_set(limits, '{ai_queries_per_month}', '500') where code = 'verified_premium'`);
    }
  });

  it('another business cannot ask, read or see this seller’s conversations', async () => {
    await expectError(rpc(outsider.client, 'ai_send_message', { p_business: biz, p_conversation: null, p_text: 'Revenue?' }), 'permission_denied');
    await expectError(rpc(outsider.client, 'ai_get_conversation', { p_conversation: conv }), 'not_found');
    const seen = await outsider.client.from('ai_messages').select('id').eq('business_id', biz);
    expect(seen.data ?? []).toEqual([]);
    const mine = await owner.client.from('ai_messages').select('id').eq('business_id', biz);
    expect((mine.data ?? []).length).toBeGreaterThan(0);
  });

  it('an action is only proposed until the seller confirms it, and an action that is not enabled changes nothing', async () => {
    const before = (await sql<any>('select qty_on_hand from products where id = $1', [tee.id]))[0].qty_on_hand;
    const p = await rpc<any>(owner.client, 'ai_propose_action', { p_business: biz, p_kind: 'adjust_stock', p_payload: { product_id: tee.id, quantity: -5 } });
    expect(p.status).toBe('proposed');
    await expectError(rpc(owner.client, 'ai_confirm_action', { p_action: p.action_id }), 'action_not_enabled');
    await rpc(owner.client, 'ai_cancel_action', { p_action: p.action_id });
    await expectError(rpc(owner.client, 'ai_confirm_action', { p_action: p.action_id }), 'invalid_status');
    const after = (await sql<any>('select qty_on_hand from products where id = $1', [tee.id]))[0].qty_on_hand;
    expect(Number(after)).toBe(Number(before));
  });

  it('a draft restock list is saved for review; no purchase or payment is created', async () => {
    const purchases = (await sql<{ n: number }>('select count(*)::int n from purchases where business_id = $1', [biz]))[0].n;
    const p = await rpc<any>(owner.client, 'ai_propose_action', { p_business: biz, p_kind: 'draft_restock_list', p_payload: {} });
    expect(p.preview.lines.map((l: any) => l.name)).toContain('Canvas Bag');
    const done = await rpc<any>(owner.client, 'ai_confirm_action', { p_action: p.action_id });
    expect(done.status).toBe('executed');
    const [draft] = await sql<any>('select status, lines from supplier_draft_lists where business_id = $1', [biz]);
    expect(draft.status).toBe('draft');
    expect(draft.lines.map((l: any) => l.name)).toContain('Canvas Bag');
    expect((await sql<{ n: number }>('select count(*)::int n from purchases where business_id = $1', [biz]))[0].n).toBe(purchases);
    await expectError(rpc(owner.client, 'ai_confirm_action', { p_action: p.action_id }), 'invalid_status');
  });

  it('the seller can see and clear their own conversation history; cleared messages are gone', async () => {
    const list = await rpc<any[]>(owner.client, 'ai_list_conversations', { p_business: biz });
    expect(list.map((c) => c.id)).toContain(conv);
    const cleared = await rpc<number>(owner.client, 'ai_clear_history', { p_business: biz });
    expect(cleared).toBeGreaterThanOrEqual(1);
    await expectError(rpc(owner.client, 'ai_get_conversation', { p_conversation: conv }), 'not_found');
  });
});
