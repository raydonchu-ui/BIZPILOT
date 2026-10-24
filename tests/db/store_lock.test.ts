import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { createClient, type SupabaseClient } from '@supabase/supabase-js';
import { createHmac } from 'node:crypto';
import { addProduct, addStaff, ANON_KEY, closeDb, createBusiness, createUser, expectError, openStock, rpc, sell, sql, SUPABASE_URL, type TestUser } from './helpers';

const PASSWORD = 'Test-password-123!'; // createUser's password
const JWT_SECRET = process.env.TEST_JWT_SECRET ?? 'super-secret-jwt-token-with-at-least-32-characters-long'; // local demo secret
const opts = { auth: { persistSession: false, autoRefreshToken: false } };

async function signIn(email: string): Promise<SupabaseClient> {
  const c = createClient(SUPABASE_URL, ANON_KEY, opts);
  const { error } = await c.auth.signInWithPassword({ email, password: PASSWORD });
  if (error) throw error;
  return c;
}
async function sessionId(c: SupabaseClient) {
  const { data } = await c.auth.getSession();
  return JSON.parse(Buffer.from(data.session!.access_token.split('.')[1], 'base64url').toString()).session_id as string;
}
// A token for an existing session whose last sign-in was long ago (for the "fresh login" rule).
function staleLoginClient(userId: string, sid: string) {
  const b64 = (o: object) => Buffer.from(JSON.stringify(o)).toString('base64url');
  const now = Math.floor(Date.now() / 1000);
  const head = b64({ alg: 'HS256', typ: 'JWT' });
  const body = b64({ sub: userId, role: 'authenticated', aud: 'authenticated', session_id: sid, iat: now, exp: now + 600,
    aal: 'aal1', amr: [{ method: 'password', timestamp: now - 3600 }] });
  const sig = createHmac('sha256', JWT_SECRET).update(`${head}.${body}`).digest('base64url');
  return createClient(SUPABASE_URL, ANON_KEY, { ...opts, global: { headers: { Authorization: `Bearer ${head}.${body}.${sig}` } } });
}
const status = (c: SupabaseClient) => rpc<any>(c, 'store_lock_status');

describe('Store Lock PIN (server-enforced)', () => {
  let owner: TestUser; let biz: string; let productId: string;
  beforeAll(async () => {
    owner = await createUser('lock-owner');
    biz = await createBusiness(owner, 'Locked Shop');
    productId = (await addProduct(owner, biz, { name: 'Soap', selling_price: 500 })).id;
    await openStock(owner, biz, productId, 10, 300);
  });
  afterAll(closeDb);

  it('has no effect until a PIN is created; weak PINs are refused; the PIN is stored only as a bcrypt hash', async () => {
    expect(await status(owner.client)).toEqual({ has_pin: false, locked: false });
    await expectError(rpc(owner.client, 'lock_store'), 'pin_not_set');
    for (const weak of ['1234', '0000', '9999', '4321', '12a4', '123', '12345', '']) {
      await expectError(rpc(owner.client, 'set_store_pin', { p_pin: weak }), 'pin_too_simple');
    }
    const s = await rpc<any>(owner.client, 'set_store_pin', { p_pin: '2580' });
    expect(s).toMatchObject({ has_pin: true, locked: false, idle_minutes: 15 });
    await expectError(rpc(owner.client, 'set_store_pin', { p_pin: '1357' }), 'pin_already_set');

    const [row] = await sql(`select pin_hash from app.store_pins where user_id = $1`, [owner.id]);
    expect(row.pin_hash).toMatch(/^\$2[aby]\$10\$/);
    expect(row.pin_hash).not.toContain('2580');
    const { error } = await owner.client.from('store_pins').select('*');
    expect(error).not.toBeNull(); // not reachable through the API
    const [logs] = await sql(`select count(*)::int n from audit_logs where user_id = $1 and details::text like '%2580%'`, [owner.id]);
    expect(logs.n).toBe(0);
  });

  it('a locked session cannot read or change business data until unlocked', async () => {
    expect((await rpc<any>(owner.client, 'lock_store')).locked).toBe(true);
    const { data: products } = await owner.client.from('products').select('id').eq('business_id', biz);
    expect(products).toEqual([]);
    const { data: businesses } = await owner.client.from('businesses').select('id');
    expect(businesses).toEqual([]);
    await expectError(rpc(owner.client, 'get_my_context'), 'store_locked');
    await expectError(rpc(owner.client, 'dashboard_summary', { p_business: biz, p_from: '2026-01-01', p_to: '2026-12-31' }), 'store_locked');
    await expectError(sell(owner, biz, [{ product_id: productId, quantity: 1 }], { payments: [{ method: 'cash', amount: 500 }] }), 'store_locked');
    const { error: upd } = await owner.client.from('products').update({ selling_price: 1 }).eq('id', productId).select('id').single();
    expect(upd).not.toBeNull();
    const { data: files } = await owner.client.storage.from('business-files').list(`${biz}/products`);
    expect(files ?? []).toEqual([]);
    const [p] = await sql(`select selling_price from products where id = $1`, [productId]);
    expect(Number(p.selling_price)).toBe(500);

    const wrong = await rpc<any>(owner.client, 'unlock_store', { p_pin: '1111' });
    expect(wrong).toMatchObject({ ok: false, error: 'wrong_pin', attempts_left: 4 });
    expect((await status(owner.client)).locked).toBe(true);
    const right = await rpc<any>(owner.client, 'unlock_store', { p_pin: '2580' });
    expect(right.ok).toBe(true);
    expect(right.status.locked).toBe(false);
    const { data: again } = await owner.client.from('products').select('id').eq('business_id', biz);
    expect(again).toHaveLength(1);
    await sell(owner, biz, [{ product_id: productId, quantity: 1 }], { payments: [{ method: 'cash', amount: 500 }] });
  });

  it('repeated wrong PINs cause growing waits; the right PIN is refused during a wait', async () => {
    await rpc(owner.client, 'lock_store');
    const results = [];
    for (let i = 0; i < 5; i++) results.push(await rpc<any>(owner.client, 'unlock_store', { p_pin: '0101' }));
    expect(results.slice(0, 4).map((r) => r.error)).toEqual(['wrong_pin', 'wrong_pin', 'wrong_pin', 'wrong_pin']);
    expect(results[4]).toMatchObject({ ok: false, error: 'pin_temporarily_locked', retry_after: 30 });
    const during = await rpc<any>(owner.client, 'unlock_store', { p_pin: '2580' });
    expect(during).toMatchObject({ ok: false, error: 'pin_temporarily_locked' });
    expect(during.retry_after).toBeGreaterThan(0);
    // Next mistake after the wait doubles it.
    await sql(`update app.store_pins set locked_until = now() - interval '1 second' where user_id = $1`, [owner.id]);
    expect(await rpc<any>(owner.client, 'unlock_store', { p_pin: '0101' })).toMatchObject({ error: 'pin_temporarily_locked', retry_after: 60 });
    await sql(`update app.store_pins set locked_until = now() - interval '1 second' where user_id = $1`, [owner.id]);
    expect((await rpc<any>(owner.client, 'unlock_store', { p_pin: '2580' })).ok).toBe(true);
    const [row] = await sql(`select failed_attempts from app.store_pins where user_id = $1`, [owner.id]);
    expect(row.failed_attempts).toBe(0);
    const [audit] = await sql(`select count(*)::int n from audit_logs where user_id = $1 and action = 'store_lock.too_many_attempts'`, [owner.id]);
    expect(audit.n).toBeGreaterThanOrEqual(2);
  });

  it('a new sign-in starts locked; each device/session is locked and unlocked separately', async () => {
    const second = await signIn(owner.email);
    expect(await sessionId(second)).not.toBe(await sessionId(owner.client));
    expect(await status(second)).toMatchObject({ locked: true, reason: 'new_session' });
    const { data } = await second.from('products').select('id').eq('business_id', biz);
    expect(data).toEqual([]);
    expect((await status(owner.client)).locked).toBe(false); // first device unaffected
    expect((await rpc<any>(second, 'unlock_store', { p_pin: '2580' })).ok).toBe(true);
    await rpc(second, 'lock_store');
    expect((await status(owner.client)).locked).toBe(false);
    await second.auth.signOut();
  });

  it('locks after the chosen period of inactivity; activity before then keeps it open', async () => {
    const s = await rpc<any>(owner.client, 'set_store_lock_timeout', { p_minutes: 2 });
    expect(s.idle_minutes).toBe(2);
    await expectError(rpc(owner.client, 'set_store_lock_timeout', { p_minutes: 0 }), 'invalid_input');
    const sid = await sessionId(owner.client);
    await sql(`update app.store_lock_sessions set last_activity = now() - interval '90 seconds' where session_id = $1`, [sid]);
    await rpc(owner.client, 'store_lock_heartbeat');
    expect((await status(owner.client)).locked).toBe(false);
    await sql(`update app.store_lock_sessions set last_activity = now() - interval '3 minutes' where session_id = $1`, [sid]);
    const { data } = await owner.client.from('products').select('id').eq('business_id', biz);
    expect(data).toEqual([]); // locked by inactivity even before the app asks
    expect(await rpc<any>(owner.client, 'store_lock_heartbeat')).toMatchObject({ locked: true });
    expect(await status(owner.client)).toMatchObject({ locked: true, reason: 'idle' });
    expect((await rpc<any>(owner.client, 'unlock_store', { p_pin: '2580' })).ok).toBe(true);
    await rpc(owner.client, 'set_store_lock_timeout', { p_minutes: 15 });
  });

  it('changing the PIN needs the current PIN and locks the other sessions', async () => {
    const other = await signIn(owner.email);
    await rpc(other, 'unlock_store', { p_pin: '2580' });
    expect(await rpc<any>(owner.client, 'change_store_pin', { p_current: '9753', p_new: '8642' })).toMatchObject({ ok: false, error: 'wrong_pin' });
    await expectError(rpc(owner.client, 'change_store_pin', { p_current: '2580', p_new: '5555' }), 'pin_too_simple');
    expect((await rpc<any>(owner.client, 'change_store_pin', { p_current: '2580', p_new: '8642' })).ok).toBe(true);
    expect((await status(owner.client)).locked).toBe(false);
    expect(await status(other)).toMatchObject({ locked: true, reason: 'pin_changed' });
    expect((await rpc<any>(other, 'unlock_store', { p_pin: '2580' })).error).toBe('wrong_pin');
    expect((await rpc<any>(other, 'unlock_store', { p_pin: '8642' })).ok).toBe(true);
    await rpc(other, 'lock_store');
    await expectError(rpc(other, 'change_store_pin', { p_current: '8642', p_new: '7531' }), 'store_locked');
    await other.auth.signOut();
  });

  it('forgotten PIN: reset only right after signing in; then every session must unlock with the new PIN', async () => {
    const sid = await sessionId(owner.client);
    const stale = staleLoginClient(owner.id, sid);
    expect((await status(stale)).can_reset).toBe(false);
    await expectError(rpc(stale, 'reset_store_pin', { p_new: '3698' }), 'fresh_login_required');

    const fresh = await signIn(owner.email); // "sign in again to confirm it's you"
    expect((await status(fresh)).can_reset).toBe(true);
    await expectError(rpc(fresh, 'reset_store_pin', { p_new: '7777' }), 'pin_too_simple');
    const r = await rpc<any>(fresh, 'reset_store_pin', { p_new: '3698' });
    expect(r).toMatchObject({ has_pin: true, locked: true, reason: 'pin_reset' });
    expect(await status(owner.client)).toMatchObject({ locked: true, reason: 'pin_reset' });
    expect((await rpc<any>(owner.client, 'unlock_store', { p_pin: '8642' })).error).toBe('wrong_pin');
    expect((await rpc<any>(owner.client, 'unlock_store', { p_pin: '3698' })).ok).toBe(true);
    expect((await rpc<any>(fresh, 'unlock_store', { p_pin: '3698' })).ok).toBe(true);
    const [audit] = await sql(`select count(*)::int n from audit_logs where user_id = $1 and action = 'store_lock.pin_reset'`, [owner.id]);
    expect(audit.n).toBe(1);
  });

  it('staff have their own PIN and lock; the owner’s lock does not affect them', async () => {
    const cashier = await addStaff(owner, biz, 'cashier');
    await rpc(cashier.client, 'set_store_pin', { p_pin: '1470' });
    await rpc(owner.client, 'lock_store');
    const { data } = await cashier.client.from('products').select('id').eq('business_id', biz);
    expect(data).toHaveLength(1);
    await rpc(cashier.client, 'lock_store');
    expect((await rpc<any>(cashier.client, 'unlock_store', { p_pin: '3698' })).error).toBe('wrong_pin'); // owner's PIN is not the cashier's
    expect((await rpc<any>(cashier.client, 'unlock_store', { p_pin: '1470' })).ok).toBe(true);
    expect((await rpc<any>(owner.client, 'unlock_store', { p_pin: '3698' })).ok).toBe(true);
  });

  it('accounts without a PIN and database jobs are unaffected', async () => {
    const plain = await createUser('lock-none');
    const b = await createBusiness(plain, 'No PIN Shop');
    const { data } = await plain.client.from('businesses').select('id').eq('id', b);
    expect(data).toHaveLength(1);
    const [n] = await sql(`select count(*)::int n from products where business_id = $1`, [biz]);
    expect(n.n).toBe(1);
  });
});
