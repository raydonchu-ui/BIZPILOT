// Seller Mobile Money settings (MTN, Orange): each method on or off, validated, visible to the buyer only when enabled.
// BizPilot stores what the seller enters; it never stores PINs, passwords or OTPs.
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { randomBytes } from 'node:crypto';
import { addProduct, addStaff, anon, closeDb, createBusiness, createUser, expectError, openStock, rpc, sql, uid, type TestUser } from './helpers';

const token = () => randomBytes(24).toString('hex');
const phone = () => `69${Math.floor(1e6 + Math.random() * 8.9e6)}`;

describe('seller payment settings: MTN and Orange', () => {
  let owner: TestUser; let other: TestUser; let biz: string; let slug: string; let item: any;

  beforeAll(async () => {
    await sql(`delete from rate_limits where key like 'order_%' or key like 'order_phone:%'`);
    owner = await createUser('pay-owner');
    other = await createUser('pay-other');
    biz = await createBusiness(owner, 'Payments Shop', { category: 'fashion' });
    await rpc(owner.client, 'store_save', { p_business: biz, p: { name: 'Payments Shop', phone: '677000601', whatsapp: '677000601', city: 'Douala', pickup_enabled: true, pickup_note: 'Akwa market' } });
    [{ slug }] = await sql<{ slug: string }>('select slug from stores where business_id = $1', [biz]);
    item = await addProduct(owner, biz, { name: 'Pay shirt', selling_price: 4000, min_stock: 0 });
    await openStock(owner, biz, item.id, 20, 2000);
    await rpc(owner.client, 'products_set_online', { p_business: biz, p_ids: [item.id], p_online: true });
  });
  afterAll(closeDb);

  it('a seller turns on MTN only, with a number, name and instructions', async () => {
    await rpc(owner.client, 'store_save_payments', { p_business: biz, p: {
      momo_direct_enabled: true, momo_mtn_enabled: true, momo_mtn_number: '677 00 00 01', momo_mtn_name: 'Awa Shop',
      momo_mtn_instructions: 'Send to this number, then type the reference in the order.',
      momo_orange_enabled: false, momo_orange_number: '699000002', momo_proof_required: true } });
    const [s] = await sql<any>(`select momo_direct_enabled, momo_mtn_enabled, momo_orange_enabled, momo_mtn_number, momo_mtn_name,
      momo_proof_required, momo_settings_updated_at from stores where business_id = $1`, [biz]);
    expect(s).toMatchObject({ momo_direct_enabled: true, momo_mtn_enabled: true, momo_orange_enabled: false,
      momo_mtn_number: '677000001', momo_mtn_name: 'Awa Shop', momo_proof_required: true });
    expect(s.momo_settings_updated_at).not.toBeNull();
  });

  it('an enabled method needs its number', async () => {
    await expectError(rpc(owner.client, 'store_save_payments', { p_business: biz, p: {
      momo_direct_enabled: true, momo_orange_enabled: true, momo_orange_number: '' } }), 'momo_number_required');
    await expectError(rpc(owner.client, 'store_save_payments', { p_business: biz, p: {
      momo_direct_enabled: true, momo_mtn_enabled: false, momo_orange_enabled: false, momo_mtn_number: '677000001' } }), 'momo_number_required');
  });

  it('a number must be a valid 9-digit mobile number', async () => {
    await expectError(rpc(owner.client, 'store_save_payments', { p_business: biz, p: {
      momo_direct_enabled: true, momo_mtn_enabled: true, momo_mtn_number: '12345' } }), 'invalid_phone');
  });

  it('instructions that ask for a PIN, password or OTP are refused, and nothing is stored', async () => {
    for (const text of ['Enter your PIN to confirm', 'Send your OTP code', 'Give us your mot de passe', 'share the wallet password']) {
      await expectError(rpc(owner.client, 'store_save_payments', { p_business: biz, p: {
        momo_direct_enabled: true, momo_mtn_enabled: true, momo_mtn_number: '677000001', momo_mtn_instructions: text } }), 'payment_secret_not_allowed');
    }
    const [{ n }] = await sql<{ n: number }>(`select count(*)::int n from stores where business_id = $1 and momo_mtn_instructions ~* 'pin|otp'`, [biz]);
    expect(n).toBe(0);
  });

  it('only the owner or a manager with store rights can change payment details', async () => {
    const cashier = await addStaff(owner, biz, 'cashier');
    await expectError(rpc(cashier.client, 'store_save_payments', { p_business: biz, p: { momo_direct_enabled: false } }), 'permission_denied');
    await expectError(rpc(other.client, 'store_save_payments', { p_business: biz, p: { momo_direct_enabled: false } }), 'permission_denied');
  });

  it('a buyer of a Mobile Money order sees only the enabled method, labelled as seller-entered', async () => {
    await rpc(owner.client, 'store_set_published', { p_business: biz, p_publish: true });
    const tk = token();
    const o = await rpc<any>(anon(), 'market_place_order', { p: {
      client_ref: uid(), access_token: tk, items: [{ product_id: item.id, quantity: 1 }],
      delivery_method: 'pickup', payment_method: 'momo_direct',
      customer: { name: 'Awa Buyer', phone: phone(), email: 'awa@example.com' } } });
    const view = await rpc<any>(anon(), 'market_order_view', { p_order: o.order_id, p_token: tk });
    expect(view.store.momo.mtn).toMatchObject({ number: '677000001', name: 'Awa Shop' });
    expect(view.store.momo.orange).toBeNull();
    expect(view.store.momo).toMatchObject({ proof_required: true, source: 'seller_entered' });
  });

  it('the public store page never shows payment numbers', async () => {
    const store = await rpc<any>(anon(), 'market_store', { p_slug: slug });
    expect(JSON.stringify(store)).not.toContain('677000001');
    expect(JSON.stringify(store)).not.toContain('699000002');
  });

  it('when the seller turns direct payment off, new Mobile Money orders are refused', async () => {
    await rpc(owner.client, 'store_save_payments', { p_business: biz, p: { momo_direct_enabled: false, momo_mtn_enabled: true, momo_mtn_number: '677000001' } });
    const [{ momo_direct_enabled, momo_mtn_enabled }] = await sql<any>('select momo_direct_enabled, momo_mtn_enabled from stores where business_id = $1', [biz]);
    expect(momo_direct_enabled).toBe(false);
    expect(momo_mtn_enabled).toBe(false);
    await expectError(rpc(anon(), 'market_place_order', { p: {
      client_ref: uid(), access_token: token(), items: [{ product_id: item.id, quantity: 1 }],
      delivery_method: 'pickup', payment_method: 'momo_direct', customer: { name: 'Awa Buyer', phone: phone() } } }), 'payment_method_not_available');
  });
});
