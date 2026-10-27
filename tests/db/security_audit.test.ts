// Security audit, run against the database itself: row-level security on every table, the only functions anonymous
// visitors may call, private tables closed to anonymous visitors, rate limits, and cross-account and escalation checks.
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { admin, anon, closeDb, createBusiness, createUser, expectError, rpc, sql, type TestUser } from './helpers';

// Functions anonymous visitors may call. Each either serves the public catalogue, or checks an order token, or is guest
// support, or only counts a creator link visit. Anything else must be closed to anonymous visitors.
const ANON_FUNCTIONS = new Set([
  'market_config_public', 'market_home', 'market_locations', 'market_order_customer_action', 'market_order_report_payment',
  'market_order_view', 'market_payment_begin', 'market_place_order', 'market_product', 'market_products_by_ids', 'market_quote',
  'market_report', 'market_search', 'market_shops', 'market_store', 'market_store_cards', 'market_submit_review',
  'online_payment_status', 'store_slug_available', 'submit_support_request', 'creator_track_click',
]);

// Tables that hold private data. Anonymous visitors must see no rows from any of them.
const PRIVATE_TABLES = ['ai_conversations', 'ai_messages', 'ai_action_requests', 'supplier_draft_lists', 'seller_automations',
  'automation_runs', 'creator_profiles', 'creator_ledger', 'referrals', 'creator_payout_requests', 'verification_applications',
  'notification_preferences', 'inbox_notifications', 'billing_payments', 'notifications', 'support_requests', 'stored_images',
  'market_reports', 'online_payments', 'platform_admins', 'audit_logs', 'business_members', 'creator_clicks'];

// Platform-admin functions. A normal account must be refused every one of them.
const ADMIN_CALLS: [string, Record<string, unknown>][] = [
  ['admin_finance_overview', { p_from: '2026-01-01', p_to: '2026-01-02' }],
  ['admin_platform_health', {}],
  ['admin_creator_list', { p_status: null }],
  ['admin_set_creator_program', { p: { enabled: true } }],
  ['admin_creator_reconcile', {}],
  ['admin_list_payouts', { p_status: null }],
  ['admin_verification_applications', { p_status: null }],
  ['admin_locations_list', {}],
  ['admin_add_locality', { p_region: 'littoral', p_name: 'Nope' }],
  ['admin_set_region_names', { p_code: 'west', p_en: 'West', p_fr: 'Ouest' }],
];

describe('security audit', () => {
  let user: TestUser; let other: TestUser; let biz: string;

  beforeAll(async () => {
    user = await createUser('sec-user');
    other = await createUser('sec-other');
    biz = await createBusiness(user, 'Audit Shop', { category: 'fashion' });
  });
  afterAll(async () => { await closeDb(); });

  it('every table in the public schema has row-level security turned on', async () => {
    const rows = await sql<{ relname: string }>(`select c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
      where n.nspname = 'public' and c.relkind = 'r' and not c.relrowsecurity`);
    expect(rows.map((r) => r.relname)).toEqual([]);
  });

  it('anonymous visitors can run only the functions on the allowlist', async () => {
    const rows = await sql<{ routine_name: string }>(`select distinct routine_name from information_schema.role_routine_grants
      where grantee = 'anon' and routine_schema = 'public'`);
    const unexpected = rows.map((r) => r.routine_name).filter((name) => !ANON_FUNCTIONS.has(name));
    expect(unexpected).toEqual([]);
  });

  it('anonymous visitors see no rows from any private table', async () => {
    for (const table of PRIVATE_TABLES) {
      const { data, error } = await anon().from(table).select('*').limit(5);
      expect(error ? [] : data ?? []).toEqual([]);
    }
  });

  it('a signed-in account cannot read another account’s private rows', async () => {
    const seen = await other.client.from('ai_conversations').select('id').eq('business_id', biz);
    expect(seen.data ?? []).toEqual([]);
    const notes = await other.client.from('notifications').select('id').eq('business_id', biz);
    expect(notes.data ?? []).toEqual([]);
    const docs = await other.client.from('verification_applications').select('id').eq('business_id', biz);
    expect(docs.data ?? []).toEqual([]);
  });

  it('a normal account is refused every platform-administrator function', async () => {
    for (const [fn, args] of ADMIN_CALLS) {
      await expectError(rpc(user.client, fn, args), /permission_denied|not_authenticated/);
    }
  });

  it('a normal account is refused business functions for a business it does not belong to', async () => {
    await expectError(rpc(other.client, 'ai_list_conversations', { p_business: biz }), 'permission_denied');
    await expectError(rpc(other.client, 'automation_list', { p_business: biz }), 'permission_denied');
    await expectError(rpc(other.client, 'verification_status', { p_business: biz }), 'not_found');
    await expectError(rpc(other.client, 'billing_payment_cancel', { p_payment: '00000000-0000-0000-0000-000000000000' }), 'not_found');
  });

  it('applying to be a creator is rate limited (three attempts a day)', async () => {
    const c = await createUser('sec-creator');
    for (let i = 0; i < 3; i++) await rpc(c.client, 'creator_apply', { p: { display_name: 'Rate Test' } });
    await expectError(rpc(c.client, 'creator_apply', { p: { display_name: 'Rate Test' } }), 'rate_limited');
  });

  it('the platform administrator is set only by the deployer, never through the API', async () => {
    await expectError(rpc(user.client, 'admin_add_platform_admin', { p_email: user.email }), /permission_denied|not_found|not_authenticated/);
    const { error } = await admin.from('platform_admins').select('user_id').eq('user_id', user.id);
    expect(error).toBeNull();
    const [{ n }] = await sql<any>('select count(*)::int n from platform_admins where user_id = $1', [user.id]);
    expect(n).toBe(0);
  });
});
