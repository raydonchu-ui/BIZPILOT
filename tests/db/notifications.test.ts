// Notifications and support: buyers hear about their orders, preferences are enforced by the database, support replies
// reach the seller, renewals are reminded once per period, and old read notices are removed.
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { randomBytes } from 'node:crypto';
import { addProduct, admin, anon, closeDb, createBusiness, createUser, expectError, openStock, rpc, sql, uid, type TestUser } from './helpers';

const token = () => randomBytes(24).toString('hex');
const phone = () => `69${Math.floor(1e6 + Math.random() * 8.9e6)}`;

describe('notifications, preferences and support', () => {
  let owner: TestUser; let buyer: TestUser; let platformAdmin: TestUser; let biz: string; let zone: string; let item: any;
  const inbox = async (uidv: string, kind = 'order_update') =>
    sql<{ preview: string; link: string }>('select preview, link from inbox_notifications where user_id = $1 and kind = $2 order by created_at', [uidv, kind]);

  beforeAll(async () => {
    owner = await createUser('nt-owner');
    buyer = await createUser('nt-buyer');
    platformAdmin = await createUser('nt-admin');
    await sql('select app.bootstrap_platform_admin($1)', [platformAdmin.email]);
    biz = await createBusiness(owner, 'Notify Shop', { category: 'fashion' });
    await rpc(owner.client, 'store_save', { p_business: biz, p: { name: 'Notify Shop', phone: '677000801', whatsapp: '677000801', city: 'Douala' } });
    await rpc(owner.client, 'store_save_zones', { p_business: biz, p_zones: [{ name: 'Littoral', fee: 500, eta: 'Today', regions: ['littoral'], localities: [] }] });
    zone = (await sql<{ id: string }>('select id from store_delivery_zones where business_id = $1', [biz]))[0].id;
    await rpc(owner.client, 'store_save_payments', { p_business: biz, p: { cod_enabled: true } });
    item = await addProduct(owner, biz, { name: 'Notice shirt', selling_price: 2000, min_stock: 0 });
    await openStock(owner, biz, item.id, 20, 800);
    await rpc(owner.client, 'products_set_online', { p_business: biz, p_ids: [item.id], p_online: true });
    await rpc(owner.client, 'store_set_published', { p_business: biz, p_publish: true });
  });
  afterAll(closeDb);

  const placeSigned = async () => {
    const res = await rpc<any>(buyer.client, 'market_place_order', { p: {
      client_ref: uid(), access_token: token(), items: [{ product_id: item.id, quantity: 1 }], delivery_method: 'delivery',
      payment_method: 'cod', zone_id: zone, address: { region: 'littoral', city: 'Douala', line: 'Bonanjo' },
      customer: { name: 'Buyer Name', phone: phone(), email: 'buyer@example.com' } } });
    return res.order_id as string;
  };

  it('a buyer with an account is told when the order is dispatched, delivered, and when receipt is confirmed', async () => {
    const o = await placeSigned();
    await rpc(owner.client, 'market_order_action', { p_order: o, p_action: 'confirm' });
    await rpc(owner.client, 'market_order_action', { p_order: o, p_action: 'dispatch', p: {} });
    await rpc(owner.client, 'market_order_action', { p_order: o, p_action: 'deliver', p: { cod_method: 'cash' } });
    const rows = await inbox(buyer.id);
    expect(rows.map((r) => r.preview).join(' | ')).toMatch(/on its way/);
    expect(rows.map((r) => r.preview).join(' | ')).toMatch(/Please confirm you received it/);
    expect(rows.every((r) => r.link === `/order/${o}`)).toBe(true);
    await rpc(buyer.client, 'market_order_customer_action', { p_order: o, p_token: null, p_action: 'received' });
    const [{ receipt_status }] = await sql<any>('select receipt_status from market_orders where id = $1', [o]);
    expect(receipt_status).toBe('confirmed');
    expect((await inbox(buyer.id)).map((r) => r.preview).join(' | ')).toMatch(/You can now rate/);
  });

  it('a guest order produces no account notice (guests follow their order link)', async () => {
    const before = (await sql<any>(`select count(*)::int n from inbox_notifications where kind = 'order_update'`))[0].n;
    const res = await rpc<any>(anon(), 'market_place_order', { p: {
      client_ref: uid(), access_token: token(), items: [{ product_id: item.id, quantity: 1 }], delivery_method: 'delivery',
      payment_method: 'cod', zone_id: zone, address: { region: 'littoral', city: 'Douala', line: 'Akwa' },
      customer: { name: 'Guest Person', phone: phone(), email: 'guest@example.com' } } });
    await rpc(owner.client, 'market_order_action', { p_order: res.order_id, p_action: 'confirm' });
    await rpc(owner.client, 'market_order_action', { p_order: res.order_id, p_action: 'dispatch', p: {} });
    expect((await sql<any>(`select count(*)::int n from inbox_notifications where kind = 'order_update'`))[0].n).toBe(before);
  });

  it('turning off order notices stores nothing more for that account; turning them on again restores them', async () => {
    await rpc(buyer.client, 'set_notification_preference', { p_category: 'orders', p_enabled: false });
    expect(await rpc<any>(buyer.client, 'my_notification_preferences')).toMatchObject({ orders: false, messages: true });
    const before = (await inbox(buyer.id)).length;
    const o = await placeSigned();
    await rpc(owner.client, 'market_order_action', { p_order: o, p_action: 'confirm' });
    await rpc(owner.client, 'market_order_action', { p_order: o, p_action: 'dispatch', p: {} });
    expect((await inbox(buyer.id)).length).toBe(before);
    await rpc(buyer.client, 'set_notification_preference', { p_category: 'orders', p_enabled: true });
    await expectError(rpc(buyer.client, 'set_notification_preference', { p_category: 'marketing', p_enabled: false }), 'invalid_request');
  });

  it('a creator notice is also dropped when the creator has turned that kind off', async () => {
    await sql(`insert into notification_preferences (user_id, category, enabled) values ($1, 'creator', false)`, [buyer.id]);
    await sql(`insert into inbox_notifications (user_id, kind, from_name, preview, link) values ($1, 'creator_commission', 'BizPilot', 'x', '/creator')`, [buyer.id]);
    expect((await inbox(buyer.id, 'creator_commission'))).toHaveLength(0);
    await sql(`delete from notification_preferences where user_id = $1 and category = 'creator'`, [buyer.id]);
  });

  it('a support reply reaches the business and the person who asked, with a link to the right place', async () => {
    const rid = await rpc<string>(owner.client, 'submit_support_request', { p: { business_id: biz, category: 'billing', subject: 'Invoice question', message: 'Please check my invoice.' } });
    await rpc(platformAdmin.client, 'admin_respond_support', { p_request: rid, p_status: 'resolved', p_response: 'Your invoice is correct.' });
    const [n] = await sql<any>(`select link from notifications where business_id = $1 and type = 'support_response'`, [biz]);
    expect(n.link).toBe('/app/help');
    const rows = await inbox(owner.id, 'support_reply');
    expect(rows.map((r) => r.preview).join(' ')).toMatch(/Your invoice is correct/);
  });

  it('a renewal reminder is made once per paid period, not again the same day', async () => {
    await sql(`update business_subscriptions set status = 'active', plan_code = 'business', current_period_end = now() + interval '3 days',
               current_period_start = now() - interval '27 days', cancel_at_period_end = false where business_id = $1`, [biz]);
    const first = await sql<{ n: number }>('select app.send_renewal_reminders() as n');
    expect(first[0].n).toBeGreaterThanOrEqual(1);
    const second = await sql<{ n: number }>('select app.send_renewal_reminders() as n');
    expect(second[0].n).toBe(0);
    const [{ link }] = await sql<any>(`select link from notifications where business_id = $1 and type = 'subscription_renewal'`, [biz]);
    expect(link).toBe('/app/billing');
  });

  it('old notices that have been read are removed; unread ones are kept', async () => {
    await sql(`insert into inbox_notifications (user_id, kind, from_name, preview, link, created_at, read_at)
      values ($1, 'order_update', 'BizPilot', 'old read', '/x', now() - interval '200 days', now() - interval '199 days'),
             ($1, 'order_update', 'BizPilot', 'old unread', '/x', now() - interval '200 days', null)`, [buyer.id]);
    await sql('select app.prune_notifications(90)');
    const left = await sql<any>(`select preview from inbox_notifications where user_id = $1 and preview like 'old %'`, [buyer.id]);
    expect(left.map((r: any) => r.preview)).toEqual(['old unread']);
  });

  it('a person cannot read another person’s preferences or inbox', async () => {
    const seen = await owner.client.from('notification_preferences').select('user_id').eq('user_id', buyer.id);
    expect(seen.data ?? []).toEqual([]);
    const inboxSeen = await owner.client.from('inbox_notifications').select('id').eq('user_id', buyer.id);
    expect(inboxSeen.data ?? []).toEqual([]);
  });
});
