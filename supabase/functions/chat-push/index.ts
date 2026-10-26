// BizPilot messages: background push for a new chat message. Supabase Edge Function (Deno).
// No npm dependencies: Web Push encryption (RFC 8291, aes128gcm) and VAPID (RFC 8292) use Web Crypto,
// and the database is read through PostgREST, as the fapshi function does.
//
// POST {message_id}   the app asks for a message to be pushed right after the sender stored it.
//   * The caller's own token decides what it may see, and the message must be one the caller wrote, so
//     nobody can make the app push someone else's message.
//   * Recipients come from the inbox rows the database wrote when the message was stored, never from the
//     request. A device receives a push only if its user has a row for this message and a subscription.
//   * Subscriptions the push service reports as gone (404/410) are removed.
//
// Secrets (Supabase → Edge Functions → Secrets): VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY (base64url, as
// generated for Web Push), VAPID_SUBJECT (a mailto: address). Without them nothing is sent and the response
// says push_not_configured, so the in-app notifications keep working. SUPABASE_URL, SUPABASE_ANON_KEY and
// SUPABASE_SERVICE_ROLE_KEY are provided by Supabase. Deploy with JWT verification on (the default): the
// app calls it with the signed-in user's token.

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } });

const enc = new TextEncoder();

function b64uToBytes(s: string): Uint8Array {
  const pad = '='.repeat((4 - (s.length % 4)) % 4);
  const bin = atob(s.replace(/-/g, '+').replace(/_/g, '/') + pad);
  return Uint8Array.from(bin, (c) => c.charCodeAt(0));
}

function bytesToB64u(b: Uint8Array): string {
  let bin = '';
  for (const x of b) bin += String.fromCharCode(x);
  return btoa(bin).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

function concat(...parts: Uint8Array[]): Uint8Array {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let o = 0;
  for (const p of parts) { out.set(p, o); o += p.length; }
  return out;
}

async function hmac(key: Uint8Array, data: Uint8Array): Promise<Uint8Array> {
  const k = await crypto.subtle.importKey('raw', key, { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  return new Uint8Array(await crypto.subtle.sign('HMAC', k, data));
}

/** HKDF for outputs of at most 32 bytes (one block): every key this file derives is that short. */
async function hkdf(salt: Uint8Array, ikm: Uint8Array, info: Uint8Array, length: number): Promise<Uint8Array> {
  const prk = await hmac(salt, ikm);
  const okm = await hmac(prk, concat(info, new Uint8Array([1])));
  return okm.slice(0, length);
}

/** Encrypts one push message for a subscription (RFC 8291 key agreement, aes128gcm record). */
async function encryptPayload(p256dh: string, authSecret: string, plaintext: Uint8Array): Promise<Uint8Array> {
  const uaPublic = b64uToBytes(p256dh);
  const uaAuth = b64uToBytes(authSecret);
  const ephemeral = await crypto.subtle.generateKey({ name: 'ECDH', namedCurve: 'P-256' }, true, ['deriveBits']);
  const asPublic = new Uint8Array(await crypto.subtle.exportKey('raw', ephemeral.publicKey));
  const uaKey = await crypto.subtle.importKey('raw', uaPublic, { name: 'ECDH', namedCurve: 'P-256' }, false, []);
  const shared = new Uint8Array(await crypto.subtle.deriveBits({ name: 'ECDH', public: uaKey }, ephemeral.privateKey, 256));
  const ikm = await hkdf(uaAuth, shared, concat(enc.encode('WebPush: info\0'), uaPublic, asPublic), 32);
  const salt = crypto.getRandomValues(new Uint8Array(16));
  const cek = await hkdf(salt, ikm, enc.encode('Content-Encoding: aes128gcm\0'), 16);
  const nonce = await hkdf(salt, ikm, enc.encode('Content-Encoding: nonce\0'), 12);
  const key = await crypto.subtle.importKey('raw', cek, { name: 'AES-GCM' }, false, ['encrypt']);
  // 0x02 marks the last (and only) record.
  const ciphertext = new Uint8Array(await crypto.subtle.encrypt({ name: 'AES-GCM', iv: nonce }, key, concat(plaintext, new Uint8Array([2]))));
  const recordSize = new Uint8Array([0, 0, 16, 0]); // 4096 bytes
  return concat(salt, recordSize, new Uint8Array([asPublic.length]), asPublic, ciphertext);
}

/** The VAPID token that proves this server may push to one push service (ES256 JWT). */
async function vapidToken(endpoint: string, publicKey: string, privateKey: string, subject: string): Promise<string> {
  const header = bytesToB64u(enc.encode(JSON.stringify({ typ: 'JWT', alg: 'ES256' })));
  const claims = bytesToB64u(enc.encode(JSON.stringify({
    aud: new URL(endpoint).origin, exp: Math.floor(Date.now() / 1000) + 12 * 3600, sub: subject,
  })));
  const pub = b64uToBytes(publicKey);
  const key = await crypto.subtle.importKey('jwk', {
    kty: 'EC', crv: 'P-256', d: privateKey, x: bytesToB64u(pub.slice(1, 33)), y: bytesToB64u(pub.slice(33, 65)), ext: true,
  }, { name: 'ECDSA', namedCurve: 'P-256' }, false, ['sign']);
  const sig = new Uint8Array(await crypto.subtle.sign({ name: 'ECDSA', hash: 'SHA-256' }, key, enc.encode(`${header}.${claims}`)));
  return `${header}.${claims}.${bytesToB64u(sig)}`;
}

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (req.method !== 'POST') return json({ error: 'method_not_allowed' }, 405);

  const body = await req.json().catch(() => ({}));
  const messageId = typeof body?.message_id === 'string' ? body.message_id : '';
  if (!/^[0-9a-f-]{36}$/i.test(messageId)) return json({ error: 'bad_request' }, 400);

  const url = Deno.env.get('SUPABASE_URL') ?? '';
  const anonKey = Deno.env.get('SUPABASE_ANON_KEY') ?? '';
  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
  const authorization = req.headers.get('Authorization') ?? '';
  if (!authorization) return json({ error: 'not_authenticated' }, 401);

  // Who is calling: the user's own token, checked by Supabase Auth.
  const who = await fetch(`${url}/auth/v1/user`, { headers: { apikey: anonKey, Authorization: authorization } });
  if (!who.ok) return json({ error: 'not_authenticated' }, 401);
  const caller = (await who.json()) as { id?: string };

  // The message must be one the caller wrote; row level security decides what the caller can see.
  const mine = await fetch(`${url}/rest/v1/messages?id=eq.${messageId}&select=id,sender_id`, {
    headers: { apikey: anonKey, Authorization: authorization, Accept: 'application/json' },
  });
  const [message] = mine.ok ? ((await mine.json()) as { id: string; sender_id: string }[]) : [];
  if (!message || message.sender_id !== caller.id) return json({ error: 'not_found' }, 404);

  const publicKey = Deno.env.get('VAPID_PUBLIC_KEY') ?? '';
  const privateKey = Deno.env.get('VAPID_PRIVATE_KEY') ?? '';
  const subject = Deno.env.get('VAPID_SUBJECT') ?? '';
  if (!publicKey || !privateKey || !subject) return json({ sent: 0, skipped: 'push_not_configured' });

  const service = { apikey: serviceKey, Authorization: `Bearer ${serviceKey}`, Accept: 'application/json' };
  const inbox = await fetch(`${url}/rest/v1/inbox_notifications?message_id=eq.${messageId}&select=user_id,from_name,preview,link,conversation_id`, { headers: service });
  const rows = inbox.ok ? ((await inbox.json()) as { user_id: string; from_name: string; preview: string; link: string; conversation_id: string }[]) : [];
  const byUser = new Map(rows.map((r) => [r.user_id, r]));
  if (byUser.size === 0) return json({ sent: 0, removed: 0, failed: 0 });

  const ids = [...byUser.keys()].join(',');
  const subsRes = await fetch(`${url}/rest/v1/push_subscriptions?user_id=in.(${ids})&select=id,user_id,endpoint,p256dh,auth`, { headers: service });
  const subs = subsRes.ok ? ((await subsRes.json()) as { id: string; user_id: string; endpoint: string; p256dh: string; auth: string }[]) : [];

  let sent = 0;
  let removed = 0;
  let failed = 0;
  await Promise.all(subs.map(async (s) => {
    const row = byUser.get(s.user_id);
    if (!row) return;
    const payload = enc.encode(JSON.stringify({ title: row.from_name, body: row.preview, url: row.link, tag: row.conversation_id }));
    try {
      const res = await fetch(s.endpoint, {
        method: 'POST',
        headers: {
          TTL: '3600',
          'Content-Encoding': 'aes128gcm',
          'Content-Type': 'application/octet-stream',
          Authorization: `vapid t=${await vapidToken(s.endpoint, publicKey, privateKey, subject)}, k=${publicKey}`,
        },
        body: await encryptPayload(s.p256dh, s.auth, payload),
      });
      if (res.status === 404 || res.status === 410) {
        await fetch(`${url}/rest/v1/push_subscriptions?id=eq.${s.id}`, { method: 'DELETE', headers: service });
        removed++;
      } else if (res.ok) {
        sent++;
      } else {
        failed++;
      }
    } catch {
      failed++;
    }
  }));
  return json({ sent, removed, failed });
});
