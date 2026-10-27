// Order lifecycle: delivery and receipt are separate. The buyer confirms receipt or reports a problem, a review opens only
// for a completed order, a review can be edited once, and reviews and orders can be reported.
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { randomBytes } from 'node:crypto';
import { addProduct, anon, closeDb, createBusiness, createUser, expectError, openStock, rpc, sql, uid, type TestUser } from './helpers';

const token = () => randomBytes(24).toString('hex');
const order = (items: { product_id: string; quantity: number }[], extra: Record<string, unknown> = {}) => ({
  client_ref: uid(), access_token: token(), items, delivery_method: 'delivery', payment_method: 'cod',
  customer: { name: 'Awa Buyer', phone: `69${Math.floor(1e6 + Math.random() * 8.9e6)}`, email: 'awa@example.com' }, ...extra,
});

describe('order lifecycle: receipt, problems and reviews', () => {
  let owner: TestUser; let biz: string; let zone: string; let item: any;

  // A cash-on-delivery order from a buyer who keeps the access token, as a guest would.
  const place = async () => {
    const tk = token();
    const res = await rpc<any>(anon(), 'market_place_order', { p: order([{ product_id: item.id, quantity: 1 }],
      { zone_id: zone, access_token: tk, address: { region: 'littoral', city: 'Douala', line: 'Bonanjo' } }) });
    return { id: res.order_id as string, token: tk };
  };
  const deliver = async (id: string) => {
    await rpc(owner.client, 'market_order_action', { p_order: id, p_action: 'confirm' });
    await rpc(owner.client, 'market_order_action', { p_order: id, p_action: 'dispatch', p: {} });
    return rpc<any>(owner.client, 'market_order_action', { p_order: id, p_action: 'deliver', p: { cod_method: 'cash', received_by: 'Awa' } });
  };
  const placeDelivered = async () => {
    const o = await place();
    await deliver(o.id);
    return o;
  };
  const receipt = async (id: string) => (await sql<{ receipt_status: string }>('select receipt_status from market_orders where id = $1', [id]))[0].receipt_status;
  const view = (o: { id: string; token: string }) => rpc<any>(anon(), 'market_order_view', { p_order: o.id, p_token: o.token });
  const confirm = (o: { id: string; token: string }) =>
    rpc(anon(), 'market_order_customer_action', { p_order: o.id, p_token: o.token, p_action: 'received' });
  const reviewOf = (o: { id: string; token: string }, rating: number, comment?: string) =>
    rpc(anon(), 'market_submit_review', { p_order: o.id, p_token: o.token, p_product: item.id, p_rating: rating, p_comment: comment });
  const report = (o: { id: string; token: string }, reason: string, details?: string) =>
    rpc(anon(), 'market_report', { p: { target_type: 'order', target_id: o.id, token: o.token, reason, details } });
  const setDispute = (o: { id: string }, status: string) =>
    sql(`update market_reports set status = $2 where order_id = $1 and kind = 'dispute'`, [o.id, status]);

  beforeAll(async () => {
    await sql(`delete from rate_limits where key like 'order_%' or key like 'report_ip:%'`);
    owner = await createUser('life-owner');
    biz = await createBusiness(owner, 'Lifecycle Shop', { category: 'fashion' });
    await rpc(owner.client, 'store_save', { p_business: biz, p: { name: 'Lifecycle Shop', phone: '677000501', whatsapp: '677000501', city: 'Douala', pickup_enabled: false } });
    await rpc(owner.client, 'store_save_zones', { p_business: biz, p_zones: [
      { name: 'Littoral', fee: 1000, eta: 'Same day', regions: ['littoral'], localities: [] }] });
    zone = (await sql<{ id: string }>('select id from store_delivery_zones where business_id = $1', [biz]))[0].id;
    item = await addProduct(owner, biz, { name: 'Lifecycle shirt', selling_price: 5000, min_stock: 0 });
    await openStock(owner, biz, item.id, 50, 3000);
    await rpc(owner.client, 'products_set_online', { p_business: biz, p_ids: [item.id], p_online: true });
    await rpc(owner.client, 'store_set_published', { p_business: biz, p_publish: true });
  });
  afterAll(closeDb);

  it('a delivered order opens a receipt window that the buyer can close', async () => {
    const o = await place();
    const done = await deliver(o.id);
    expect(done.status).toBe('delivered');
    expect(await receipt(o.id)).toBe('awaiting');
    const [{ days }] = await sql<{ days: string }>(
      `select extract(epoch from (receipt_due_at - now())) / 86400 as days from market_orders where id = $1`, [o.id]);
    expect(Number(days)).toBeGreaterThan(2.9);
    expect(Number(days)).toBeLessThanOrEqual(3);
    expect(await view(o)).toMatchObject({ status: 'delivered', receipt_status: 'awaiting', can_confirm_receipt: true, can_review: false });
  });

  it('a review waits until the buyer confirms receipt', async () => {
    const o = await placeDelivered();
    await expectError(reviewOf(o, 5), 'review_requires_receipt');
  });

  it('confirming receipt is recorded once, with a timeline entry, and tells the seller', async () => {
    const o = await placeDelivered();
    await confirm(o);
    await confirm(o); // a second tap changes nothing and is not an error
    expect(await receipt(o.id)).toBe('confirmed');
    const events = await sql<{ actor: string; status: string; message: string }>(
      `select actor, status, message from market_order_events where order_id = $1 and kind = 'receipt'`, [o.id]);
    expect(events).toEqual([{ actor: 'customer', status: 'delivered', message: 'received_confirmed' }]);
    const notes = await sql(`select id from notifications where business_id = $1 and type = 'market_receipt' and link = $2`,
      [biz, `/app/orders/${o.id}`]);
    expect(notes).toHaveLength(1);
    expect(await view(o)).toMatchObject({ receipt_status: 'confirmed', can_confirm_receipt: false, can_report_problem: false, can_review: true });
  });

  it('after receipt is confirmed, the order cannot be reported as a problem', async () => {
    const o = await placeDelivered();
    await confirm(o);
    await expectError(report(o, 'not_delivered'), 'receipt_already_confirmed');
  });

  it('only the buyer who placed the order can confirm its receipt or read it', async () => {
    const o = await placeDelivered();
    const stranger = await createUser('life-stranger');
    await expectError(rpc(owner.client, 'market_order_customer_action', { p_order: o.id, p_token: 'not-the-token', p_action: 'received' }), 'not_found');
    await expectError(rpc(stranger.client, 'market_order_customer_action', { p_order: o.id, p_token: 'not-the-token', p_action: 'received' }), 'not_found');
    await expectError(rpc(stranger.client, 'market_order_view', { p_order: o.id, p_token: 'not-the-token' }), 'not_found');
    expect(await receipt(o.id)).toBe('awaiting');
  });

  it('a problem reported on delivery holds the receipt and blocks reviews until support decides', async () => {
    const o = await placeDelivered();
    await report(o, 'damaged', 'Zip is broken');
    expect(await receipt(o.id)).toBe('disputed');
    expect(await view(o)).toMatchObject({ receipt_status: 'disputed', can_confirm_receipt: false, can_review: false });
    await expectError(confirm(o), 'invalid_order_status');
    await expectError(reviewOf(o, 5), 'review_blocked_by_problem');
  });

  it('when support resolves the problem the receipt is released, and the buyer can confirm', async () => {
    const o = await placeDelivered();
    await report(o, 'wrong_item');
    await setDispute(o, 'resolved');
    expect(await receipt(o.id)).toBe('resolved');
    expect(await view(o)).toMatchObject({ can_confirm_receipt: true, can_review: true });
    await confirm(o);
    expect(await receipt(o.id)).toBe('confirmed');
  });

  it('when support dismisses the problem the receipt goes back to the buyer', async () => {
    const o = await placeDelivered();
    await report(o, 'not_delivered');
    await setDispute(o, 'dismissed');
    expect(await receipt(o.id)).toBe('awaiting');
    expect(await view(o)).toMatchObject({ can_confirm_receipt: true });
  });

  it('a review opens when the receipt window passes with no problem, and nothing is confirmed for the buyer', async () => {
    const o = await placeDelivered();
    await expectError(reviewOf(o, 4), 'review_requires_receipt');
    await sql(`update market_orders set receipt_due_at = now() - interval '1 hour' where id = $1`, [o.id]);
    expect(await reviewOf(o, 4)).toBeTruthy();
    expect(await receipt(o.id)).toBe('awaiting');
  });

  it('a problem reported while the order is on its way is still open when it is delivered', async () => {
    const o = await place();
    await rpc(owner.client, 'market_order_action', { p_order: o.id, p_action: 'confirm' });
    await rpc(owner.client, 'market_order_action', { p_order: o.id, p_action: 'dispatch', p: {} });
    await report(o, 'not_delivered');
    const done = await rpc<any>(owner.client, 'market_order_action', { p_order: o.id, p_action: 'deliver', p: { cod_method: 'cash' } });
    expect(done.status).toBe('delivered');
    expect(await receipt(o.id)).toBe('disputed');
  });

  it('an order delivered before receipts existed keeps working as it did', async () => {
    const o = await placeDelivered();
    await sql(`update market_orders set receipt_status = 'none', receipt_due_at = null where id = $1`, [o.id]);
    expect(await view(o)).toMatchObject({ can_confirm_receipt: false, can_review: true });
    expect(await reviewOf(o, 5)).toBeTruthy();
  });

  it('a review can be edited once within 48 hours, and the edit is marked', async () => {
    const o = await placeDelivered();
    await confirm(o);
    await reviewOf(o, 3, 'Okay');
    await reviewOf(o, 5, 'Better after washing');
    const v = await view(o);
    expect(v.lines[0].review).toMatchObject({ rating: 5, comment: 'Better after washing', can_edit: false });
    expect(v.lines[0].review.edited_at).toBeTruthy();
    await expectError(reviewOf(o, 1), 'already_reviewed');
  });

  it('after 48 hours a review can no longer be edited', async () => {
    const o = await placeDelivered();
    await confirm(o);
    await reviewOf(o, 3);
    await sql(`update market_reviews set created_at = now() - interval '3 days' where order_id = $1`, [o.id]);
    await expectError(reviewOf(o, 5), 'review_edit_closed');
  });

  it('a review can be reported; a signed-out reporter must leave a way to reach them', async () => {
    const o = await placeDelivered();
    await confirm(o);
    await reviewOf(o, 1, 'Not as described');
    const [{ id: reviewId }] = await sql<{ id: string }>('select id from market_reviews where order_id = $1', [o.id]);
    await expectError(rpc(anon(), 'market_report', { p: { target_type: 'review', target_id: reviewId, reason: 'misleading' } }), 'contact_required');
    await rpc(anon(), 'market_report', { p: { target_type: 'review', target_id: reviewId, reason: 'misleading', contact: 'awa@example.com' } });
    const rows = await sql(`select kind, target_type, status from market_reports where target_id = $1`, [reviewId]);
    expect(rows).toEqual([{ kind: 'report', target_type: 'review', status: 'open' }]);
  });
});
