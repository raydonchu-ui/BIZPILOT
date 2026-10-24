// BizPilot online payments with Fapshi — Supabase Edge Function (Deno). No dependencies.
//
// POST {action: "order", order_id, token?, phone?, medium?}                  buyer pays an online order
// POST {action: "subscription", business_id, plan_code, period, phone?, medium?}   owner pays a plan period
//   With a phone number, Fapshi sends the payment request straight to that phone (direct pay): the
//   payer only approves the withdrawal on their MTN / Orange Money account. Without one (or when
//   direct pay is not enabled on the Fapshi service), a Fapshi hosted payment page is used instead.
// POST {action: "verify", payment_id}       asks Fapshi for the status (the app polls this while waiting)
// POST {action: "balance"}                  platform administrators: the Fapshi service balance
// POST .../fapshi/webhook                   Fapshi status notification (x-wh-secret header)
//
// Security:
//   * Fapshi credentials and the webhook secret are edge-function secrets; they never reach the browser.
//   * Amounts come from the database (market_payment_begin / billing_fapshi_begin run with the caller's
//     own credentials, so ownership and permissions are checked there), never from the request.
//   * A payment changes only through public.fapshi_apply (service role) with a status this function
//     fetched from Fapshi's API itself. Webhook bodies and browser redirects are never trusted:
//     a webhook only tells us which transaction to re-check.
//
// Secrets (Supabase → Edge Functions → Secrets): FAPSHI_API_USER, FAPSHI_API_KEY, FAPSHI_WEBHOOK_SECRET,
// FAPSHI_BASE_URL (https://sandbox.fapshi.com while testing, https://live.fapshi.com in production),
// SITE_URL (default https://www.bizpilotmarket.com). SUPABASE_URL, SUPABASE_ANON_KEY and
// SUPABASE_SERVICE_ROLE_KEY are provided by Supabase. Deploy with JWT verification OFF (the webhook has
// no Supabase token); every action authenticates the caller itself.

export interface FapshiConfig {
  supabaseUrl: string;
  anonKey: string;
  serviceKey: string;
  fapshiBase: string;
  apiUser: string;
  apiKey: string;
  webhookSecret: string;
  siteUrl: string;
  /** Fapshi sandbox (test keys): no real money moves and Fapshi approves test payments on its own. */
  sandbox: boolean;
}

type Fetch = typeof fetch;

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } });

/** Cameroon mobile number as Fapshi expects it (9 digits, e.g. 67XXXXXXX), or null. */
export function cmPhone(v: unknown) {
  let d = String(v ?? '').replace(/\D/g, '');
  if (d.length === 12 && d.startsWith('237')) d = d.slice(3);
  return /^6\d{8}$/.test(d) ? d : null;
}
const MEDIUMS = ['mobile money', 'orange money'];

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const TRANS = /^[A-Za-z0-9_-]{4,64}$/;
const EMAIL = /^[^@\s]+@[^@\s]+\.[^@\s]+$/;

// Supabase provides the legacy keys (SUPABASE_ANON_KEY / SUPABASE_SERVICE_ROLE_KEY) and, on projects
// using the new API keys, SUPABASE_PUBLISHABLE_KEYS / SUPABASE_SECRET_KEYS (JSON: {"default": "sb_…"}).
function pickKey(raw: string | undefined) {
  if (!raw) return '';
  const v = raw.trim();
  if (!v.startsWith('{')) return v;
  try { const o = JSON.parse(v) as Record<string, string>; return o.default ?? Object.values(o)[0] ?? ''; } catch { return ''; }
}

export function loadConfig(env: (k: string) => string | undefined): FapshiConfig {
  const apiKey = (env('FAPSHI_API_KEY') ?? '').trim();
  let fapshiBase = (env('FAPSHI_BASE_URL') ?? 'https://sandbox.fapshi.com').trim().replace(/\/+$/, '');
  // Test keys (FAK_TEST_…) only work on the sandbox: use it even if the live address was entered.
  const testKey = apiKey.startsWith('FAK_TEST_');
  if (testKey && /live\.fapshi\.com/.test(fapshiBase)) fapshiBase = 'https://sandbox.fapshi.com';
  return {
    sandbox: testKey || /sandbox\.fapshi\.com/.test(fapshiBase),
    supabaseUrl: env('SUPABASE_URL') ?? '',
    anonKey: pickKey(env('SUPABASE_ANON_KEY')) || pickKey(env('SUPABASE_PUBLISHABLE_KEYS')),
    serviceKey: pickKey(env('SUPABASE_SERVICE_ROLE_KEY')) || pickKey(env('SUPABASE_SECRET_KEYS')),
    fapshiBase,
    apiUser: (env('FAPSHI_API_USER') ?? '').trim(),
    apiKey,
    webhookSecret: env('FAPSHI_WEBHOOK_SECRET') ?? '',
    siteUrl: (env('SITE_URL') ?? 'https://www.bizpilotmarket.com').replace(/\/+$/, ''),
  };
}

/** Constant-time string comparison (webhook secret). */
export function safeEqual(a: string, b: string) {
  const x = new TextEncoder().encode(a);
  const y = new TextEncoder().encode(b);
  let diff = x.length ^ y.length;
  for (let i = 0; i < Math.max(x.length, y.length); i++) diff |= (x[i] ?? 0) ^ (y[i] ?? 0);
  return diff === 0;
}

function bearerToken(auth: string | null) {
  const m = /^Bearer\s+(.+)$/i.exec(auth ?? '');
  // Only a Supabase user JWT is forwarded; anything else (e.g. the public key) means "anonymous".
  return m && m[1].startsWith('eyJ') && m[1].split('.').length === 3 ? m[1] : null;
}

async function rpc(cfg: FapshiConfig, f: Fetch, fn: string, args: unknown, as: { user?: string | null; service?: boolean }) {
  const key = as.service ? cfg.serviceKey : cfg.anonKey;
  const headers: Record<string, string> = { apikey: key, 'Content-Type': 'application/json' };
  const bearer = as.service ? (key.startsWith('eyJ') ? key : null) : as.user;
  if (bearer) headers.Authorization = `Bearer ${bearer}`;
  const res = await f(`${cfg.supabaseUrl}/rest/v1/rpc/${fn}`, { method: 'POST', headers, body: JSON.stringify(args) });
  const text = await res.text();
  let body: any = null;
  try { body = text ? JSON.parse(text) : null; } catch { body = null; }
  if (!res.ok) return { data: null, error: { message: String(body?.message ?? `http_${res.status}`), details: body?.details ?? null } };
  return { data: body, error: null };
}

// The last answer Fapshi gave to a direct-pay request (accepted, or refused and why), kept in the
// private app_config row 'fapshi_direct_pay' so administrators can see whether phone requests work.
function serviceHeaders(cfg: FapshiConfig) {
  const h: Record<string, string> = { apikey: cfg.serviceKey, 'Content-Type': 'application/json' };
  if (cfg.serviceKey.startsWith('eyJ')) h.Authorization = `Bearer ${cfg.serviceKey}`;
  return h;
}
const cleanMessage = (m: unknown) => String(m ?? '').replace(/[^\p{L}\p{N}\s.,:;'()\/-]/gu, '').slice(0, 200);
async function saveDirectStatus(cfg: FapshiConfig, f: Fetch, value: Record<string, unknown>) {
  await f(`${cfg.supabaseUrl}/rest/v1/app_config?on_conflict=key`, {
    method: 'POST', headers: { ...serviceHeaders(cfg), Prefer: 'resolution=merge-duplicates,return=minimal' },
    body: JSON.stringify({ key: 'fapshi_direct_pay', value: { ...value, at: new Date().toISOString() }, is_public: false }),
  }).catch(() => null);
}
/** Fapshi's refusal as an error the app can explain: wrong keys, unreachable, or another reason. */
export function providerError(res: { status: number; data: any }) {
  const reason = cleanMessage(res.data?.message) || `HTTP ${res.status}`;
  const error = res.status === 0 ? 'payment_provider_unreachable'
    : res.status === 401 || res.status === 403 || /credential|api ?(user|key)|unauthori[sz]ed|forbidden|invalid key/i.test(reason) ? 'payment_provider_auth'
    : 'payment_provider_refused';
  return { error, reason, http_status: res.status };
}
async function saveLastError(cfg: FapshiConfig, f: Fetch, where: string, pe: ReturnType<typeof providerError>) {
  const cur = (await loadDirectStatus(cfg, f)) ?? {};
  await saveDirectStatus(cfg, f, { ...cur, last_error: { where, code: pe.error, http_status: pe.http_status, message: pe.reason, at: new Date().toISOString() } });
}
async function loadDirectStatus(cfg: FapshiConfig, f: Fetch) {
  const res = await f(`${cfg.supabaseUrl}/rest/v1/app_config?key=eq.fapshi_direct_pay&select=value`, { headers: serviceHeaders(cfg) }).catch(() => null);
  if (!res?.ok) return null;
  const rows = await res.json().catch(() => []);
  return Array.isArray(rows) && rows[0] ? rows[0].value : null;
}

async function fapshi(cfg: FapshiConfig, f: Fetch, method: 'GET' | 'POST', path: string, body?: unknown) {
  let res: Response;
  try {
    res = await f(`${cfg.fapshiBase}${path}`, {
      method,
      headers: { apiuser: cfg.apiUser, apikey: cfg.apiKey, ...(body ? { 'Content-Type': 'application/json' } : {}) },
      ...(body ? { body: JSON.stringify(body) } : {}),
    });
  } catch (e) {
    // Wrong FAPSHI_BASE_URL, DNS or network failure: report it instead of crashing.
    return { ok: false, status: 0, data: { message: `cannot reach ${cfg.fapshiBase}: ${String((e as Error)?.message ?? e).slice(0, 120)}` } as any };
  }
  let data: any = null;
  try { data = await res.json(); } catch { data = null; }
  return { ok: res.ok, status: res.status, data };
}

/** Fetches the authoritative status from Fapshi and records it. */
async function refresh(cfg: FapshiConfig, f: Fetch, transId: string) {
  const st = await fapshi(cfg, f, 'GET', `/payment-status/${encodeURIComponent(transId)}`);
  if (!st.ok || !st.data || st.data.transId !== transId) return { error: 'status_unavailable' as const };
  const applied = await rpc(cfg, f, 'fapshi_apply', { p_trans_id: transId, p_tx: {
    status: st.data.status, amount: st.data.amount, externalId: st.data.externalId, medium: st.data.medium,
    payerName: st.data.payerName, financialTransId: st.data.financialTransId, revenue: st.data.revenue,
  } }, { service: true });
  if (applied.error) return { error: 'apply_failed' as const };
  return { result: applied.data };
}

async function startPayment(cfg: FapshiConfig, f: Fetch, begin: any, direct?: { phone: string; medium?: string; name?: string }) {
  // Close earlier unpaid links of the same order so only one can be paid (best effort).
  for (const prev of (begin.previous ?? []) as string[]) {
    if (!TRANS.test(prev)) continue;
    await fapshi(cfg, f, 'POST', '/expire-pay', { transId: prev }).catch(() => null);
    await refresh(cfg, f, prev).catch(() => null);
  }
  const amount = Number(begin.amount);
  if (!Number.isInteger(amount) || amount < 100) return json({ error: 'online_minimum_amount' }, 400);
  let directError = '';
  const common = {
    ...(begin.email && EMAIL.test(begin.email) ? { email: begin.email } : {}),
    userId: String(begin.user_id ?? '').replace(/[^A-Za-z0-9_-]/g, '').slice(0, 100) || undefined,
    externalId: begin.payment_id,
    message: String(begin.message ?? 'BizPilot').slice(0, 120),
  };
  if (direct) {
    // The request appears on the payer's phone; they approve it with their Mobile Money PIN.
    const dp = await fapshi(cfg, f, 'POST', '/direct-pay', {
      amount, phone: direct.phone, ...(direct.medium ? { medium: direct.medium } : {}),
      ...(direct.name ? { name: direct.name.slice(0, 80) } : {}), ...common,
    });
    if (dp.ok && TRANS.test(String(dp.data?.transId ?? ''))) {
      const att = await rpc(cfg, f, 'fapshi_attach', { p_payment: begin.payment_id, p_trans_id: dp.data.transId, p_link: null }, { service: true });
      if (att.error) return json({ error: 'payment_record_failed' }, 500);
      await saveDirectStatus(cfg, f, { ok: true });
      return json({ mode: 'direct', payment_id: begin.payment_id, amount, test_mode: cfg.sandbox });
    }
    // Direct pay refused (Fapshi disables it on live services until its support activates it):
    // fall back to the payment page and keep Fapshi's reason for the administrators.
    directError = cleanMessage(dp.data?.message) || `http_${dp.status}`;
    console.error('fapshi direct-pay failed', dp.status, directError);
    await saveDirectStatus(cfg, f, { ok: false, http_status: dp.status, message: directError });
  }
  const init = await fapshi(cfg, f, 'POST', '/initiate-pay', {
    amount, redirectUrl: `${cfg.siteUrl}${begin.return_path}`, ...common,
  });
  if (!init.ok || !init.data?.link || !TRANS.test(String(init.data?.transId ?? ''))) {
    const pe = init.ok ? { error: 'payment_provider_refused', reason: 'no payment link returned', http_status: init.status } : providerError(init);
    console.error('fapshi initiate-pay failed', init.status, pe.reason);
    await saveLastError(cfg, f, 'initiate-pay', pe);
    return json({ error: pe.error, details: JSON.stringify({ reason: pe.reason }), ...(directError ? { direct_error: directError } : {}) }, 502);
  }
  const attached = await rpc(cfg, f, 'fapshi_attach', { p_payment: begin.payment_id, p_trans_id: init.data.transId, p_link: init.data.link },
    { service: true });
  if (attached.error) return json({ error: 'payment_record_failed' }, 500);
  return json({ mode: 'link', link: init.data.link, payment_id: begin.payment_id, direct_failed: Boolean(direct), test_mode: cfg.sandbox, ...(directError ? { direct_error: directError } : {}) });
}

function directOptions(body: any) {
  if (body?.phone === undefined || body?.phone === null || body?.phone === '') return { ok: true as const, direct: undefined };
  const phone = cmPhone(body.phone);
  if (!phone) return { ok: false as const };
  const medium = MEDIUMS.includes(body.medium) ? body.medium : undefined;
  return { ok: true as const, direct: { phone, medium, name: typeof body.name === 'string' ? body.name : undefined } };
}

export async function handle(req: Request, cfg: FapshiConfig, f: Fetch = fetch): Promise<Response> {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (req.method !== 'POST') return json({ error: 'method_not_allowed' }, 405);
  if (!cfg.supabaseUrl || !cfg.serviceKey || !cfg.anonKey) return json({ error: 'not_configured' }, 503);
  const url = new URL(req.url);

  if (url.pathname.endsWith('/webhook')) {
    // Fapshi sends each event once and does not retry; always answer quickly.
    if (!cfg.webhookSecret || !safeEqual(req.headers.get('x-wh-secret') ?? '', cfg.webhookSecret)) {
      return json({ error: 'unauthorized' }, 401);
    }
    let body: any;
    try { body = await req.json(); } catch { return json({ ok: false, error: 'invalid_body' }, 400); }
    const transId = String(body?.transId ?? '');
    if (!TRANS.test(transId)) return json({ ok: false, error: 'invalid_transaction' }, 400);
    const r = await refresh(cfg, f, transId);
    return json({ ok: !('error' in r), ...(('error' in r) ? { error: r.error } : {}) });
  }

  if (!cfg.apiUser || !cfg.apiKey) return json({ error: 'online_payments_not_available' }, 503);
  let body: any;
  try { body = await req.json(); } catch { return json({ error: 'invalid_request' }, 400); }
  const user = bearerToken(req.headers.get('Authorization'));

  // With sandbox keys Fapshi approves payments without taking any money, so only platform
  // administrators may start one (to test); customers are told online payment is not available.
  if (cfg.sandbox && (body?.action === 'order' || body?.action === 'subscription')) {
    const admin = user ? await rpc(cfg, f, 'admin_market_overview', {}, { user }) : null;
    if (!admin || admin.error) return json({ error: 'online_payments_test_mode' }, 503);
  }

  if (body?.action === 'order') {
    if (!UUID.test(String(body.order_id ?? ''))) return json({ error: 'invalid_request' }, 400);
    const token = typeof body.token === 'string' && body.token.length <= 128 ? body.token : null;
    const d = directOptions(body);
    if (!d.ok) return json({ error: 'invalid_phone' }, 400);
    const begin = await rpc(cfg, f, 'market_payment_begin', { p_order: body.order_id, p_token: token }, { user });
    if (begin.error) return json({ error: begin.error.message, details: begin.error.details }, 400);
    return startPayment(cfg, f, begin.data, d.direct);
  }

  if (body?.action === 'subscription') {
    if (!user) return json({ error: 'not_authenticated' }, 401);
    if (!UUID.test(String(body.business_id ?? ''))) return json({ error: 'invalid_request' }, 400);
    const d = directOptions(body);
    if (!d.ok) return json({ error: 'invalid_phone' }, 400);
    const begin = await rpc(cfg, f, 'billing_fapshi_begin',
      { p_business: body.business_id, p_plan: String(body.plan_code ?? ''), p_period: body.period === 'annual' ? 'annual' : 'monthly' }, { user });
    if (begin.error) return json({ error: begin.error.message, details: begin.error.details }, 400);
    return startPayment(cfg, f, begin.data, d.direct);
  }

  if (body?.action === 'balance') {
    // Only platform administrators (checked by the database with the caller's own token).
    if (!user) return json({ error: 'not_authenticated' }, 401);
    const check = await rpc(cfg, f, 'admin_market_overview', {}, { user });
    if (check.error) return json({ error: 'permission_denied' }, 403);
    const bal = await fapshi(cfg, f, 'GET', '/balance');
    if (!bal.ok) {
      const pe = providerError(bal);
      console.error('fapshi balance failed', bal.status, pe.reason);
      return json({ error: pe.error, details: JSON.stringify({ reason: pe.reason }) }, 502);
    }
    return json({ service: bal.data?.service ?? null, balance: Number(bal.data?.balance ?? 0), currency: bal.data?.currency ?? 'XAF',
      live: !cfg.sandbox, direct_pay: await loadDirectStatus(cfg, f) });
  }

  if (body?.action === 'verify') {
    if (!UUID.test(String(body.payment_id ?? ''))) return json({ error: 'invalid_request' }, 400);
    const look = await rpc(cfg, f, 'fapshi_payment_lookup', { p_payment: body.payment_id }, { service: true });
    if (look.error || !look.data) return json({ error: 'not_found' }, 404);
    const p = look.data;
    if (p.trans_id && !p.throttled && !['successful', 'failed', 'expired'].includes(p.status)) {
      await refresh(cfg, f, p.trans_id);
    }
    const st = await rpc(cfg, f, 'online_payment_status', { p_payment: body.payment_id }, { user });
    if (st.error || !st.data) return json({ error: 'not_found' }, 404);
    return json(st.data);
  }

  return json({ error: 'invalid_request' }, 400);
}

// deno-lint-ignore no-explicit-any
const D = (globalThis as any).Deno;
if (D?.serve) {
  const cfg = loadConfig((k) => D.env.get(k));
  D.serve(async (req: Request) => {
    try { return await handle(req, cfg); } catch (e) {
      console.error('fapshi function error', String((e as Error)?.stack ?? e).slice(0, 500));
      return json({ error: 'internal_error' }, 500);
    }
  });
}
