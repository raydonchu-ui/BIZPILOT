// BizPilot online payments with Fapshi — Supabase Edge Function (Deno). No dependencies.
//
// POST {action: "order", order_id, token?}          buyer starts paying an online order
// POST {action: "subscription", business_id, plan_code, period}   owner pays a subscription period
// POST {action: "verify", payment_id}                 asks Fapshi for the status (after the buyer returns)
// POST .../fapshi/webhook                             Fapshi status notification (x-wh-secret header)
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
}

type Fetch = typeof fetch;

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } });

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const TRANS = /^[A-Za-z0-9_-]{4,64}$/;
const EMAIL = /^[^@\s]+@[^@\s]+\.[^@\s]+$/;

export function loadConfig(env: (k: string) => string | undefined): FapshiConfig {
  return {
    supabaseUrl: env('SUPABASE_URL') ?? '',
    anonKey: env('SUPABASE_ANON_KEY') ?? '',
    serviceKey: env('SUPABASE_SERVICE_ROLE_KEY') ?? '',
    fapshiBase: (env('FAPSHI_BASE_URL') ?? 'https://sandbox.fapshi.com').replace(/\/+$/, ''),
    apiUser: env('FAPSHI_API_USER') ?? '',
    apiKey: env('FAPSHI_API_KEY') ?? '',
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

async function fapshi(cfg: FapshiConfig, f: Fetch, method: 'GET' | 'POST', path: string, body?: unknown) {
  const res = await f(`${cfg.fapshiBase}${path}`, {
    method,
    headers: { apiuser: cfg.apiUser, apikey: cfg.apiKey, ...(body ? { 'Content-Type': 'application/json' } : {}) },
    ...(body ? { body: JSON.stringify(body) } : {}),
  });
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

async function startPayment(cfg: FapshiConfig, f: Fetch, begin: any) {
  // Close earlier unpaid links of the same order so only one can be paid (best effort).
  for (const prev of (begin.previous ?? []) as string[]) {
    if (!TRANS.test(prev)) continue;
    await fapshi(cfg, f, 'POST', '/expire-pay', { transId: prev }).catch(() => null);
    await refresh(cfg, f, prev).catch(() => null);
  }
  const amount = Number(begin.amount);
  if (!Number.isInteger(amount) || amount < 100) return json({ error: 'online_minimum_amount' }, 400);
  const init = await fapshi(cfg, f, 'POST', '/initiate-pay', {
    amount,
    ...(begin.email && EMAIL.test(begin.email) ? { email: begin.email } : {}),
    redirectUrl: `${cfg.siteUrl}${begin.return_path}`,
    userId: String(begin.user_id ?? '').replace(/[^A-Za-z0-9_-]/g, '').slice(0, 100) || undefined,
    externalId: begin.payment_id,
    message: String(begin.message ?? 'BizPilot').slice(0, 120),
  });
  if (!init.ok || !init.data?.link || !TRANS.test(String(init.data?.transId ?? ''))) {
    console.error('fapshi initiate-pay failed', init.status, init.data?.message ?? '');
    return json({ error: 'payment_provider_error', provider_message: init.data?.message ?? null }, 502);
  }
  const attached = await rpc(cfg, f, 'fapshi_attach', { p_payment: begin.payment_id, p_trans_id: init.data.transId, p_link: init.data.link },
    { service: true });
  if (attached.error) return json({ error: 'payment_record_failed' }, 500);
  return json({ link: init.data.link, payment_id: begin.payment_id });
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

  if (body?.action === 'order') {
    if (!UUID.test(String(body.order_id ?? ''))) return json({ error: 'invalid_request' }, 400);
    const token = typeof body.token === 'string' && body.token.length <= 128 ? body.token : null;
    const begin = await rpc(cfg, f, 'market_payment_begin', { p_order: body.order_id, p_token: token }, { user });
    if (begin.error) return json({ error: begin.error.message, details: begin.error.details }, 400);
    return startPayment(cfg, f, begin.data);
  }

  if (body?.action === 'subscription') {
    if (!user) return json({ error: 'not_authenticated' }, 401);
    if (!UUID.test(String(body.business_id ?? ''))) return json({ error: 'invalid_request' }, 400);
    const begin = await rpc(cfg, f, 'billing_fapshi_begin',
      { p_business: body.business_id, p_plan: String(body.plan_code ?? ''), p_period: body.period === 'annual' ? 'annual' : 'monthly' }, { user });
    if (begin.error) return json({ error: begin.error.message, details: begin.error.details }, 400);
    return startPayment(cfg, f, begin.data);
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
  D.serve((req: Request) => handle(req, cfg));
}
