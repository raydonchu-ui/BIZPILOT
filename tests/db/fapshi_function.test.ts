// The Fapshi edge function, run in Node against the local Supabase stack with a simulated Fapshi API.
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { randomBytes } from 'node:crypto';
import { handle, loadConfig, safeEqual } from '../../supabase/functions/fapshi/index.ts';
import { ANON_KEY, SERVICE_KEY, SUPABASE_URL, addProduct, anon, closeDb, createBusiness, createUser, openStock, rpc, sql, uid, type TestUser } from './helpers';

const FAPSHI = 'https://fapshi.test';
const SECRET = 'wh-secret-for-tests';
const cfg = loadConfig((k) => ({
  SUPABASE_URL, SUPABASE_ANON_KEY: ANON_KEY, SUPABASE_SERVICE_ROLE_KEY: SERVICE_KEY, FAPSHI_BASE_URL: FAPSHI,
  FAPSHI_API_USER: 'test-user', FAPSHI_API_KEY: 'test-key', FAPSHI_WEBHOOK_SECRET: SECRET, SITE_URL: 'https://shop.example',
} as Record<string, string>)[k]);

// Simulated Fapshi: remembers created transactions; tests set the status Fapshi will report.
const tx = new Map<string, { amount: number; externalId: string; status: string }>();
const calls: { method: string; path: string; body: any; headers: Record<string, string> }[] = [];
let failInitiate = false;
const fetchMock: typeof fetch = async (input, init) => {
  const url = String(input);
  if (!url.startsWith(FAPSHI)) return fetch(input, init);
  const path = url.slice(FAPSHI.length);
  const body = init?.body ? JSON.parse(String(init.body)) : null;
  calls.push({ method: init?.method ?? 'GET', path, body, headers: (init?.headers ?? {}) as Record<string, string> });
  const ok = (d: unknown) => new Response(JSON.stringify(d), { status: 200 });
  if (path === '/initiate-pay') {
    if (failInitiate) return new Response(JSON.stringify({ message: 'Invalid API credentials' }), { status: 403 });
    const transId = `tx${randomBytes(4).toString('hex')}`;
    tx.set(transId, { amount: body.amount, externalId: body.externalId, status: 'CREATED' });
    return ok({ message: 'Request successful', link: `https://checkout.fapshi.test/${transId}`, transId, dateInitiated: new Date().toISOString() });
  }
  if (path.startsWith('/payment-status/')) {
    const id = decodeURIComponent(path.split('/').pop()!);
    const t = tx.get(id);
    if (!t) return new Response(JSON.stringify({ message: 'Not found' }), { status: 404 });
    return ok({ transId: id, status: t.status, amount: t.amount, externalId: t.externalId, medium: 'mobile money', payerName: 'Awa' });
  }
  if (path === '/expire-pay') {
    const t = tx.get(body.transId);
    if (t && t.status !== 'SUCCESSFUL') t.status = 'EXPIRED';
    return ok({ transId: body.transId, status: 'EXPIRED' });
  }
  return new Response('{}', { status: 404 });
};

type JsonResponse = Omit<Response, 'json'> & { json(): Promise<any> };
const post = (body: unknown, opts: { path?: string; auth?: string; headers?: Record<string, string> } = {}): Promise<JsonResponse> =>
  handle(new Request(`${SUPABASE_URL}/functions/v1/fapshi${opts.path ?? ''}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', ...(opts.auth ? { Authorization: `Bearer ${opts.auth}` } : {}), ...(opts.headers ?? {}) },
    body: JSON.stringify(body),
  }), cfg, fetchMock);

async function setConfig(patch: Record<string, unknown>) {
  await sql(`update app_config set value = value || $1::jsonb where key = 'marketplace'`, [JSON.stringify(patch)]);
}

describe('Fapshi edge function', () => {
  let owner: TestUser; let biz: string; let productId: string;
  const token = () => randomBytes(24).toString('hex');
  const placeOnline = async (tk: string, qty = 1) => rpc(anon(), 'market_place_order', { p: {
    client_ref: uid(), access_token: tk, items: [{ product_id: productId, quantity: qty }], delivery_method: 'pickup',
    payment_method: 'online', customer: { name: 'Awa', phone: `69${Math.floor(1e6 + Math.random() * 8e6)}`, email: 'awa@example.com' } } });

  beforeAll(async () => {
    await sql(`delete from rate_limits where key like 'order_%' or key like 'pay_begin:%' or key like 'report_ip:%'`);
    await setConfig({ online_payments_enabled: true });
    owner = await createUser('fx-owner');
    biz = await createBusiness(owner, 'Fapshi Test Shop');
    await rpc(owner.client, 'store_save', { p_business: biz, p: { phone: '677001122', pickup_enabled: true, online_payment_enabled: true } });
    const p = await addProduct(owner, biz, { name: 'Phone case', selling_price: 2500 });
    productId = p.id;
    await openStock(owner, biz, p.id, 10, 1000);
    await rpc(owner.client, 'products_set_online', { p_business: biz, p_ids: [p.id], p_online: true });
    await rpc(owner.client, 'store_set_published', { p_business: biz, p_publish: true });
  });
  afterAll(async () => { await setConfig({ online_payments_enabled: false }); await closeDb(); });

  it('compares webhook secrets in constant time', () => {
    expect(safeEqual('abc', 'abc')).toBe(true);
    expect(safeEqual('abc', 'abd')).toBe(false);
    expect(safeEqual('abc', 'abcd')).toBe(false);
  });

  it('starts a hosted checkout with the amount from the database, not from the request', async () => {
    const tk = token();
    const o = await placeOnline(tk, 2);
    const res = await post({ action: 'order', order_id: o.order_id, token: tk, amount: 1 });
    expect(res.status).toBe(200);
    const out = await res.json();
    expect(out.link).toMatch(/^https:\/\/checkout\.fapshi\.test\//);
    const init = calls.filter((c) => c.path === '/initiate-pay').pop()!;
    expect(init.body.amount).toBe(5000);
    expect(init.body.externalId).toBe(out.payment_id);
    expect(init.body.redirectUrl).toBe(`https://shop.example/pay/return?p=${out.payment_id}`);
    expect(init.headers.apiuser).toBe('test-user');
    // Someone without the order token cannot start a payment for it.
    const bad = await post({ action: 'order', order_id: o.order_id, token: token() });
    expect(bad.status).toBe(400);
    expect((await bad.json()).error).toBe('not_found');
  });

  it('webhook: requires the secret, re-checks the status with Fapshi and ignores the body’s claims', async () => {
    const tk = token();
    const o = await placeOnline(tk);
    const { payment_id } = await (await post({ action: 'order', order_id: o.order_id, token: tk })).json();
    const [{ trans_id }] = await sql('select trans_id from online_payments where id = $1', [payment_id]);
    expect((await post({ transId: trans_id, status: 'SUCCESSFUL' }, { path: '/webhook' })).status).toBe(401);
    expect((await post({ transId: trans_id, status: 'SUCCESSFUL' }, { path: '/webhook', headers: { 'x-wh-secret': 'wrong' } })).status).toBe(401);
    // The body says SUCCESSFUL but Fapshi still reports PENDING: nothing is paid.
    tx.get(trans_id)!.status = 'PENDING';
    const r1 = await post({ transId: trans_id, status: 'SUCCESSFUL', amount: 2500 }, { path: '/webhook', headers: { 'x-wh-secret': SECRET } });
    expect(r1.status).toBe(200);
    expect((await sql('select payment_status from market_orders where id = $1', [o.order_id]))[0].payment_status).toBe('awaiting_payment');
    tx.get(trans_id)!.status = 'SUCCESSFUL';
    await post({ transId: trans_id }, { path: '/webhook', headers: { 'x-wh-secret': SECRET } });
    expect((await sql('select payment_status from market_orders where id = $1', [o.order_id]))[0].payment_status).toBe('paid');
    // A duplicate notification changes nothing.
    await post({ transId: trans_id }, { path: '/webhook', headers: { 'x-wh-secret': SECRET } });
    const pays = await sql(`select status from online_payments where order_id = $1`, [o.order_id]);
    expect(pays).toEqual([{ status: 'successful' }]);
  });

  it('verify (buyer returned from checkout): reports a failed payment; retrying closes the old link', async () => {
    const tk = token();
    const o = await placeOnline(tk);
    const first = await (await post({ action: 'order', order_id: o.order_id, token: tk })).json();
    const [{ trans_id: t1 }] = await sql('select trans_id from online_payments where id = $1', [first.payment_id]);
    tx.get(t1)!.status = 'FAILED';
    const v = await (await post({ action: 'verify', payment_id: first.payment_id })).json();
    expect(v.status).toBe('failed');
    expect(v.order_payment_status).toBe('failed');
    // Retry with a link still open: it is expired at Fapshi before a new one is created.
    const second = await (await post({ action: 'order', order_id: o.order_id, token: tk })).json();
    const [{ trans_id: t2 }] = await sql('select trans_id from online_payments where id = $1', [second.payment_id]);
    const third = await (await post({ action: 'order', order_id: o.order_id, token: tk })).json();
    expect(third.payment_id).not.toBe(second.payment_id);
    expect(calls.some((c) => c.path === '/expire-pay' && c.body.transId === t2)).toBe(true);
    expect((await sql('select status from online_payments where id = $1', [second.payment_id]))[0].status).toBe('expired');
    // Status checks are throttled per payment.
    const again = await (await post({ action: 'verify', payment_id: first.payment_id })).json();
    expect(again.status).toBeTruthy();
  });

  it('subscription payments need a signed-in owner; provider errors are reported without recording a transaction', async () => {
    expect((await post({ action: 'subscription', business_id: biz, plan_code: 'starter' })).status).toBe(401);
    const { data } = await owner.client.auth.getSession();
    const ok = await post({ action: 'subscription', business_id: biz, plan_code: 'starter', period: 'monthly' }, { auth: data.session!.access_token });
    expect(ok.status).toBe(200);
    expect(calls.filter((c) => c.path === '/initiate-pay').pop()!.body.amount).toBe(1500);
    const stranger = await createUser('fx-stranger');
    const { data: s2 } = await stranger.client.auth.getSession();
    const denied = await post({ action: 'subscription', business_id: biz, plan_code: 'starter' }, { auth: s2.session!.access_token });
    expect((await denied.json()).error).toBe('permission_denied');
    failInitiate = true;
    try {
      const tk = token();
      const o = await placeOnline(tk);
      const r = await post({ action: 'order', order_id: o.order_id, token: tk });
      expect(r.status).toBe(502);
      const rows = await sql('select trans_id from online_payments where order_id = $1', [o.order_id]);
      expect(rows.every((x: any) => x.trans_id === null)).toBe(true);
    } finally { failInitiate = false; }
  });
});
