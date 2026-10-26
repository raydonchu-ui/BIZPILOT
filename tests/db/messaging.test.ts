// Messaging: a shopper writes to a store about a product; the store's team answers. Each side sees only its
// own conversations, unread counts and inbox rows follow who has read what, and writes go through the
// functions only (direct inserts, updates and other people's inboxes are refused by the database).
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { addProduct, addStaff, anon, closeDb, createBusiness, createUser, expectError, openStock, rpc, sql, type TestUser } from './helpers';

describe('messaging: buyer and store conversations, unread counts, inbox', () => {
  let owner: TestUser; let cashier: TestUser; let shopper: TestUser; let outsider: TestUser;
  let slug: string; let product: any; let conv: string;

  beforeAll(async () => {
    owner = await createUser('msg-owner');
    const biz = await createBusiness(owner, 'Messaging Shop', { category: 'fashion' });
    await rpc(owner.client, 'store_save', { p_business: biz, p: { name: 'Messaging Shop', phone: '677000301', whatsapp: '677000301',
      city: 'Yaoundé', pickup_enabled: true, opening_hours: { mon: { open: '08:00', close: '19:00' } } } });
    [{ slug }] = await sql<{ slug: string }>('select slug from stores where business_id = $1', [biz]);
    product = await addProduct(owner, biz, { name: 'Messaging dress', selling_price: 9000, min_stock: 0 });
    await openStock(owner, biz, product.id, 5, 4000);
    await rpc(owner.client, 'products_set_online', { p_business: biz, p_ids: [product.id], p_online: true });
    await rpc(owner.client, 'store_set_published', { p_business: biz, p_publish: true });
    cashier = await addStaff(owner, biz, 'cashier');
    shopper = await createUser('msg-shopper');
    outsider = await createUser('msg-outsider');
  });
  afterAll(closeDb);

  it('signed-out visitors cannot start a conversation', async () => {
    await expectError(rpc(anon(), 'msg_start', { p_store: slug, p_product: product.id, p_body: 'Hi' }), /not_authenticated|permission denied/);
  });

  it('a shopper starts a conversation about a product; the store team sees it as unread', async () => {
    const started = await rpc<any>(shopper.client, 'msg_start', { p_store: slug, p_product: product.id, p_body: 'Is the dress available in size M?' });
    conv = started.conversation_id;
    expect(conv).toBeTruthy();
    const mine = await rpc<any[]>(shopper.client, 'msg_list', {});
    expect(mine.find((c) => c.id === conv)).toMatchObject({ side: 'buyer', store_slug: slug, product_name: 'Messaging dress', unread: 0 });
    const theirs = await rpc<any[]>(owner.client, 'msg_list', {});
    expect(theirs.find((c) => c.id === conv)).toMatchObject({ side: 'seller', unread: 1 });
    expect(await rpc<number>(owner.client, 'msg_unread')).toBeGreaterThanOrEqual(1);
  });

  it('a second message about the same product stays in the same conversation', async () => {
    const again = await rpc<any>(shopper.client, 'msg_start', { p_store: slug, p_product: product.id, p_body: 'Do you deliver to Douala?' });
    expect(again.conversation_id).toBe(conv);
    const [{ n }] = await sql<{ n: number }>('select count(*)::int n from messages where conversation_id = $1', [conv]);
    expect(n).toBe(2);
  });

  it('the team gets an inbox row for each member, never the shopper', async () => {
    const rows = await sql<{ user_id: string; from_name: string; link: string }>(
      'select user_id, from_name, link from inbox_notifications where conversation_id = $1', [conv]);
    const ids = rows.map((r) => r.user_id);
    expect(ids).toEqual(expect.arrayContaining([owner.id, cashier.id]));
    expect(ids).not.toContain(shopper.id);
    expect(rows[0]).toMatchObject({ from_name: 'Customer', link: `/messages/${conv}` });
  });

  it('a cashier answers for the store; the shopper gets the reply in the inbox and as unread', async () => {
    await rpc(cashier.client, 'msg_send', { p_conversation: conv, p_body: 'Yes, size M is in stock.' });
    const mine = await rpc<any[]>(shopper.client, 'msg_list', {});
    expect(mine.find((c) => c.id === conv)).toMatchObject({ unread: 1, last_message_preview: 'Yes, size M is in stock.' });
    const [row] = await sql<{ from_name: string; preview: string }>(
      'select from_name, preview from inbox_notifications where user_id = $1 and conversation_id = $2 and preview like $3', [shopper.id, conv, 'Yes%']);
    expect(row).toMatchObject({ from_name: 'Messaging Shop', preview: 'Yes, size M is in stock.' });
    const theirs = await rpc<any[]>(cashier.client, 'msg_list', {});
    // Replying marks the conversation read for the store side too.
    expect(theirs.find((c) => c.id === conv)).toMatchObject({ side: 'seller', unread: 0 });
  });

  it('marking read clears the unread count and the inbox rows for that conversation', async () => {
    await rpc(shopper.client, 'msg_mark_read', { p_conversation: conv });
    expect((await rpc<any[]>(shopper.client, 'msg_list', {})).find((c) => c.id === conv)).toMatchObject({ unread: 0 });
    const [{ n }] = await sql<{ n: number }>('select count(*)::int n from inbox_notifications where user_id = $1 and conversation_id = $2 and read_at is null', [shopper.id, conv]);
    expect(n).toBe(0);
  });

  it('the conversation header carries the store and the product card', async () => {
    const buyerView = await rpc<any>(shopper.client, 'msg_thread', { p_conversation: conv });
    expect(buyerView).toMatchObject({ side: 'buyer', store_name: 'Messaging Shop', store_slug: slug, counterpart: 'Messaging Shop' });
    expect(buyerView.product).toMatchObject({ id: product.id, name: 'Messaging dress', price: 9000 });
    const sellerView = await rpc<any>(cashier.client, 'msg_thread', { p_conversation: conv });
    expect(sellerView).toMatchObject({ side: 'seller', counterpart: 'Customer' });
  });

  it('other shoppers and other stores cannot see, read or answer the conversation', async () => {
    expect((await rpc<any[]>(outsider.client, 'msg_list', {})).some((c) => c.id === conv)).toBe(false);
    await expectError(rpc(outsider.client, 'msg_thread', { p_conversation: conv }), 'not_found');
    await expectError(rpc(outsider.client, 'msg_send', { p_conversation: conv, p_body: 'Hi' }), 'not_found');
    await expectError(rpc(outsider.client, 'msg_mark_read', { p_conversation: conv }), 'not_found');
    const leakedMessages = await outsider.client.from('messages').select('id').eq('conversation_id', conv);
    expect(leakedMessages.data ?? []).toEqual([]);
    const leakedInbox = await outsider.client.from('inbox_notifications').select('id').eq('conversation_id', conv);
    expect(leakedInbox.data ?? []).toEqual([]);
  });

  it('the database refuses messages the rules do not allow', async () => {
    await expectError(rpc(owner.client, 'msg_start', { p_store: slug, p_product: product.id, p_body: 'Hi' }), 'own_store');
    await expectError(rpc(shopper.client, 'msg_start', { p_store: slug, p_product: product.id, p_body: '   ' }), 'message_empty');
    await expectError(rpc(shopper.client, 'msg_start', { p_store: slug, p_product: product.id, p_body: 'x'.repeat(2001) }), 'message_too_long');
    await expectError(rpc(shopper.client, 'msg_start', { p_store: slug, p_product: '00000000-0000-0000-0000-000000000001', p_body: 'Hi' }), 'product_unavailable');
    await expectError(rpc(shopper.client, 'msg_start', { p_store: 'no-such-store', p_body: 'Hi' }), 'store_not_found');
  });

  it('a store that is not published cannot be written to', async () => {
    const draftOwner = await createUser('msg-draft');
    const draftBiz = await createBusiness(draftOwner, 'Draft Messaging Shop', { category: 'fashion' });
    await rpc(draftOwner.client, 'store_save', { p_business: draftBiz, p: { name: 'Draft Messaging Shop', city: 'Douala' } });
    const [{ slug: draftSlug }] = await sql<{ slug: string }>('select slug from stores where business_id = $1', [draftBiz]);
    await expectError(rpc(shopper.client, 'msg_start', { p_store: draftSlug, p_body: 'Hi' }), 'store_not_found');
  });

  it('writes cannot bypass the functions: direct inserts and updates change nothing', async () => {
    const insert = await shopper.client.from('messages').insert({ conversation_id: conv, sender_id: shopper.id, side: 'buyer', body: 'sneaky' });
    expect(insert.error).not.toBeNull();
    const update = await shopper.client.from('conversations').update({ product_name: 'changed' }).eq('id', conv).select('id');
    expect(update.data ?? []).toEqual([]);
    const inboxUpdate = await shopper.client.from('inbox_notifications').update({ read_at: null }).eq('user_id', shopper.id).select('id');
    expect(inboxUpdate.data ?? []).toEqual([]);
    const [{ product_name, n }] = await sql<{ product_name: string; n: number }>(
      'select c.product_name, (select count(*)::int from messages m where m.conversation_id = c.id) n from conversations c where c.id = $1', [conv]);
    expect(product_name).toBe('Messaging dress');
    expect(n).toBe(3);
  });

  it('push subscriptions belong to their owner', async () => {
    const run = Date.now(); // endpoints are unique: a rerun must not collide with the rows of an earlier run
    const own = await shopper.client.from('push_subscriptions').insert({ user_id: shopper.id, endpoint: `https://push.example/own-${run}`, p256dh: 'k', auth: 'a' });
    expect(own.error).toBeNull();
    const stolen = await outsider.client.from('push_subscriptions').insert({ user_id: shopper.id, endpoint: `https://push.example/stolen-${run}`, p256dh: 'k', auth: 'a' });
    expect(stolen.error).not.toBeNull();
    const seen = await outsider.client.from('push_subscriptions').select('id').eq('user_id', shopper.id);
    expect(seen.data ?? []).toEqual([]);
  });
});
