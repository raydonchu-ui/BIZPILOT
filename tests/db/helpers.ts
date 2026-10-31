// Integration-test helpers. Tests talk to a running Supabase stack through the
// public API (Auth + PostgREST), exactly like the browser application does.
// Defaults target `supabase start` (local demo keys, not secrets).
import { createClient, SupabaseClient } from '@supabase/supabase-js';
import { randomUUID } from 'node:crypto';
import pg from 'pg';

export const SUPABASE_URL = process.env.TEST_SUPABASE_URL ?? 'http://127.0.0.1:54321';
export const ANON_KEY =
  process.env.TEST_SUPABASE_ANON_KEY ??
  'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6ImFub24iLCJleHAiOjE5ODM4MTI5OTZ9.CRXP1A7WOeoJeXxjNni43kdQwgnWNReilDMblYTn_I0';
export const SERVICE_KEY =
  process.env.TEST_SUPABASE_SERVICE_KEY ??
  'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImV4cCI6MTk4MzgxMjk5Nn0.EGIM96RAZx35lJzdJsyH-qQwv8Hdp7fsn3W0YpN81IU';
export const DB_URL = process.env.TEST_DB_URL ?? 'postgresql://postgres:postgres@127.0.0.1:54322/postgres';

const opts = { auth: { persistSession: false, autoRefreshToken: false } };
export const admin = createClient(SUPABASE_URL, SERVICE_KEY, opts);
export const anon = () => createClient(SUPABASE_URL, ANON_KEY, opts);

let pool: pg.Pool | null = null;
export function db() {
  pool ??= new pg.Pool({ connectionString: DB_URL, max: 3 });
  return pool;
}
export async function sql<T = any>(text: string, params: unknown[] = []): Promise<T[]> {
  const r = await db().query(text, params);
  return r.rows as T[];
}
export async function closeDb() {
  await pool?.end();
  pool = null;
}

export const uid = () => randomUUID();

export interface TestUser {
  id: string;
  email: string;
  client: SupabaseClient;
}

export async function createUser(prefix = 'user'): Promise<TestUser> {
  const email = `${prefix}-${randomUUID().slice(0, 8)}@test.bizpilot.local`;
  const password = 'Test-password-123!';
  const { data, error } = await admin.auth.admin.createUser({ email, password, email_confirm: true });
  if (error) throw error;
  const client = createClient(SUPABASE_URL, ANON_KEY, opts);
  const { error: e2 } = await client.auth.signInWithPassword({ email, password });
  if (e2) throw e2;
  return { id: data.user!.id, email, client };
}

/** Calls an RPC and returns data, throwing an Error whose message is the DB error code. */
export async function rpc<T = any>(client: SupabaseClient, fn: string, args: Record<string, unknown> = {}): Promise<T> {
  const { data, error } = await client.rpc(fn, args);
  if (error) {
    const err = new Error(error.message) as Error & { details?: string };
    err.details = error.details;
    throw err;
  }
  return data as T;
}

export async function expectError(p: Promise<unknown>, code: string | RegExp) {
  try {
    await p;
  } catch (e: any) {
    const msg = String(e?.message ?? e);
    if (typeof code === 'string' ? msg.includes(code) : code.test(msg)) return e;
    throw new Error(`Expected error ${code} but got: ${msg}`);
  }
  throw new Error(`Expected error ${code} but call succeeded`);
}

// Most tests exercise paid features, so a new test business gets a 30-day Business trial, as new businesses did before.
// Pass 'free' to test what a new account gets without a trial.
export async function createBusiness(user: TestUser, name = 'Test Shop', extra: Record<string, unknown> = {}, plan: 'business' | 'free' = 'business') {
  const id = await rpc<string>(user.client, 'create_business', {
    p: { name, owner_name: 'Owner', country_code: 'CM', language: 'en', category: 'grocery', ...extra },
  });
  if (plan === 'business') {
    await sql(`update business_subscriptions set plan_code = 'business', status = 'trialing', trial_ends_at = now() + interval '30 days' where business_id = $1`, [id]);
  }
  return id;
}

export async function addProduct(user: TestUser, business: string, fields: Record<string, unknown> = {}) {
  const { data, error } = await user.client
    .from('products')
    .insert({
      business_id: business,
      name: fields.name ?? `Product ${randomUUID().slice(0, 6)}`,
      sku: fields.sku ?? `SKU-${randomUUID().slice(0, 8)}`,
      selling_price: 1000,
      purchase_cost: 600,
      ...fields,
    })
    .select()
    .single();
  if (error) throw new Error(error.message);
  return data as any;
}

export async function addSupplier(user: TestUser, business: string, fields: Record<string, unknown> = {}) {
  const { data, error } = await user.client
    .from('suppliers')
    .insert({ business_id: business, name: `Supplier ${randomUUID().slice(0, 6)}`, ...fields })
    .select()
    .single();
  if (error) throw new Error(error.message);
  return data as any;
}

export async function addCustomer(user: TestUser, business: string, fields: Record<string, unknown> = {}) {
  const { data, error } = await user.client
    .from('customers')
    .insert({ business_id: business, name: `Customer ${randomUUID().slice(0, 6)}`, ...fields })
    .select()
    .single();
  if (error) throw new Error(error.message);
  return data as any;
}

export async function product(user: TestUser, id: string) {
  const { data, error } = await user.client.from('products').select('*').eq('id', id).single();
  if (error) throw new Error(error.message);
  return data as any;
}

/** Adds a staff member with the given role directly (bypassing the invite email). */
export async function addStaff(owner: TestUser, business: string, role: 'manager' | 'cashier') {
  const staff = await createUser(role);
  await rpc(owner.client, 'invite_member', { p_business: business, p_email: staff.email, p_role: role });
  const n = await rpc<number>(staff.client, 'accept_invites');
  if (n !== 1) throw new Error('invite not accepted');
  return staff;
}

export async function sell(user: TestUser, business: string, lines: any[], extra: Record<string, unknown> = {}) {
  return rpc<any>(user.client, 'create_sale', { p_business: business, p: { client_ref: uid(), lines, ...extra } });
}

/** Opening stock helper (quantity in base units, cost per base unit). */
export async function openStock(user: TestUser, business: string, productId: string, qty: number, cost: number) {
  return rpc(user.client, 'record_opening_stock', {
    p_business: business, p_product: productId, p_quantity: qty, p_unit_cost: cost,
  });
}

export const n = (v: unknown) => Number(v);
