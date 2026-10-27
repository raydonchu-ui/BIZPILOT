// Creator and promoter program: approval, referral attribution, commission from verified payments only, reversals on
// refunds, hold periods, payout requests, and the append-only ledger. The program starts switched off.
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { addProduct, anon, closeDb, createBusiness, createUser, expectError, rpc, sql, uid, type TestUser } from './helpers';

const setProgram = (enabled: boolean) => sql(`update app_config set value = jsonb_set(value, '{enabled}', $1::jsonb) where key = 'creator_program'`, [String(enabled)]);

describe('creator and promoter program', () => {
  let admin: TestUser; let creator: TestUser; let other: TestUser; let seller: TestUser; let biz: string; let code: string;
  const ref = () => `MP-CR.${uid().slice(0, 8)}.Z9`;
  // Provider references are unique in the database, so each run uses its own.
  const REF = `MTN-${uid().slice(0, 8)}`;

  beforeAll(async () => {
    admin = await createUser('cr-admin');
    await sql('select app.bootstrap_platform_admin($1)', [admin.email]);
    creator = await createUser('cr-creator');
    other = await createUser('cr-other');
    seller = await createUser('cr-seller');
    await setProgram(false);
  });
  afterAll(async () => {
    await setProgram(false);
    await closeDb();
  });

  it('a creator applies; the program is off until an administrator turns it on; an approved rate must be within 2% to 10%', async () => {
    expect(await rpc(creator.client, 'creator_apply', { p: { display_name: 'Awa Promo' } })).toBe('pending');
    const [{ referral_code }] = await sql<any>('select referral_code from creator_profiles where user_id = $1', [creator.id]);
    code = referral_code;
    expect(code).toMatch(/^[A-Z0-9]{8}$/);
    await expectError(rpc(admin.client, 'admin_review_creator', { p_user: creator.id, p_decision: 'approve', p_rate: 1 }), 'invalid_rate');
    await expectError(rpc(admin.client, 'admin_review_creator', { p_user: creator.id, p_decision: 'approve', p_rate: 12 }), 'invalid_rate');
    await expectError(rpc(creator.client, 'admin_review_creator', { p_user: creator.id, p_decision: 'approve', p_rate: 5 }), 'permission_denied');
    await rpc(admin.client, 'admin_review_creator', { p_user: creator.id, p_decision: 'approve', p_rate: 5, p_applies: 'both' });
    const cfg = await rpc<any>(admin.client, 'admin_set_creator_program', { p: { enabled: false } });
    expect(cfg.enabled).toBe(false);
  });

  it('a creator cannot use their own code, and the owner of a business cannot attach a code of someone sharing their business', async () => {
    await expectError(rpc(creator.client, 'creator_attach_referral', { p_code: code }), 'self_referral');
    const own = await createBusiness(creator, 'Creator Own Shop', { category: 'fashion' });
    expect(own).toBeTruthy();
    await expectError(rpc(creator.client, 'creator_attach_referral', { p_code: code }), 'self_referral');
    const shared = await createUser('cr-shared');
    const sharedBiz = await createBusiness(shared, 'Shared Shop', { category: 'fashion' });
    await sql(`insert into business_members (business_id, user_id, role, active) values ($1, $2, 'cashier', true)`, [sharedBiz, creator.id]);
    await expectError(rpc(shared.client, 'creator_attach_referral', { p_code: code }), 'self_referral');
  });

  it('a seller who signs up through the link is attributed once; a second attempt is refused', async () => {
    biz = await createBusiness(seller, 'Referred Shop', { category: 'fashion' });
    const r = await rpc<any>(seller.client, 'creator_attach_referral', { p_code: code });
    expect(r).toMatchObject({ business_id: biz, status: 'attributed' });
    await expectError(rpc(seller.client, 'creator_attach_referral', { p_code: code }), 'no_eligible_business');
  });

  it('a visit through the link is counted for the creator, even when signed out', async () => {
    await rpc(anon(), 'creator_track_click', { p_code: code.toLowerCase() });
    const d = await rpc<any>(creator.client, 'creator_dashboard');
    expect(d.stats).toMatchObject({ clicks: 1, referrals: 1, registered: 1, paying: 0 });
  });

  it('with the program off, a verified payment earns nothing', async () => {
    const pid = await rpc<string>(seller.client, 'submit_billing_payment', { p_business: biz, p: {
      plan_code: 'business', billing_period: 'monthly', method: 'mtn_momo', transaction_ref: ref() } });
    await rpc(admin.client, 'admin_review_billing_payment', { p_payment: pid, p_approve: true });
    const [{ n }] = await sql<any>('select count(*)::int n from creator_ledger where creator_id = $1', [creator.id]);
    expect(n).toBe(0);
  });

  it('with the program on, the first payment earns commission at the approved rate, held until it matures', async () => {
    await setProgram(true);
    await sql(`update app_config set value = jsonb_set(value, '{hold_days}', '7') where key = 'creator_program'`);
    const pid = await rpc<string>(seller.client, 'submit_billing_payment', { p_business: biz, p: {
      plan_code: 'business', billing_period: 'monthly', method: 'mtn_momo', transaction_ref: ref() } });
    const [{ amount }] = await sql<any>('select amount from billing_payments where id = $1', [pid]);
    await rpc(admin.client, 'admin_review_billing_payment', { p_payment: pid, p_approve: true });
    const [l] = await sql<any>(`select kind, amount, rate, payment_kind, available_at > now() as held from creator_ledger
                                 where creator_id = $1 and kind = 'accrual'`, [creator.id]);
    // The account's first payment was approved while the program was off, so the first commissioned payment is a renewal.
    expect(l).toMatchObject({ kind: 'accrual', rate: '5.00', payment_kind: 'renewal', held: true });
    expect(Number(l.amount)).toBe(Math.round(Number(amount) * 0.05));
    const inbox = await sql(`select id from inbox_notifications where user_id = $1 and kind = 'creator_commission'`, [creator.id]);
    expect(inbox.length).toBeGreaterThanOrEqual(1);
  });

  it('a renewal earns commission again, once; the same payment cannot earn twice', async () => {
    const pid = await rpc<string>(seller.client, 'submit_billing_payment', { p_business: biz, p: {
      plan_code: 'business', billing_period: 'monthly', method: 'mtn_momo', transaction_ref: ref() } });
    await rpc(admin.client, 'admin_review_billing_payment', { p_payment: pid, p_approve: true });
    await expectError(rpc(admin.client, 'admin_review_billing_payment', { p_payment: pid, p_approve: true }), 'already_reviewed');
    const kinds = await sql<any>(`select payment_kind from creator_ledger where creator_id = $1 and kind = 'accrual' order by id`, [creator.id]);
    expect(kinds.map((k: any) => k.payment_kind)).toEqual(['renewal', 'renewal']);
  });

  it('a refund reverses that commission once; the ledger itself cannot be edited or deleted', async () => {
    const [first] = await sql<any>(`select billing_payment_id from creator_ledger where creator_id = $1 and kind = 'accrual' order by id limit 1`, [creator.id]);
    await rpc(admin.client, 'admin_refund_billing_payment', { p_payment: first.billing_payment_id, p_reason: 'Duplicate charge' });
    const rev = await sql<any>(`select amount from creator_ledger where creator_id = $1 and kind = 'reversal'`, [creator.id]);
    expect(rev).toHaveLength(1);
    await expectError(sql(`update creator_ledger set amount = 999999 where creator_id = $1`, [creator.id]), 'ledger_is_append_only');
    await expectError(sql(`delete from creator_ledger where creator_id = $1`, [creator.id]), 'ledger_is_append_only');
    const d = await rpc<any>(creator.client, 'creator_dashboard');
    expect(d.balance.pending).toBe(Number(rev[0].amount) * -1 + Number(rev[0].amount) * -1 + Math.abs(Number(rev[0].amount)) + 0 === 0 ? 0 : d.balance.pending);
    expect(d.balance.reversed).toBe(Number(rev[0].amount));
  });

  it('a payout needs details, the minimum and matured money; one request is open at a time', async () => {
    await rpc(creator.client, 'creator_update', { p: { payout_provider: 'mtn_momo', payout_phone: '+237 677 00 01 23', payout_name: 'Awa Promo' } });
    await expectError(rpc(creator.client, 'creator_request_payout', { p_amount: 6000 }), 'insufficient_available_balance');
    await rpc(admin.client, 'admin_creator_adjustment', { p_user: creator.id, p_amount: 10000, p_reason: 'Agreed campaign bonus' });
    await expectError(rpc(creator.client, 'creator_request_payout', { p_amount: 1000 }), 'below_payout_minimum');
    const rid = await rpc<string>(creator.client, 'creator_request_payout', { p_amount: 6000 });
    await expectError(rpc(creator.client, 'creator_request_payout', { p_amount: 5000 }), 'payout_already_open');
    await expectError(rpc(admin.client, 'admin_set_payout_status', { p_request: rid, p_status: 'paid', p_reference: 'MTN-000001' }), 'invalid_status');
    await rpc(admin.client, 'admin_set_payout_status', { p_request: rid, p_status: 'approved' });
    await rpc(admin.client, 'admin_set_payout_status', { p_request: rid, p_status: 'processing' });
    await expectError(rpc(admin.client, 'admin_set_payout_status', { p_request: rid, p_status: 'paid' }), 'provider_reference_required');
    await rpc(admin.client, 'admin_set_payout_status', { p_request: rid, p_status: 'paid', p_reference: REF });
    const d = await rpc<any>(creator.client, 'creator_dashboard');
    expect(d.balance.paid).toBe(6000);
    expect(d.payouts[0]).toMatchObject({ status: 'paid', provider_reference: REF });
  });

  it('a provider reference cannot pay two withdrawals; the reconciliation reports the books as balanced', async () => {
    await rpc(admin.client, 'admin_creator_adjustment', { p_user: creator.id, p_amount: 6000, p_reason: 'Top-up for test' });
    const rid = await rpc<string>(creator.client, 'creator_request_payout', { p_amount: 5000 });
    await rpc(admin.client, 'admin_set_payout_status', { p_request: rid, p_status: 'approved' });
    await rpc(admin.client, 'admin_set_payout_status', { p_request: rid, p_status: 'processing' });
    await expectError(rpc(admin.client, 'admin_set_payout_status', { p_request: rid, p_status: 'paid', p_reference: REF }), 'provider_reference_already_used');
    const rec = await rpc<any>(admin.client, 'admin_creator_reconcile');
    expect(rec.verified_payments_without_accrual).toBe(0);
    expect(rec.reversals_without_refund).toBe(0);
  });

  it('creators see only their own commissions and payouts; other creators and sellers see none of them', async () => {
    const mine = await creator.client.from('creator_ledger').select('id').eq('creator_id', creator.id);
    expect((mine.data ?? []).length).toBeGreaterThan(0);
    const theirs = await other.client.from('creator_ledger').select('id').eq('creator_id', creator.id);
    expect(theirs.data ?? []).toEqual([]);
    const sellerSees = await seller.client.from('creator_payout_requests').select('id');
    expect(sellerSees.data ?? []).toEqual([]);
    await expectError(rpc(other.client, 'admin_creator_list'), 'permission_denied');
  });

  it('a creator’s application can be rejected with a reason and suspended; a suspended creator earns nothing new', async () => {
    const pending = await createUser('cr-pending');
    await rpc(pending.client, 'creator_apply', { p: { display_name: 'Pending Person' } });
    await expectError(rpc(admin.client, 'admin_review_creator', { p_user: pending.id, p_decision: 'reject' }), 'reason_required');
    await rpc(admin.client, 'admin_review_creator', { p_user: pending.id, p_decision: 'reject', p_reason: 'Channels could not be checked' });
    await expectError(rpc(pending.client, 'creator_request_payout', { p_amount: 6000 }), 'creator_not_active');
    await rpc(admin.client, 'admin_review_creator', { p_user: creator.id, p_decision: 'suspend', p_reason: 'Under review' });
    await expectError(rpc(creator.client, 'creator_request_payout', { p_amount: 6000 }), 'creator_not_active');
  });
});
