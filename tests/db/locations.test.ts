// Locations and delivery areas: the ten regions and maintained localities, a seller's delivery areas, and the
// server-side check that an order is delivered only inside the zone the seller configured for it.
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { randomBytes } from 'node:crypto';
import { addProduct, anon, closeDb, createBusiness, createUser, expectError, openStock, rpc, sql, uid, type TestUser } from './helpers';

const token = () => randomBytes(24).toString('hex');
const order = (items: { product_id: string; quantity: number }[], extra: Record<string, unknown> = {}) => ({
  client_ref: uid(), access_token: token(), items, delivery_method: 'delivery', payment_method: 'cod',
  customer: { name: 'Awa Buyer', phone: `69${Math.floor(1e6 + Math.random() * 8.9e6)}`, email: 'awa@example.com' }, ...extra,
});

describe('locations and delivery areas', () => {
  let owner: TestUser; let biz: string; let slug: string; let item: any;
  let littoralZone: string; let yaoundeZone: string; let anyZone: string;

  beforeAll(async () => {
    await sql(`delete from rate_limits where key like 'order_%' or key like 'order_phone:%'`);
    owner = await createUser('loc-owner');
    biz = await createBusiness(owner, 'Locations Shop', { category: 'fashion' });
    await rpc(owner.client, 'store_save', { p_business: biz, p: { name: 'Locations Shop', phone: '677000401', whatsapp: '677000401', city: 'Douala', pickup_enabled: true } });
    await rpc(owner.client, 'store_save_zones', { p_business: biz, p_zones: [
      { name: 'Littoral', fee: 1000, eta: 'Same day', regions: ['littoral'], localities: [] },
      { name: 'Yaoundé town', fee: 2000, eta: '24 h', regions: [], localities: ['yaounde'] },
      { name: 'Any area (older zone)', fee: 500 },
    ] });
    [{ slug }] = await sql<{ slug: string }>('select slug from stores where business_id = $1', [biz]);
    const zones = await sql<{ id: string; name: string }>('select id, name from store_delivery_zones where business_id = $1', [biz]);
    littoralZone = zones.find((z) => z.name === 'Littoral')!.id;
    yaoundeZone = zones.find((z) => z.name === 'Yaoundé town')!.id;
    anyZone = zones.find((z) => z.name === 'Any area (older zone)')!.id;
    item = await addProduct(owner, biz, { name: 'Located shirt', selling_price: 5000, min_stock: 0 });
    await openStock(owner, biz, item.id, 50, 3000);
    await rpc(owner.client, 'products_set_online', { p_business: biz, p_ids: [item.id], p_online: true });
    await rpc(owner.client, 'store_set_published', { p_business: biz, p_publish: true });
  });
  afterAll(closeDb);

  it('the list has the ten regions and the maintained localities', async () => {
    const list = await rpc<any>(anon(), 'market_locations');
    expect(list.regions.map((r: any) => r.code).sort()).toEqual(
      ['adamawa', 'centre', 'east', 'far_north', 'littoral', 'north', 'northwest', 'south', 'southwest', 'west']);
    expect(list.localities).toEqual(expect.arrayContaining([
      expect.objectContaining({ region: 'littoral', name: 'Douala', key: 'douala' }),
      expect.objectContaining({ region: 'centre', name: 'Yaoundé', key: 'yaounde' }),
    ]));
  });

  it('the seller’s areas are saved with their regions and localities', async () => {
    const rows = await sql<{ name: string; regions: string[]; localities: string[] }>(
      'select name, regions, localities from store_delivery_zones where business_id = $1 order by sort', [biz]);
    expect(rows[0]).toMatchObject({ name: 'Littoral', regions: ['littoral'], localities: [] });
    expect(rows[1]).toMatchObject({ name: 'Yaoundé town', regions: [], localities: ['yaounde'] });
    expect(rows[2]).toMatchObject({ name: 'Any area (older zone)', regions: [], localities: [] });
  });

  it('a locality that is not in the maintained list cannot be added to a zone', async () => {
    await expectError(rpc(owner.client, 'store_save_zones', { p_business: biz, p_zones: [
      { id: littoralZone, name: 'Littoral', fee: 1000, localities: ['nowhere-town'] }] }), 'zone_locality_unknown');
  });

  it('a region that does not exist cannot be added to a zone', async () => {
    await expect(rpc(owner.client, 'store_save_zones', { p_business: biz, p_zones: [
      { id: littoralZone, name: 'Littoral', fee: 1000, regions: ['mars'] }] })).rejects.toBeTruthy();
  });

  it('an order to a location inside the zone is placed, and keeps its region', async () => {
    const buyer = anon();
    const res = await rpc<any>(buyer, 'market_place_order', { p: order([{ product_id: item.id, quantity: 1 }],
      { zone_id: littoralZone, address: { region: 'littoral', city: 'Douala', line: 'Rue Joss' } }) });
    expect(res.number).toMatch(/ORD-/);
    const [{ region, city }] = await sql<{ region: string; city: string }>(
      `select address->>'region' as region, address->>'city' as city from market_orders where id = $1`, [res.order_id]);
    expect(region).toBe('littoral');
    expect(city).toBe('Douala');
  });

  it('an order outside the zone is refused by the server, whatever the browser shows', async () => {
    await expectError(rpc(anon(), 'market_place_order', { p: order([{ product_id: item.id, quantity: 1 }],
      { zone_id: littoralZone, address: { region: 'centre', city: 'Yaoundé', line: 'Bastos' } }) }), 'zone_not_serving_location');
  });

  it('a zone for listed localities serves that locality, and refuses a typed town it does not cover', async () => {
    const ok = await rpc<any>(anon(), 'market_place_order', { p: order([{ product_id: item.id, quantity: 1 }],
      { zone_id: yaoundeZone, address: { region: 'centre', city: 'Yaoundé', line: 'Mvog-Ada' } }) });
    expect(ok.number).toMatch(/ORD-/);
    await expectError(rpc(anon(), 'market_place_order', { p: order([{ product_id: item.id, quantity: 1 }],
      { zone_id: yaoundeZone, address: { region: 'centre', city: 'Mfou', line: 'Route principale' } }) }), 'zone_not_serving_location');
  });

  it('a zone with no restriction keeps working for any region (older zones are not changed)', async () => {
    const res = await rpc<any>(anon(), 'market_place_order', { p: order([{ product_id: item.id, quantity: 1 }],
      { zone_id: anyZone, address: { region: 'north', city: 'Garoua', line: 'Quartier Plan' } }) });
    expect(res.number).toMatch(/ORD-/);
  });

  it('a delivery needs one of the ten regions', async () => {
    await expectError(rpc(anon(), 'market_place_order', { p: order([{ product_id: item.id, quantity: 1 }],
      { zone_id: anyZone, address: { city: 'Douala', line: 'Akwa' } }) }), 'region_required');
    await expectError(rpc(anon(), 'market_place_order', { p: order([{ product_id: item.id, quantity: 1 }],
      { zone_id: anyZone, address: { region: 'mars', city: 'Douala', line: 'Akwa' } }) }), 'region_required');
  });

  it('the store page shows each zone’s coverage, so the checkout offers only zones that serve the location', async () => {
    const store = await rpc<any>(anon(), 'market_store', { p_slug: slug });
    const littoral = store.zones.find((z: any) => z.name === 'Littoral');
    expect(littoral).toMatchObject({ regions: ['littoral'], localities: [] });
    expect(store.zones.find((z: any) => z.name === 'Any area (older zone)')).toMatchObject({ regions: [], localities: [] });
  });

  // Runs last: saving only one zone removes the others (the seller's list is the whole list).
  it('an older app that sends no areas leaves a zone’s restrictions as they are', async () => {
    await rpc(owner.client, 'store_save_zones', { p_business: biz, p_zones: [{ id: littoralZone, name: 'Littoral', fee: 1000 }] });
    const [{ regions }] = await sql<{ regions: string[] }>('select regions from store_delivery_zones where id = $1', [littoralZone]);
    expect(regions).toEqual(['littoral']);
  });
});
