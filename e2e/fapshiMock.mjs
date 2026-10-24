// Simulated Fapshi API + hosted checkout page for end-to-end tests (never used in production).
// POST /initiate-pay, POST /direct-pay, GET /payment-status/:id, POST /expire-pay, GET /balance;
// GET /checkout/:id shows a page with "Pay" / "Fail" buttons that set the status, send the webhook
// and redirect like Fapshi does. POST /__phone/:id/(pay|fail) plays the customer approving (or
// declining) a direct-pay request on their phone; POST /__direct/(on|off) toggles direct pay.
import http from 'node:http';
import { randomBytes } from 'node:crypto';

const PORT = Number(process.env.FAPSHI_MOCK_PORT ?? 4999);
const WEBHOOK = process.env.FAPSHI_MOCK_WEBHOOK ?? 'http://127.0.0.1:54321/functions/v1/fapshi/webhook';
const SECRET = process.env.FAPSHI_MOCK_SECRET ?? 'e2e-webhook-secret';
const PUBLIC = process.env.FAPSHI_MOCK_PUBLIC ?? `http://localhost:${PORT}`;
const tx = new Map();
let directEnabled = true;
const authed = (req) => req.headers.apiuser === 'e2e-user' && req.headers.apikey === 'e2e-key';
const webhook = (id) => fetch(WEBHOOK, { method: 'POST', headers: { 'Content-Type': 'application/json', 'x-wh-secret': SECRET }, body: JSON.stringify(status(id)) }).catch(() => {});

const send = (res, code, body, type = 'application/json') => { res.writeHead(code, { 'Content-Type': type }); res.end(type === 'application/json' ? JSON.stringify(body) : body); };
const status = (id) => { const t = tx.get(id); return t && { transId: id, status: t.status, amount: t.amount, externalId: t.externalId, medium: t.medium ?? 'mobile money', payerName: 'E2E Payer' }; };

http.createServer(async (req, res) => {
  let raw = ''; for await (const c of req) raw += c;
  const url = new URL(req.url, 'http://x');
  if (req.method === 'POST' && url.pathname === '/initiate-pay') {
    if (!authed(req)) return send(res, 403, { message: 'Invalid API credentials' });
    const b = JSON.parse(raw || '{}');
    const id = 'e2e' + randomBytes(5).toString('hex');
    tx.set(id, { amount: b.amount, externalId: b.externalId, redirectUrl: b.redirectUrl, status: 'CREATED' });
    return send(res, 200, { message: 'Request successful', link: `${PUBLIC}/checkout/${id}`, transId: id, dateInitiated: new Date().toISOString() });
  }
  if (req.method === 'POST' && url.pathname === '/direct-pay') {
    if (!authed(req)) return send(res, 403, { message: 'Invalid API credentials' });
    if (!directEnabled) return send(res, 403, { message: 'Direct pay is not enabled for this service' });
    const b = JSON.parse(raw || '{}');
    if (!/^6\d{8}$/.test(String(b.phone))) return send(res, 400, { message: 'Invalid phone' });
    const id = 'dp' + randomBytes(5).toString('hex');
    tx.set(id, { amount: b.amount, externalId: b.externalId, phone: b.phone, medium: b.medium, status: 'PENDING' });
    return send(res, 200, { message: 'Accepted', transId: id, dateInitiated: new Date().toISOString() });
  }
  if (req.method === 'GET' && url.pathname === '/balance') {
    if (!authed(req)) return send(res, 403, { message: 'Invalid API credentials' });
    const balance = [...tx.values()].filter((t) => t.status === 'SUCCESSFUL').reduce((s, t) => s + Number(t.amount), 0);
    return send(res, 200, { service: 'BizPilot E2E', balance, currency: 'XAF' });
  }
  if (req.method === 'POST' && /^\/__phone\/[^/]+\/(pay|fail)$/.test(url.pathname)) {
    const [, , id, action] = url.pathname.split('/'); const t = tx.get(id);
    if (!t) return send(res, 404, { message: 'not found' });
    t.status = action === 'pay' ? 'SUCCESSFUL' : 'FAILED';
    await webhook(id);
    return send(res, 200, status(id));
  }
  if (req.method === 'POST' && /^\/__direct\/(on|off)$/.test(url.pathname)) {
    directEnabled = url.pathname.endsWith('/on');
    return send(res, 200, { directEnabled });
  }
  if (req.method === 'GET' && url.pathname.startsWith('/payment-status/')) {
    const s = status(url.pathname.split('/').pop());
    return s ? send(res, 200, s) : send(res, 404, { message: 'not found' });
  }
  if (req.method === 'POST' && url.pathname === '/expire-pay') {
    const b = JSON.parse(raw || '{}'); const t = tx.get(b.transId);
    if (t && t.status !== 'SUCCESSFUL') t.status = 'EXPIRED';
    return send(res, 200, status(b.transId) ?? {});
  }
  if (req.method === 'GET' && url.pathname.startsWith('/checkout/')) {
    const id = url.pathname.split('/').pop(); const t = tx.get(id);
    if (!t) return send(res, 404, 'not found', 'text/plain');
    return send(res, 200, `<!doctype html><title>Fapshi test checkout</title><h1>Pay ${t.amount} XAF</h1>
      <form method="post" action="/checkout/${id}/pay"><button>Pay now</button></form>
      <form method="post" action="/checkout/${id}/fail"><button>Fail payment</button></form>`, 'text/html');
  }
  if (req.method === 'POST' && /^\/checkout\/[^/]+\/(pay|fail)$/.test(url.pathname)) {
    const [, , id, action] = url.pathname.split('/'); const t = tx.get(id);
    t.status = action === 'pay' ? 'SUCCESSFUL' : 'FAILED';
    // Like Fapshi: one webhook, then the browser goes back to the redirect URL.
    await webhook(id);
    res.writeHead(302, { Location: t.redirectUrl }); return res.end();
  }
  if (url.pathname === '/__tx') return send(res, 200, Object.fromEntries(tx));
  send(res, 404, { message: 'not found' });
}).listen(PORT, () => console.log(`fapshi mock on ${PORT}`));
