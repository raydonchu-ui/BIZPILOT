// One login, several roles: the roles come from the records that grant them, and a plain account has no extra roles.
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { anon, closeDb, createBusiness, createUser, rpc, sql, type TestUser } from './helpers';

describe('account roles', () => {
  let plain: TestUser; let seller: TestUser; let creator: TestUser; let admin: TestUser; let biz: string;

  beforeAll(async () => {
    plain = await createUser('role-plain');
    seller = await createUser('role-seller');
    creator = await createUser('role-creator');
    admin = await createUser('role-admin');
    await sql('select app.bootstrap_platform_admin($1)', [admin.email]);
    biz = await createBusiness(seller, 'Roles Shop', { category: 'fashion' });
    await rpc(creator.client, 'creator_apply', { p: { display_name: 'Role Creator', payout_provider: 'mtn_momo', payout_phone: '670000002' } });
    await sql(`update creator_profiles set status = 'approved', commission_rate = 5, applies_to = 'both' where user_id = $1`, [creator.id]);
  });
  afterAll(closeDb);

  it('a plain account is a buyer and nothing more', async () => {
    expect(await rpc<any>(plain.client, 'my_roles')).toEqual({ signed_in: true, buyer: true, sellers: [], creator: false, creator_pending: false, admin: false });
  });

  it('a seller sees the business and their role, one login for every business they belong to', async () => {
    const r = await rpc<any>(seller.client, 'my_roles');
    expect(r.sellers).toEqual([expect.objectContaining({ business_id: biz, name: 'Roles Shop', role: 'owner', premium: false })]);
    expect(r.creator).toBe(false);
  });

  it('an approved creator holds the creator role on the same login as a seller', async () => {
    const r = await rpc<any>(creator.client, 'my_roles');
    expect(r).toMatchObject({ creator: true, creator_pending: false, sellers: [] });
  });

  it('the administrator role is shown only to platform administrators', async () => {
    expect((await rpc<any>(admin.client, 'my_roles')).admin).toBe(true);
    expect((await rpc<any>(plain.client, 'my_roles')).admin).toBe(false);
  });

  it('anonymous visitors get no roles', async () => {
    await expectNoAnon();
  });

  async function expectNoAnon() {
    const { error } = await anon().rpc('my_roles');
    expect(error).not.toBeNull();
  }
});
