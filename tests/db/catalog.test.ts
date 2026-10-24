import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { addStaff, closeDb, createBusiness, createUser, expectError, product, rpc, sell, sql, type TestUser } from './helpers';

describe('flexible catalogue: categories, optional fields, SKU, attributes, variants', () => {
  let owner: TestUser; let biz: string;
  beforeAll(async () => {
    owner = await createUser('cat-owner');
    biz = await createBusiness(owner, 'Mode Shop', {
      category: 'fashion',
      categories: [
        { name: 'Men', attribute_set: 'clothing', children: ['T-shirts', 'Jeans', 'Jackets'] },
        { name: 'Women', attribute_set: 'clothing', children: ['T-shirts', 'Dresses'] },
        { name: 'Accessories', children: ['Bags', 'Belts'] },
      ],
    });
  });
  afterAll(closeDb);

  it('creates the categories chosen during onboarding, with subcategories (same name allowed under different parents)', async () => {
    const rows = await sql<{ name: string; parent: string | null; attribute_set: string | null }>(
      `select c.name, p.name parent, c.attribute_set from categories c left join categories p on p.id = c.parent_id where c.business_id = $1 order by p.name nulls first, c.sort_order`, [biz]);
    expect(rows.filter((r) => !r.parent).map((r) => r.name)).toEqual(['Men', 'Women', 'Accessories']);
    expect(rows.filter((r) => r.parent === 'Men').map((r) => r.name)).toEqual(['T-shirts', 'Jeans', 'Jackets']);
    expect(rows.filter((r) => r.name === 'T-shirts')).toHaveLength(2);
    expect(rows.find((r) => r.name === 'Men')!.attribute_set).toBe('clothing');
  });

  it('accepts the new business types and keeps the defaults for clients that send no categories', async () => {
    const u = await createUser('cat-types');
    for (const category of ['hair_beauty', 'footwear', 'pets', 'supermarket']) {
      const b = await createBusiness(u, `Shop ${category}`, { category });
      const [{ n }] = await sql<{ n: string }>('select count(*) n from categories where business_id = $1', [b]);
      expect(Number(n)).toBeGreaterThan(0);
    }
    await expectError(createBusiness(u, 'Bad', { category: 'casino' }), 'invalid_category');
  });

  it('adds suggested categories later without duplicates and restores archived ones', async () => {
    const before = await sql('select count(*)::int n from categories where business_id = $1', [biz]);
    await sql(`update categories set archived_at = now() where business_id = $1 and name = 'Accessories'`, [biz]);
    const added = await rpc<number>(owner.client, 'apply_category_template', { p_business: biz, p_categories: [
      { name: 'men', children: ['T-SHIRTS', 'Shorts'] }, { name: 'Accessories' }, { name: 'Shoes', children: ['Sneakers'] },
    ] });
    expect(added).toBe(4); // Shorts, Accessories (restored), Shoes, Sneakers
    const after = await sql('select count(*)::int n from categories where business_id = $1', [biz]);
    expect(after[0].n).toBe(before[0].n + 3);
    const [acc] = await sql(`select archived_at from categories where business_id = $1 and name = 'Accessories'`, [biz]);
    expect(acc.archived_at).toBeNull();
  });

  it('lets the owner rename, reorder and archive categories; blocks a third level and other businesses', async () => {
    const tops = await sql<{ id: string; name: string }>(`select id, name from categories where business_id = $1 and parent_id is null order by sort_order`, [biz]);
    await rpc(owner.client, 'reorder_categories', { p_business: biz, p_ids: [...tops].reverse().map((t) => t.id) });
    const re = await sql<{ name: string }>(`select name from categories where business_id = $1 and parent_id is null order by sort_order`, [biz]);
    expect(re.map((r) => r.name)).toEqual([...tops].reverse().map((t) => t.name));

    const men = tops.find((t) => t.name === 'Men')!;
    const { error: renameErr } = await owner.client.from('categories').update({ name: 'Men’s clothing' }).eq('id', men.id);
    expect(renameErr).toBeNull();
    const [tshirt] = await sql(`select id from categories where parent_id = $1 and name = 'T-shirts'`, [men.id]);
    const { error: third } = await owner.client.from('categories').insert({ business_id: biz, name: 'Too deep', parent_id: tshirt.id });
    expect(third?.message).toContain('invalid_category');
    const { error: dup } = await owner.client.from('categories').insert({ business_id: biz, name: 'women' });
    expect(dup?.message).toMatch(/duplicate|unique/);

    const other = await createUser('cat-other');
    const otherBiz = await createBusiness(other, 'Other');
    const { error: cross } = await other.client.from('categories').insert({ business_id: otherBiz, name: 'Sneaky', parent_id: men.id });
    expect(cross?.message).toContain('invalid_category');
    const { data: seen } = await other.client.from('categories').select('id').eq('business_id', biz);
    expect(seen).toEqual([]);
    await expectError(rpc(other.client, 'apply_category_template', { p_business: biz, p_categories: [{ name: 'X' }] }), 'permission_denied');
  });

  it('cashiers cannot change categories or products', async () => {
    const cashier = await addStaff(owner, biz, 'cashier');
    await expectError(rpc(cashier.client, 'apply_category_template', { p_business: biz, p_categories: [{ name: 'X' }] }), 'permission_denied');
    await expectError(rpc(cashier.client, 'reorder_categories', { p_business: biz, p_ids: [] }), 'permission_denied');
    const { error } = await cashier.client.from('products').insert({ business_id: biz, name: 'Nope', selling_price: 1 });
    expect(error).not.toBeNull();
  });

  it('saves a product with only a name and price; generates a unique SKU that stays stable', async () => {
    const ins = async (row: Record<string, unknown>) => {
      const { data, error } = await owner.client.from('products').insert({ business_id: biz, ...row }).select('*').single();
      if (error) throw new Error(error.message);
      return data as any;
    };
    const a = await ins({ name: 'Plain T-shirt', selling_price: 5000 });
    const b = await ins({ name: 'Cap', selling_price: 2000, sku: '   ' });
    expect(a.sku).toMatch(/^SKU-\d{5}$/);
    expect(b.sku).toMatch(/^SKU-\d{5}$/);
    expect(a.sku).not.toBe(b.sku);
    expect(a.barcode).toBeNull();
    expect(a.category_id).toBeNull();
    expect(a.purchase_cost).toBe(0);
    expect(a.attributes).toEqual({});

    const { error: upd } = await owner.client.from('products').update({ name: 'Plain T-shirt (white)', sku: '' }).eq('id', a.id);
    expect(upd).toBeNull();
    expect((await product(owner, a.id)).sku).toBe(a.sku);

    await ins({ name: 'Own code', selling_price: 1, sku: 'TS-001' });
    await expect(ins({ name: 'Clash', selling_price: 1, sku: 'ts-001' })).rejects.toThrow(/duplicate|unique/);
    // A generated SKU skips codes already typed by the owner.
    const [{ value }] = await sql<{ value: string }>(`select value from business_counters where business_id = $1 and key = 'sku'`, [biz]);
    const next = `SKU-${String(Number(value) + 1).padStart(5, '0')}`;
    await ins({ name: 'Manual next', selling_price: 1, sku: next });
    const c = await ins({ name: 'Auto after manual', selling_price: 1 });
    expect(c.sku).not.toBe(next);
    await expect(ins({ name: 'Same barcode', selling_price: 1, barcode: '6151100000017' }).then(() => ins({ name: 'Again', selling_price: 1, barcode: '6151100000017' }))).rejects.toThrow(/duplicate|unique/);
  });

  it('stores optional category attributes and rejects non-object or oversized values', async () => {
    const { data, error } = await owner.client.from('products').insert({ business_id: biz, name: 'Phone X', selling_price: 100000,
      attributes: { brand_model: 'X1', capacity: '128 GB', imei: '356938035643809', warranty_months: 12 } }).select('attributes').single();
    expect(error).toBeNull();
    expect((data as any).attributes.capacity).toBe('128 GB');
    const { error: arr } = await owner.client.from('products').insert({ business_id: biz, name: 'Bad', selling_price: 1, attributes: ['x'] });
    expect(arr?.message).toMatch(/attributes_check|violates check/);
    const { error: big } = await owner.client.from('products').insert({ business_id: biz, name: 'Big', selling_price: 1, attributes: { notes: 'x'.repeat(20000) } });
    expect(big?.message).toMatch(/attributes_check|violates check/);
  });

  it('creates variants with their own price, SKU and opening stock in one step; sells a variant', async () => {
    const { data: parent } = await owner.client.from('products').insert({ business_id: biz, name: 'Hoodie', selling_price: 8000,
      purchase_cost: 4000, attributes: { material: 'Cotton' } }).select('id').single();
    const ids = await rpc<string[]>(owner.client, 'add_product_variants', { p_business: biz, p_parent: (parent as any).id, p_variants: [
      { label: 'M / Black', attributes: { size: 'M', color: 'Black' }, opening_qty: 5 },
      { label: 'XL / Black', attributes: { size: 'XL', color: 'Black' }, selling_price: 9000, opening_qty: 2, opening_cost: 4500 },
    ] });
    expect(ids).toHaveLength(2);
    const vs = await sql(`select variant_label, selling_price, qty_on_hand, avg_cost, sku, attributes from products where variant_of = $1 order by variant_label`, [(parent as any).id]);
    expect(vs.map((v) => [v.variant_label, Number(v.selling_price), Number(v.qty_on_hand), Number(v.avg_cost)])).toEqual([
      ['M / Black', 8000, 5, 4000], ['XL / Black', 9000, 2, 4500]]);
    expect(vs[0].attributes).toEqual({ material: 'Cotton', size: 'M', color: 'Black' });
    expect(new Set(vs.map((v) => v.sku)).size).toBe(2);
    const mv = await sql(`select count(*)::int n from stock_movements where product_id = any($1::uuid[]) and movement_type = 'opening'`, [ids]);
    expect(mv[0].n).toBe(2);

    await expectError(rpc(owner.client, 'add_product_variants', { p_business: biz, p_parent: (parent as any).id, p_variants: [{ label: 'm / black' }] }), 'duplicate_variant');
    await expectError(rpc(owner.client, 'add_product_variants', { p_business: biz, p_parent: (parent as any).id, p_variants: [{ label: 'L' }, { label: 'L' }] }), 'duplicate_variant');
    const [{ n }] = await sql(`select count(*)::int n from products where variant_of = $1`, [(parent as any).id]);
    expect(n).toBe(2); // the failed call added nothing

    await sell(owner, biz, [{ product_id: ids[1], quantity: 1 }], { payments: [{ method: 'cash', amount: 9000 }] });
    const [xl] = await sql(`select qty_on_hand from products where id = $1`, [ids[1]]);
    expect(Number(xl.qty_on_hand)).toBe(1);

    const cashier = await addStaff(owner, biz, 'cashier');
    await expectError(rpc(cashier.client, 'add_product_variants', { p_business: biz, p_parent: (parent as any).id, p_variants: [{ label: 'S' }] }), 'permission_denied');
  });

  it('CSV import still works with two-level categories and optional SKU', async () => {
    const res = await rpc(owner.client, 'import_products', { p_business: biz, p_rows: [
      { name: 'Imported belt', selling_price: '3000', category: 'Accessories' },
      { name: 'Imported bag', selling_price: '7000', category: 'New Imported Cat' },
    ], p_file_name: 'items.csv' });
    expect(res.created).toBe(2);
    const rows = await sql(`select p.sku, c.name cat, c.parent_id from products p join categories c on c.id = p.category_id where p.business_id = $1 and p.name like 'Imported%' order by p.name`, [biz]);
    expect(rows.map((r) => r.cat)).toEqual(['New Imported Cat', 'Accessories']); // bag, belt
    expect(rows.every((r) => r.parent_id === null && /^SKU-/.test(r.sku))).toBe(true);
  });
});
