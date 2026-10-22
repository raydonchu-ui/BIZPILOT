// Exercises the ai-advisor Edge Function over HTTP. Runs only when ADVISOR_URL is
// set (e.g. `supabase functions serve` -> http://127.0.0.1:54321/functions/v1/ai-advisor,
// or a standalone Deno run). ADVISOR_EXPECT selects the expected outcome:
//   not_configured (no ANTHROPIC_API_KEY), ai_error (invalid key), ai (valid key).
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { addProduct, closeDb, createBusiness, createUser, openStock, rpc, sell, sql, TestUser } from './helpers';

const URL = process.env.ADVISOR_URL;
const EXPECT = process.env.ADVISOR_EXPECT ?? 'not_configured';

describe.skipIf(!URL)('ai-advisor edge function', () => {
  let u: TestUser; let biz: string; let token: string;
  beforeAll(async () => {
    u = await createUser('advisor');
    biz = await createBusiness(u, 'Advisor Shop');
    const p = await addProduct(u, biz, { name: 'Maggi', selling_price: 50 });
    await openStock(u, biz, p.id, 100, 30);
    await sell(u, biz, [{ product_id: p.id, quantity: 10 }], { payments: [{ method: 'cash', amount: 500 }] });
    token = (await u.client.auth.getSession()).data.session!.access_token;
  });
  afterAll(closeDb);

  const call = (body: unknown, auth = true) => fetch(URL!, {
    method: 'POST', headers: { 'Content-Type': 'application/json', ...(auth ? { Authorization: `Bearer ${token}` } : {}) },
    body: JSON.stringify(body),
  });
  const today = new Date().toISOString().slice(0, 10);

  it('rejects unauthenticated calls and other tenants', async () => {
    expect((await call({ business_id: biz, question: 'x', from: today, to: today }, false)).status).toBe(401);
    const other = await createUser('other');
    const otherBiz = await createBusiness(other, 'Other');
    const r = await call({ business_id: otherBiz, question: 'x', from: today, to: today });
    expect(r.status).toBe(403);
    expect((await r.json()).error).toBe('permission_denied');
  });

  it(`answers grounded in server-computed context (${EXPECT})`, async () => {
    const r = await call({ business_id: biz, question: 'Which products sell fastest?', from: '2026-01-01', to: '2026-12-31', lang: 'en' });
    expect(r.status).toBe(200);
    const j = await r.json();
    if (EXPECT === 'ai') {
      expect(j.mode).toBe('ai');
      expect(j.answer.length).toBeGreaterThan(20);
    } else {
      expect(j.mode).toBe('fallback');
      expect(j.reason).toBe(EXPECT);
      expect(j.context.summary.transactions).toBe(1);
      expect(j.context.top_by_units[0].name).toBe('Maggi');
    }
    const rows = await sql(`select status, error from ai_queries where business_id = $1`, [biz]);
    expect(rows[0].status).toBe(EXPECT === 'ai' ? 'completed' : EXPECT === 'not_configured' ? 'fallback' : 'failed');
  });

  it('does not count failed or fallback answers against the monthly quota', async () => {
    const used = await rpc<number>(u.client, 'ai_begin_query', { p_business: biz, p_question: 'q', p_from: today, p_to: today });
    expect(used).toBeTruthy();
    const n = await sql<{ c: string }>(`select count(*) c from ai_queries where business_id = $1 and status in ('started','completed')`, [biz]);
    expect(Number(n[0].c)).toBe(EXPECT === 'ai' ? 2 : 1);
  });

  it('enforces the plan feature on the server', async () => {
    await sql(`update business_subscriptions set trial_ends_at = now() - interval '1 day' where business_id = $1`, [biz]);
    const r = await call({ business_id: biz, question: 'x', from: today, to: today });
    expect(r.status).toBe(403);
    expect((await r.json()).error).toBe('feature_not_in_plan');
  });
});
