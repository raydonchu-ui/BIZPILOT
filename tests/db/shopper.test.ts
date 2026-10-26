// Shopper: the city selector really filters shops and products (accents and capitals do not matter),
// and the shopper dashboard numbers come from the signed-in shopper's own orders only.
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { addProduct, anon, closeDb, createBusiness, createUser, expectError, openStock, rpc, sql, type TestUser } from './helpers';

describe('shopper: city filtering and dashboard', () => {
  let yaoundeOwner: TestUser; let doualaOwner: TestUser;
  let yaoundeBiz: string; let doualaBiz: string;
  let yaoundeProduct: string; let doualaProduct: string;

  beforeAll(async () => {
    yaoundeOwner = await createUser('city-yde');
    yaoundeBiz = await createBusiness(yaoundeOwner, 'Yaounde City Shop', { category: 'fashion' });
    await rpc(yaoundeOwner.client, 'store_save', { p_business: yaoundeBiz, p: { name: 'Yaounde City Shop', phone: '677000201', whatsapp: '677000201', city: 'Yaoundé', pickup_enabled: true } });
    const yp = await addProduct(yaoundeOwner, yaoundeBiz, { name: 'Yaounde city hat', selling_price: 5000, min_stock: 0 });
    yaoundeProduct = yp.id;
    await openStock(yaoundeOwner, yaoundeBiz, yaoundeProduct, 5, 2000);
    await rpc(yaoundeOwner.client, 'products_set_online', { p_business: yaoundeBiz, p_ids: [yaoundeProduct], p_online: true });
    await rpc(yaoundeOwner.client, 'store_set_published', { p_business: yaoundeBiz, p_publish: true });

    doualaOwner = await createUser('city-dla');
    doualaBiz = await createBusiness(doualaOwner, 'Douala City Shop', { category: 'fashion' });
    await rpc(doualaOwner.client, 'store_save', { p_business: doualaBiz, p: { name: 'Douala City Shop', phone: '677000202', whatsapp: '677000202', city: 'Douala', pickup_enabled: true } });
    const dp = await addProduct(doualaOwner, doualaBiz, { name: 'Douala city bag', selling_price: 7000, min_stock: 0 });
    doualaProduct = dp.id;
    await openStock(doualaOwner, doualaBiz, doualaProduct, 5, 3000);
    await rpc(doualaOwner.client, 'products_set_online', { p_business: doualaBiz, p_ids: [doualaProduct], p_online: true });
    await rpc(doualaOwner.client, 'store_set_published', { p_business: doualaBiz, p_publish: true });
  });
  afterAll(closeDb);

  it('shops in a city are listed for that city only', async () => {
    const page = await rpc<any>(anon(), 'market_shops', { p: { city: 'Yaoundé', page: 1, page_size: 200 } });
    const ids = page.items.map((x: any) => x.business_id);
    expect(ids).toContain(yaoundeBiz);
    expect(ids).not.toContain(doualaBiz);
  });

  it('the city match ignores capitals and accents', async () => {
    const plain = await rpc<any>(anon(), 'market_shops', { p: { city: 'yaounde', page: 1, page_size: 200 } });
    expect(plain.items.map((x: any) => x.business_id)).toContain(yaoundeBiz);
    const upper = await rpc<any>(anon(), 'market_shops', { p: { city: '  DOUALA ', page: 1, page_size: 200 } });
    expect(upper.items.map((x: any) => x.business_id)).toContain(doualaBiz);
    expect(upper.items.map((x: any) => x.business_id)).not.toContain(yaoundeBiz);
  });

  it('product search is filtered by the same city', async () => {
    const inDouala = await rpc<any>(anon(), 'market_search', { p: { city: 'Douala', sort: 'newest', page_size: 200 } });
    const names = inDouala.items.map((x: any) => x.name);
    expect(names).toContain('Douala city bag');
    expect(names).not.toContain('Yaounde city hat');
    const all = await rpc<any>(anon(), 'market_search', { p: { sort: 'newest', page_size: 200 } });
    expect(all.items.map((x: any) => x.name)).toEqual(expect.arrayContaining(['Douala city bag', 'Yaounde city hat']));
  });

  it('the home counts are real for the chosen city and for all of Cameroon', async () => {
    const home = await rpc<any>(anon(), 'market_home', { p_city: 'Yaoundé' });
    expect(home.city_shops).toBeGreaterThanOrEqual(1);
    expect(home.city_products).toBeGreaterThanOrEqual(1);
    const nationwide = await rpc<any>(anon(), 'market_home', { p_city: null });
    const yde = (nationwide.cities as { city: string; shops: number }[]).find((c) => c.city === 'Yaoundé');
    expect(yde?.shops).toBe(home.city_shops);
  });

  it('the shopper dashboard needs a signed-in shopper', async () => {
    await expectError(rpc(anon(), 'buyer_dashboard'), /permission denied|not_authenticated/);
  });

  it('a new shopper sees zero orders, favourites and followed shops', async () => {
    const shopper = await createUser('city-shopper');
    const dash = await rpc<any>(shopper.client, 'buyer_dashboard');
    expect(dash.orders).toEqual({ pending: 0, processing: 0, shipped: 0, delivered: 0 });
    expect(dash.favorites).toBe(0);
    expect(dash.followed_shops).toBe(0);
  });
});
