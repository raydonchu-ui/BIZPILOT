// The blue tick given by an administrator is part of Verified Premium (5,000 XAF a month): it needs the plan, it lasts
// the verification validity period, and it stops when the plan stops.
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { closeDb, createBusiness, createUser, expectError, rpc, sql, type TestUser } from './helpers';

const setPlan = (biz: string, status = 'active') =>
  sql(`update business_subscriptions set plan_code = 'verified_premium', status = $2, billing_period = 'monthly',
       current_period_start = now(), current_period_end = now() + interval '30 days' where business_id = $1`, [biz, status]);

describe('blue tick given by an administrator (Verified Premium only)', () => {
  let admin: TestUser; let owner: TestUser; let stranger: TestUser; let biz: string;

  beforeAll(async () => {
    admin = await createUser('bt-admin');
    await sql('select app.bootstrap_platform_admin($1)', [admin.email]);
    owner = await createUser('bt-owner');
    stranger = await createUser('bt-stranger');
    biz = await createBusiness(owner, 'Blue Tick Shop');
    await rpc(owner.client, 'store_save', { p_business: biz, p: { name: 'Blue Tick Shop', phone: '677000811', whatsapp: '677000811', city: 'Douala' } });
  });
  afterAll(closeDb);

  it('an administrator cannot give the blue tick to a business that is not on Verified Premium', async () => {
    await expectError(rpc(admin.client, 'admin_market_store_update', { p_business: biz, p: { verification: 'verified', reason: 'Known shop' } }), 'requires_verified_premium');
    const [s] = await sql<any>('select verification from stores where business_id = $1', [biz]);
    expect(s.verification).toBe('unverified');
  });

  it('only an administrator can give it, even on the premium plan', async () => {
    await setPlan(biz);
    await expectError(rpc(owner.client, 'admin_market_store_update', { p_business: biz, p: { verification: 'verified' } }), 'permission_denied');
    await expectError(rpc(stranger.client, 'admin_market_store_update', { p_business: biz, p: { verification: 'verified' } }), 'permission_denied');
  });

  it('on Verified Premium the administrator gives it; it lasts about a year and the owner sees it', async () => {
    await rpc(admin.client, 'admin_market_store_update', { p_business: biz, p: { verification: 'verified', reason: 'Known shop in Douala' } });
    const [s] = await sql<any>(`select verification, verification_expires_at > now() + interval '360 days' as long,
      app.blue_tick(business_id) as tick from stores where business_id = $1`, [biz]);
    expect(s).toMatchObject({ verification: 'verified', long: true, tick: true });
  });

  it('the blue tick stops when the plan stops, even though the administrator gave it', async () => {
    await setPlan(biz, 'cancelled');
    const [s] = await sql<any>('select app.blue_tick(business_id) as tick from stores where business_id = $1', [biz]);
    expect(s.tick).toBe(false);
  });

  it('removing the tick is still possible without the plan, and it is recorded with a reason', async () => {
    await rpc(admin.client, 'admin_market_store_update', { p_business: biz, p: { verification: 'unverified', reason: 'Plan ended' } });
    const [s] = await sql<any>('select verification, verification_expires_at from stores where business_id = $1', [biz]);
    expect(s).toEqual({ verification: 'unverified', verification_expires_at: null });
  });
});
