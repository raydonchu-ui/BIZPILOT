// Verified Premium (5,000 XAF a month): applications, administrator decisions, the blue tick, billing and refunds.
// Paying never approves verification; the blue tick needs an approved, unexpired verification AND the premium plan.
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { addProduct, anon, closeDb, createBusiness, createUser, expectError, openStock, rpc, sql, uid, type TestUser } from './helpers';

const docFor = (biz: string, name: string) => `${biz}/verification/${name}.webp`;

describe('Verified Premium, verification and the blue tick', () => {
  let owner: TestUser; let other: TestUser; let platformAdmin: TestUser; let biz: string; let slug: string; let appId: string;
  let followerA: TestUser; let followerB: TestUser;

  beforeAll(async () => {
    owner = await createUser('vp-owner');
    other = await createUser('vp-other');
    followerA = await createUser('vp-fan-a');
    followerB = await createUser('vp-fan-b');
    platformAdmin = await createUser('vp-admin');
    await sql('select app.bootstrap_platform_admin($1)', [platformAdmin.email]);
    biz = await createBusiness(owner, 'Premium Shop', { category: 'fashion' });
    await rpc(owner.client, 'store_save', { p_business: biz, p: { name: 'Premium Shop', phone: '677000701', whatsapp: '677000701', city: 'Douala', pickup_enabled: true, pickup_note: 'Akwa market' } });
    await rpc(owner.client, 'store_save_payments', { p_business: biz, p: { cod_enabled: true } });
    [{ slug }] = await sql<{ slug: string }>('select slug from stores where business_id = $1', [biz]);
    const item = await addProduct(owner, biz, { name: 'Premium tee', selling_price: 3000, min_stock: 0 });
    await openStock(owner, biz, item.id, 5, 1000);
    await rpc(owner.client, 'products_set_online', { p_business: biz, p_ids: [item.id], p_online: true });
    await rpc(owner.client, 'store_set_published', { p_business: biz, p_publish: true });
  });
  afterAll(async () => {
    await sql(`update app_config set value = '{"min_followers": 300, "min_account_age_days": 7, "validity_days": 365, "purge_after_days": 90}' where key = 'verification'`);
    await closeDb();
  });

  it('Verified Premium is priced at 5,000 XAF a month and carries the premium features', async () => {
    const [p] = await sql<any>(`select price_monthly, features from plans where code = 'verified_premium' and active`);
    expect(Number(p.price_monthly)).toBe(5000);
    expect(p.features).toEqual(expect.arrayContaining(['verified_badge', 'premium_automations', 'ai_business_manager', 'ai_advisor']));
  });

  it('with the default rules, a new store is not eligible: it needs 300 genuine followers', async () => {
    await expectError(rpc(owner.client, 'verification_apply', { p_business: biz, p: { legal_name: 'Premium Shop SARL', id_type: 'business_registration',
      id_document_path: docFor(biz, 'reg') } }), 'verification_not_eligible');
    const st = await rpc<any>(owner.client, 'verification_status', { p_business: biz });
    expect(st.eligibility).toMatchObject({ eligible: false, followers: 0, min_followers: 300 });
    expect(st.eligibility.reasons).toContain('followers_below_minimum');
    expect(st.blue_tick).toBe(false);
  });

  it('only store managers can apply, and the documents must be in the business own verification folder', async () => {
    await sql(`update app_config set value = '{"min_followers": 2, "min_account_age_days": 0, "validity_days": 365, "purge_after_days": 90}' where key = 'verification'`);
    await sql(`insert into market_store_follows (user_id, business_id) values ($1, $3), ($2, $3) on conflict do nothing`, [followerA.id, followerB.id, biz]);
    await expectError(rpc(other.client, 'verification_apply', { p_business: biz, p: { legal_name: 'Intruder Ltd', id_type: 'national_id', id_document_path: docFor(biz, 'x') } }), 'permission_denied');
    await expectError(rpc(owner.client, 'verification_apply', { p_business: biz, p: { legal_name: 'Premium Shop SARL', id_type: 'national_id',
      id_document_path: `${other.id}/verification/id.webp` } }), 'invalid_document');
    await expectError(rpc(owner.client, 'verification_apply', { p_business: biz, p: { legal_name: 'Premium Shop SARL', id_type: 'national_id',
      id_document_path: docFor(biz, 'id'), business_document_path: `${biz}/logos/logo.webp` } }), 'invalid_document');
  });

  it('a seller applies with the owner documents; the application stays open until decided, and only the last four ID digits are sent and kept', async () => {
    appId = await rpc<string>(owner.client, 'verification_apply', { p_business: biz, p: { legal_name: 'Premium Shop SARL', id_type: 'national_id',
      id_last4: '0123', id_document_path: docFor(biz, 'id'), business_document_path: docFor(biz, 'reg') } });
    const [row] = await sql<any>('select status, id_last4, followers_at_submission from verification_applications where id = $1', [appId]);
    expect(row).toMatchObject({ status: 'submitted', id_last4: '0123', followers_at_submission: 2 });
    await expectError(rpc(owner.client, 'verification_apply', { p_business: biz, p: { legal_name: 'Premium Shop SARL', id_type: 'national_id', id_document_path: docFor(biz, 'id') } }), 'verification_already_open');
    const [{ verification }] = await sql<any>('select verification from stores where business_id = $1', [biz]);
    expect(verification).toBe('pending');
  });

  it('applicants and other businesses cannot read the application; the owner sees its own status', async () => {
    const mine = await owner.client.from('verification_applications').select('id').eq('business_id', biz);
    expect(mine.data?.length).toBe(1);
    const theirs = await other.client.from('verification_applications').select('id').eq('business_id', biz);
    expect(theirs.data ?? []).toEqual([]);
    const st = await rpc<any>(owner.client, 'verification_status', { p_business: biz });
    expect(st.application.status).toBe('submitted');
    await expectError(rpc(other.client, 'verification_status', { p_business: biz }), 'not_found');
  });

  it('paying for Verified Premium does not approve verification, and the 5,000 XAF amount is what is charged', async () => {
    const pid = await rpc<string>(owner.client, 'submit_billing_payment', { p_business: biz, p: {
      plan_code: 'verified_premium', billing_period: 'monthly', method: 'mtn_momo', transaction_ref: `MP-VP.${uid().slice(0, 8)}.A1` } });
    const [bp] = await sql<any>('select amount, expected_amount, status from billing_payments where id = $1', [pid]);
    expect(Number(bp.expected_amount)).toBe(5000);
    expect(bp.status).toBe('pending');
    const [{ verification }] = await sql<any>('select verification from stores where business_id = $1', [biz]);
    expect(verification).toBe('pending');
    // The plan is not changed while the payment is pending (the seller keeps what they have).
    const [{ plan_code }] = await sql<any>('select plan_code from business_subscriptions where business_id = $1', [biz]);
    expect(plan_code).not.toBe('verified_premium');
  });

  it('an administrator approves the payment: the plan switches to Verified Premium for one month from approval', async () => {
    const [bp] = await sql<{ id: string }>(`select id from billing_payments where business_id = $1 and plan_code = 'verified_premium' and status = 'pending'`, [biz]);
    await rpc(platformAdmin.client, 'admin_review_billing_payment', { p_payment: bp.id, p_approve: true });
    const [s] = await sql<any>(`select plan_code, status, extract(epoch from (current_period_end - now())) / 86400 as days
                                  from business_subscriptions where business_id = $1`, [biz]);
    expect(s.plan_code).toBe('verified_premium');
    expect(s.status).toBe('active');
    expect(Number(s.days)).toBeGreaterThan(29);
    expect(Number(s.days)).toBeLessThanOrEqual(31);
  });

  it('an administrator cannot approve a verification without a reason to reject, and cannot approve an ineligible store', async () => {
    await expectError(rpc(platformAdmin.client, 'admin_review_verification', { p_application: appId, p_decision: 'reject', p_reason: ' ' }), 'reason_required');
    await expectError(rpc(owner.client, 'admin_review_verification', { p_application: appId, p_decision: 'approve' }), 'permission_denied');
    const queue = await rpc<any[]>(platformAdmin.client, 'admin_verification_applications', { p_status: 'submitted' });
    expect(queue.find((a: any) => a.id === appId)?.eligibility.eligible).toBe(true);
  });

  it('approval shows the blue tick on the store page, for one year, and tells the seller', async () => {
    await rpc(platformAdmin.client, 'admin_review_verification', { p_application: appId, p_decision: 'approve', p_reason: 'Documents match' });
    const store = await rpc<any>(anon(), 'market_store', { p_slug: slug });
    expect(store.verified).toBe(true);
    const st = await rpc<any>(owner.client, 'verification_status', { p_business: biz });
    expect(st).toMatchObject({ blue_tick: true, verification: 'verified', premium_active: true });
    const [note] = await sql(`select id from notifications where business_id = $1 and type = 'verification_decision' and params->>'decision' = 'approved'`, [biz]);
    expect(note).toBeTruthy();
  });

  it('the blue tick needs the premium entitlement: when the plan lapses it is hidden, and it returns on renewal', async () => {
    await sql(`update business_subscriptions set current_period_end = now() - interval '30 days' where business_id = $1`, [biz]);
    expect((await rpc<any>(anon(), 'market_store', { p_slug: slug })).verified).toBe(false);
    await sql(`update business_subscriptions set current_period_end = now() + interval '30 days', status = 'active' where business_id = $1`, [biz]);
    expect((await rpc<any>(anon(), 'market_store', { p_slug: slug })).verified).toBe(true);
  });

  it('an expired verification is hidden at once, and the expiry sweep moves it to unverified with a notice', async () => {
    await sql(`update stores set verification_expires_at = now() - interval '1 day' where business_id = $1`, [biz]);
    expect((await rpc<any>(anon(), 'market_store', { p_slug: slug })).verified).toBe(false);
    const [{ expire_verifications }] = await sql<any>('select app.expire_verifications() as expire_verifications');
    expect(Number(expire_verifications)).toBeGreaterThanOrEqual(1);
    const [{ verification }] = await sql<any>('select verification from stores where business_id = $1', [biz]);
    expect(verification).toBe('unverified');
    const [n] = await sql(`select id from notifications where business_id = $1 and type = 'verification_expired'`, [biz]);
    expect(n).toBeTruthy();
    // Restore an active verification for the rest of the tests.
    await sql(`update stores set verification = 'verified', verification_expires_at = now() + interval '1 year' where business_id = $1`, [biz]);
  });

  it('an administrator revokes with a reason; the blue tick goes at once', async () => {
    await expectError(rpc(platformAdmin.client, 'admin_revoke_verification', { p_business: biz, p_reason: '' }), 'reason_required');
    await rpc(platformAdmin.client, 'admin_revoke_verification', { p_business: biz, p_reason: 'Reported by a customer, under review' });
    expect((await rpc<any>(anon(), 'market_store', { p_slug: slug })).verified).toBe(false);
  });

  it('a refund ends the paid period it created; a refunded payment cannot be refunded again', async () => {
    const [bp] = await sql<{ id: string }>(`select id from billing_payments where business_id = $1 and plan_code = 'verified_premium' and status = 'verified'`, [biz]);
    // The paid period is still the current one, so the refund ends it.
    await sql(`update business_subscriptions set current_period_end = (select period_end from billing_payments where id = $2) where business_id = $1`, [biz, bp.id]);
    await rpc(platformAdmin.client, 'admin_refund_billing_payment', { p_payment: bp.id, p_reason: 'Duplicate charge' });
    const [s] = await sql<any>(`select status, cancel_at_period_end, current_period_end <= now() + interval '1 minute' as ended from business_subscriptions where business_id = $1`, [biz]);
    expect(s).toMatchObject({ status: 'cancelled', cancel_at_period_end: true, ended: true });
    await expectError(rpc(platformAdmin.client, 'admin_refund_billing_payment', { p_payment: bp.id, p_reason: 'again' }), 'invalid_status');
  });

  it('a seller can cancel a pending payment, and the reference can then be used again', async () => {
    const ref = `MP-CANCEL.${uid().slice(0, 8)}.B2`;
    const pid = await rpc<string>(owner.client, 'submit_billing_payment', { p_business: biz, p: {
      plan_code: 'business', billing_period: 'monthly', method: 'mtn_momo', transaction_ref: ref } });
    await rpc(owner.client, 'billing_payment_cancel', { p_payment: pid });
    const [{ status }] = await sql<any>('select status from billing_payments where id = $1', [pid]);
    expect(status).toBe('cancelled');
    await rpc(owner.client, 'submit_billing_payment', { p_business: biz, p: {
      plan_code: 'business', billing_period: 'monthly', method: 'mtn_momo', transaction_ref: ref } });
  });
});
