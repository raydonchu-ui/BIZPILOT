// The Fapshi edge function, run in Node against the local Supabase stack with a simulated Fapshi API.
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';
import { randomBytes } from 'node:crypto';
import { cmPhone, handle, loadConfig, safeEqual, type FapshiConfig } from '../../supabase/functions/fapshi/index.ts';
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
let directDisabled = false;
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
  if (path === '/direct-pay') {
    if (directDisabled) return new Response(JSON.stringify({ message: 'Direct pay is not enabled for this service' }), { status: 403 });
    const transId = `dp${randomBytes(4).toString('hex')}`;
    tx.set(transId, { amount: body.amount, externalId: body.externalId, status: 'PENDING' });
    return ok({ message: 'Request successful', transId, dateInitiated: new Date().toISOString() });
  }
  if (path === '/balance') return ok({ service: 'BizPilot', balance: 123456, currency: 'XAF' });
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
  // billing_fapshi_begin allows 10 payment starts per business per day.
  beforeEach(async () => { await sql(`delete from rate_limits where key like 'billing_pay:%'`); });

  it('compares webhook secrets in constant time', () => {
    expect(safeEqual('abc', 'abc')).toBe(true);
    expect(safeEqual('abc', 'abd')).toBe(false);
    expect(safeEqual('abc', 'abcd')).toBe(false);
  });

  // Fapshi is for BizPilot subscriptions only: these all go through the subscription action.
  const ownerToken = async () => (await owner.client.auth.getSession()).data.session!.access_token;
  const subscribe = async (extra: Record<string, unknown> = {}, c: FapshiConfig = cfg, fx: typeof fetch = fetchMock) => {
    await sql(`delete from rate_limits where key like 'billing_pay:%'`);
    return handle(new Request(`${SUPABASE_URL}/functions/v1/fapshi`, { method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${await ownerToken()}` },
      body: JSON.stringify({ action: 'subscription', business_id: biz, plan_code: 'starter', period: 'monthly', ...extra }) }), c, fx) as Promise<JsonResponse>;
  };

  it('refuses order payments: marketplace buyers pay sellers directly', async () => {
    const tk = token();
    const res = await post({ action: 'order', order_id: uid(), token: tk });
    expect(res.status).toBe(410);
    expect((await res.json()).error).toBe('order_payments_direct');
    // And the database no longer accepts orders to be paid through BizPilot.
    await expect(placeOnline(tk)).rejects.toThrow(/invalid_payment_method/);
    expect(calls.filter((c) => c.path === '/initiate-pay' || c.path === '/direct-pay')).toEqual([]);
  });

  it('starts a hosted checkout with the amount from the database, not from the request', async () => {
    const res = await subscribe({ amount: 1 });
    expect(res.status).toBe(200);
    const out = await res.json();
    expect(out.link).toMatch(/^https:\/\/checkout\.fapshi\.test\//);
    const init = calls.filter((c) => c.path === '/initiate-pay').pop()!;
    expect(init.body.amount).toBe(1500);
    expect(init.body.externalId).toBe(out.payment_id);
    expect(init.body.redirectUrl).toBe(`https://shop.example/pay/return?p=${out.payment_id}`);
    expect(init.headers.apiuser).toBe('test-user');
  });

  it('webhook: requires the secret, re-checks the status with Fapshi and ignores the body’s claims', async () => {
    const { payment_id } = await (await subscribe({ plan_code: 'business' })).json();
    const [{ trans_id }] = await sql('select trans_id from online_payments where id = $1', [payment_id]);
    expect((await post({ transId: trans_id, status: 'SUCCESSFUL' }, { path: '/webhook' })).status).toBe(401);
    expect((await post({ transId: trans_id, status: 'SUCCESSFUL' }, { path: '/webhook', headers: { 'x-wh-secret': 'wrong' } })).status).toBe(401);
    // The body says SUCCESSFUL but Fapshi still reports PENDING: nothing is activated.
    tx.get(trans_id)!.status = 'PENDING';
    const r1 = await post({ transId: trans_id, status: 'SUCCESSFUL', amount: 3000 }, { path: '/webhook', headers: { 'x-wh-secret': SECRET } });
    expect(r1.status).toBe(200);
    expect(await sql(`select 1 from billing_payments where transaction_ref = $1`, [trans_id])).toEqual([]);
    tx.get(trans_id)!.status = 'SUCCESSFUL';
    await post({ transId: trans_id }, { path: '/webhook', headers: { 'x-wh-secret': SECRET } });
    const [sub] = await sql('select plan_code, status from business_subscriptions where business_id = $1', [biz]);
    expect(sub).toEqual({ plan_code: 'business', status: 'active' });
    // A duplicate notification changes nothing: one verified billing payment.
    await post({ transId: trans_id }, { path: '/webhook', headers: { 'x-wh-secret': SECRET } });
    expect(await sql(`select status, method from billing_payments where transaction_ref = $1`, [trans_id])).toEqual([{ status: 'verified', method: 'fapshi' }]);
    expect(await sql(`select status from online_payments where id = $1`, [payment_id])).toEqual([{ status: 'successful' }]);
  });

  it('verify (owner returned from checkout): reports a failed payment without activating anything', async () => {
    const first = await (await subscribe()).json();
    const [{ trans_id: t1 }] = await sql('select trans_id from online_payments where id = $1', [first.payment_id]);
    tx.get(t1)!.status = 'FAILED';
    const v = await (await post({ action: 'verify', payment_id: first.payment_id })).json();
    expect(v.status).toBe('failed');
    expect(await sql(`select 1 from billing_payments where transaction_ref = $1`, [t1])).toEqual([]);
    // Status checks are throttled per payment.
    const again = await (await post({ action: 'verify', payment_id: first.payment_id })).json();
    expect(again.status).toBeTruthy();
  });

  it('subscription payments need a signed-in owner; provider errors are reported without recording a transaction', async () => {
    expect((await post({ action: 'subscription', business_id: biz, plan_code: 'starter' })).status).toBe(401);
    const ok = await subscribe();
    expect(ok.status).toBe(200);
    expect(calls.filter((c) => c.path === '/initiate-pay').pop()!.body.amount).toBe(1500);
    const stranger = await createUser('fx-stranger');
    const { data: s2 } = await stranger.client.auth.getSession();
    const denied = await post({ action: 'subscription', business_id: biz, plan_code: 'starter' }, { auth: s2.session!.access_token });
    expect((await denied.json()).error).toBe('permission_denied');
    failInitiate = true;
    try {
      const before = (await sql(`select count(*)::int n from online_payments where business_id = $1 and trans_id is not null`, [biz]))[0].n;
      const r = await subscribe();
      expect(r.status).toBe(502);
      // The payer and the admin see Fapshi's actual reason: here, the API keys were rejected.
      expect(await r.json()).toMatchObject({ error: 'payment_provider_auth', details: JSON.stringify({ reason: 'Invalid API credentials' }) });
      const after = (await sql(`select count(*)::int n from online_payments where business_id = $1 and trans_id is not null`, [biz]))[0].n;
      expect(after).toBe(before);
      const [st] = await sql(`select value from app_config where key = 'fapshi_direct_pay'`);
      expect(st.value.last_error).toMatchObject({ where: 'initiate-pay', code: 'payment_provider_auth', http_status: 403, message: 'Invalid API credentials' });
    } finally { failInitiate = false; }
  });

  it('uses the sandbox for test keys and lets only administrators pay in test mode', async () => {
    const env = (base: string) => loadConfig((k) => ({ SUPABASE_URL, SUPABASE_ANON_KEY: ANON_KEY, SUPABASE_SERVICE_ROLE_KEY: SERVICE_KEY,
      FAPSHI_BASE_URL: base, FAPSHI_API_USER: ' u ', FAPSHI_API_KEY: 'FAK_TEST_abc', FAPSHI_WEBHOOK_SECRET: SECRET } as Record<string, string>)[k]);
    const live = env('https://live.fapshi.com/');
    expect(live).toMatchObject({ fapshiBase: 'https://sandbox.fapshi.com', sandbox: true, apiUser: 'u' });
    expect(loadConfig((k) => ({ FAPSHI_BASE_URL: 'https://live.fapshi.com', FAPSHI_API_KEY: 'FAK_live' } as Record<string, string>)[k]).sandbox).toBe(false);
    // Point the sandbox config at the simulated Fapshi.
    const sb = { ...cfg, sandbox: true };
    const notAdmin = await subscribe({ phone: '670000000' }, sb);
    expect(notAdmin.status).toBe(503);
    expect(((await notAdmin.json()) as any).error).toBe('online_payments_test_mode');
    await sql('insert into platform_admins (user_id) values ($1) on conflict do nothing', [owner.id]);
    try {
      const ok = (await (await subscribe({ phone: '670000000' }, sb)).json()) as any;
      expect(ok).toMatchObject({ mode: 'direct', test_mode: true });
    } finally { await sql('delete from platform_admins where user_id = $1', [owner.id]); }
  });

  it('reports an unreachable Fapshi address instead of crashing', async () => {
    const bad = { ...cfg, fapshiBase: 'https://fapshi.unreachable.invalid' };
    const failing: typeof fetch = async (input, init) => (String(input).startsWith(bad.fapshiBase) ? Promise.reject(new TypeError('fetch failed')) : fetch(input, init));
    const r = await subscribe({}, bad, failing);
    expect(r.status).toBe(502);
    expect(((await r.json()) as any).error).toBe('payment_provider_unreachable');
  });

  it('reads the new Supabase key format and normalises Cameroon phone numbers', () => {
    const c = loadConfig((k) => ({ SUPABASE_URL: 'x', SUPABASE_PUBLISHABLE_KEYS: '{"default":"sb_publishable_a"}', SUPABASE_SECRET_KEYS: '{"default":"sb_secret_b"}' } as Record<string, string>)[k]);
    expect(c.anonKey).toBe('sb_publishable_a');
    expect(c.serviceKey).toBe('sb_secret_b');
    expect(cmPhone('+237 670 00 00 00')).toBe('670000000');
    expect(cmPhone('690000000')).toBe('690000000');
    expect(cmPhone('12345')).toBeNull();
  });

  it('subscription by phone prompt: the owner approves on their phone and the plan activates automatically', async () => {
    const { data } = await owner.client.auth.getSession();
    const auth = data.session!.access_token;
    expect((await post({ action: 'subscription', business_id: biz, plan_code: 'business', period: 'monthly', phone: '123' }, { auth })).status).toBe(400);
    const res = await post({ action: 'subscription', business_id: biz, plan_code: 'business', period: 'monthly', phone: '+237 670 000 000', medium: 'mobile money' }, { auth });
    const out = await res.json();
    expect(out.mode).toBe('direct');
    const dp = calls.filter((c) => c.path === '/direct-pay').pop()!;
    expect(dp.body).toMatchObject({ amount: 3000, phone: '670000000', medium: 'mobile money', externalId: out.payment_id });
    // Still waiting while the owner has not approved.
    expect((await (await post({ action: 'verify', payment_id: out.payment_id })).json()).status).toBe('pending');
    const [{ trans_id }] = await sql('select trans_id from online_payments where id = $1', [out.payment_id]);
    tx.get(trans_id)!.status = 'SUCCESSFUL';
    await sql('update online_payments set last_checked_at = null where id = $1', [out.payment_id]);
    expect((await (await post({ action: 'verify', payment_id: out.payment_id })).json()).status).toBe('successful');
    const [sub] = await sql('select plan_code, status from business_subscriptions where business_id = $1', [biz]);
    expect(sub).toEqual({ plan_code: 'business', status: 'active' });
    const [bp] = await sql(`select status, method, amount from billing_payments where transaction_ref = $1`, [trans_id]);
    expect(bp).toMatchObject({ status: 'verified', method: 'fapshi' });
  });

  it('falls back to the Fapshi payment page when direct pay is not enabled on the service', async () => {
    const { data } = await owner.client.auth.getSession();
    directDisabled = true;
    try {
      const out = await (await post({ action: 'subscription', business_id: biz, plan_code: 'starter', period: 'monthly', phone: '690000000' }, { auth: data.session!.access_token })).json();
      expect(out.mode).toBe('link');
      expect(out.direct_failed).toBe(true);
      expect(out.link).toMatch(/^https:\/\/checkout\.fapshi\.test\//);
      expect(out.direct_error).toBe('Direct pay is not enabled for this service');
      // Fapshi's refusal is kept (privately) so administrators can see why phones got no request.
      const [row] = await sql(`select value, is_public from app_config where key = 'fapshi_direct_pay'`);
      expect(row).toMatchObject({ is_public: false, value: { ok: false, http_status: 403, message: 'Direct pay is not enabled for this service' } });
    } finally { directDisabled = false; }
  });

  it('shows the Fapshi balance to platform administrators only', async () => {
    const { data } = await owner.client.auth.getSession();
    expect((await post({ action: 'balance' }, { auth: data.session!.access_token })).status).toBe(403);
    const adm = await createUser('fx-admin');
    await sql('insert into platform_admins (user_id) values ($1)', [adm.id]);
    const { data: ad } = await adm.client.auth.getSession();
    expect(await (await post({ action: 'balance' }, { auth: ad.session!.access_token })).json()).toMatchObject({ service: 'BizPilot', balance: 123456, currency: 'XAF', live: true,
      direct_pay: { ok: false, message: 'Direct pay is not enabled for this service' } });
    // The status row is not readable by ordinary users.
    const { data: rows } = await owner.client.from('app_config').select('key').eq('key', 'fapshi_direct_pay');
    expect(rows ?? []).toEqual([]);
  });
});
