// Simulated Fapshi API + hosted checkout page for end-to-end tests (never used in production).
// POST /initiate-pay, GET /payment-status/:id, POST /expire-pay; GET /checkout/:id shows a page with
// "Pay" / "Fail" buttons that set the status, send the webhook and redirect like Fapshi does.
import http from 'node:http';
import { randomBytes } from 'node:crypto';

const PORT = Number(process.env.FAPSHI_MOCK_PORT ?? 4999);
const WEBHOOK = process.env.FAPSHI_MOCK_WEBHOOK ?? 'http://127.0.0.1:54321/functions/v1/fapshi/webhook';
const SECRET = process.env.FAPSHI_MOCK_SECRET ?? 'e2e-webhook-secret';
const PUBLIC = process.env.FAPSHI_MOCK_PUBLIC ?? `http://localhost:${PORT}`;
const tx = new Map();

const send = (res, code, body, type = 'application/json') => { res.writeHead(code, { 'Content-Type': type }); res.end(type === 'application/json' ? JSON.stringify(body) : body); };
const status = (id) => { const t = tx.get(id); return t && { transId: id, status: t.status, amount: t.amount, externalId: t.externalId, medium: 'mobile money', payerName: 'E2E Payer' }; };

http.createServer(async (req, res) => {
  let raw = ''; for await (const c of req) raw += c;
  const url = new URL(req.url, 'http://x');
  if (req.method === 'POST' && url.pathname === '/initiate-pay') {
    if (req.headers.apiuser !== 'e2e-user' || req.headers.apikey !== 'e2e-key') return send(res, 403, { message: 'Invalid API credentials' });
    const b = JSON.parse(raw || '{}');
    const id = 'e2e' + randomBytes(5).toString('hex');
    tx.set(id, { amount: b.amount, externalId: b.externalId, redirectUrl: b.redirectUrl, status: 'CREATED' });
    return send(res, 200, { message: 'Request successful', link: `${PUBLIC}/checkout/${id}`, transId: id, dateInitiated: new Date().toISOString() });
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
    await fetch(WEBHOOK, { method: 'POST', headers: { 'Content-Type': 'application/json', 'x-wh-secret': SECRET }, body: JSON.stringify(status(id)) }).catch(() => {});
    res.writeHead(302, { Location: t.redirectUrl }); return res.end();
  }
  if (url.pathname === '/__tx') return send(res, 200, Object.fromEntries(tx));
  send(res, 404, { message: 'not found' });
}).listen(PORT, () => console.log(`fapshi mock on ${PORT}`));
