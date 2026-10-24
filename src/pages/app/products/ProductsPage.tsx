import { useState } from 'react';
import { Link, useNavigate, useSearchParams } from 'react-router-dom';
import { useQuery } from '@tanstack/react-query';
import { Download, Filter, FolderTree, Package, Plus, Upload } from 'lucide-react';
import { useI18n } from '../../../i18n';
import { useBiz } from '../../../lib/business';
import { supabase } from '../../../lib/supabase';
import { unwrap } from '../../../lib/api';
import { Product, subcategoriesOf, useCategories, useCategoryTree, useSignedUrl } from '../../../lib/hooks';
import { formatNumber } from '../../../lib/format';
import { downloadCsv } from '../../../lib/csv';
import { Badge, Button, Card, DataTable, EmptyState, ErrorState, Input, LinkButton, PageHeader, PageLoader, Pagination, Select, Tabs, useMoney } from '../../../components/ui';

const PAGE = 25;
type F = 'all' | 'low' | 'out' | 'archived';

export function stockBadge(p: Pick<Product, 'qty_on_hand' | 'min_stock' | 'status'>, t: (k: string) => string) {
  if (p.status === 'archived') return <Badge tone="gray">{t('common.archived')}</Badge>;
  const q = Number(p.qty_on_hand);
  if (q <= 0) return <Badge tone="red">{t('products.outOfStock')}</Badge>;
  if (Number(p.min_stock) > 0 && q <= Number(p.min_stock)) return <Badge tone="amber">{t('products.lowStock')}</Badge>;
  return <Badge tone="green">{t('products.inStock')}</Badge>;
}

export function ProductThumb({ path, name }: { path: string | null; name: string }) {
  const { data } = useSignedUrl(path);
  return data ? <img src={data} alt="" className="h-10 w-10 shrink-0 rounded-lg object-cover" />
    : <div className="flex h-10 w-10 shrink-0 items-center justify-center rounded-lg bg-brand-50 text-sm font-bold text-brand-700 dark:bg-brand-900/40 dark:text-brand-300">{name.slice(0, 1).toUpperCase()}</div>;
}

export default function ProductsPage() {
  const { t, lang } = useI18n();
  const { id, can } = useBiz();
  const money = useMoney();
  const nav = useNavigate();
  const [params, setParams] = useSearchParams();
  const filter = (params.get('filter') as F) || 'all';
  const [q, setQ] = useState('');
  const [cat, setCat] = useState('');
  const [sub, setSub] = useState('');
  const [brand, setBrand] = useState('');
  const [sort, setSort] = useState('name');
  const [page, setPage] = useState(0);
  const cats = useCategories(id);
  const tree = useCategoryTree(id);
  const subs = subcategoriesOf(tree.data, cat || null);
  const brands = useQuery({
    queryKey: ['product-brands', id],
    queryFn: async () => [...new Set((unwrap(await supabase.from('products').select('brand').eq('business_id', id).not('brand', 'is', null).limit(5000)) as { brand: string }[])
      .map((r) => r.brand.trim()).filter(Boolean))].sort((a, b) => a.localeCompare(b)),
  });

  const build = () => {
    let query = supabase.from('products').select('*, categories(name)', { count: 'exact' }).eq('business_id', id);
    query = filter === 'archived' ? query.eq('status', 'archived') : query.eq('status', 'active');
    if (filter === 'out') query = query.lte('qty_on_hand', 0);
    if (cat) query = query.eq('category_id', cat);
    if (cat && sub) query = query.ilike('subcategory', sub.replace(/[%_]/g, ' '));
    if (brand) query = query.eq('brand', brand);
    if (q.trim()) { const like = `%${q.trim().replace(/[%_,()]/g, ' ')}%`; query = query.or(`name.ilike.${like},sku.ilike.${like},barcode.ilike.${like},brand.ilike.${like}`); }
    const [col, dir] = sort.split(':');
    return query.order(col, { ascending: dir !== 'desc' });
  };
  const { data, isLoading, error, refetch } = useQuery({
    queryKey: ['products', id, filter, q, cat, sub, brand, sort, page],
    queryFn: async () => {
      if (filter === 'low') {
        // Low stock compares two columns, so it is filtered after fetching active products.
        const rows = (unwrap(await build().gt('qty_on_hand', 0).gt('min_stock', 0).limit(1000)) as Product[]).filter((p) => Number(p.qty_on_hand) <= Number(p.min_stock));
        return { rows: rows.slice(page * PAGE, page * PAGE + PAGE), count: rows.length };
      }
      const res = await build().range(page * PAGE, page * PAGE + PAGE - 1);
      return { rows: unwrap(res) as Product[], count: res.count ?? 0 };
    },
  });
  const setFilter = (f: F) => { setPage(0); setParams(f === 'all' ? {} : { filter: f }); };
  const exportAll = async () => {
    const rows = unwrap(await build().limit(5000)) as Product[];
    downloadCsv('bizpilot-products.csv', rows.map((p) => ({
      name: p.name, variant: p.variant_label, sku: p.sku, barcode: p.barcode, category: p.categories?.name, subcategory: p.subcategory, brand: p.brand, base_unit: p.base_unit,
      purchase_cost: p.purchase_cost, selling_price: p.selling_price, qty_on_hand: p.qty_on_hand, avg_cost: p.avg_cost,
      stock_value: Math.round(Number(p.stock_value)), min_stock: p.min_stock, status: p.status,
      details: Object.entries(p.attributes ?? {}).map(([k, v]) => `${k}: ${v}`).join('; '),
    })));
  };

  return (
    <div>
      <PageHeader title={t('products.title')} subtitle={t('products.subtitle')} actions={<>
        <Button variant="outline" icon={<Download className="h-4 w-4" />} onClick={exportAll}>{t('common.exportCsv')}</Button>
        {can('products.manage') && <LinkButton to="/app/products/categories" variant="outline" icon={<FolderTree className="h-4 w-4" />}>{t('catalog.categories.title')}</LinkButton>}
        {can('imports.manage') && <LinkButton to="/app/import" variant="outline" icon={<Upload className="h-4 w-4" />}>{t('common.import')}</LinkButton>}
        {can('products.manage') && <LinkButton to="/app/products/new" icon={<Plus className="h-4 w-4" />}>{t('nav.addProduct')}</LinkButton>}
      </>} />
      <Card>
        <div className="mb-4 flex flex-col gap-3 lg:flex-row lg:items-center">
          <div className="flex-1"><Input placeholder={t('products.searchPlaceholder')} value={q} onChange={(e) => { setQ(e.target.value); setPage(0); }} prefixIcon={<Filter className="h-4 w-4" />} /></div>
          <Select className="lg:w-48" value={cat} onChange={(e) => { setCat(e.target.value); setSub(''); setPage(0); }} aria-label={t('common.category')}>
            <option value="">{t('products.allCategories')}</option>
            {(cats.data ?? []).map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}
          </Select>
          {subs.length > 0 && (
            <Select className="lg:w-48" value={sub} onChange={(e) => { setSub(e.target.value); setPage(0); }} aria-label={t('products.subcategory')}>
              <option value="">{t('catalog.filters.subcategory')}</option>
              {subs.map((c) => <option key={c.id} value={c.name}>{c.name}</option>)}
            </Select>
          )}
          {(brands.data ?? []).length > 0 && (
            <Select className="lg:w-44" value={brand} onChange={(e) => { setBrand(e.target.value); setPage(0); }} aria-label={t('products.brand')}>
              <option value="">{t('catalog.filters.brand')}</option>
              {brands.data!.map((b) => <option key={b} value={b}>{b}</option>)}
            </Select>
          )}
          <Select className="lg:w-52" value={sort} onChange={(e) => setSort(e.target.value)} aria-label={t('products.sort')}>
            <option value="name">{t('products.sortName')}</option>
            <option value="qty_on_hand">{t('products.sortStockLow')}</option>
            <option value="qty_on_hand:desc">{t('products.sortStockHigh')}</option>
            <option value="stock_value:desc">{t('products.sortValue')}</option>
            <option value="updated_at:desc">{t('products.sortRecent')}</option>
          </Select>
        </div>
        <Tabs className="mb-3" value={filter} onChange={setFilter} items={[
          { value: 'all', label: t('common.all') }, { value: 'low', label: t('products.lowStock') },
          { value: 'out', label: t('products.outOfStock') }, { value: 'archived', label: t('common.archived') }]} />
        {isLoading ? <PageLoader /> : error ? <ErrorState error={error} onRetry={() => refetch()} /> : (
          <>
            <DataTable rows={data!.rows} rowKey={(r) => r.id} onRowClick={(r) => nav(`/app/products/${r.id}`)}
              empty={<EmptyState icon={<Package className="h-6 w-6" />} title={t('products.emptyTitle')} body={t('products.emptyBody')}
                action={can('products.manage') && <div className="flex gap-2"><LinkButton to="/app/products/new" size="sm">{t('nav.addProduct')}</LinkButton><LinkButton to="/app/import" size="sm" variant="outline">{t('setup.importInstead')}</LinkButton></div>} />}
              columns={[
                { key: 'name', header: t('common.name'), render: (p) => (
                  <div className="flex items-center gap-3"><ProductThumb path={p.image_path} name={p.name} />
                    <div className="min-w-0"><Link to={`/app/products/${p.id}`} className="block truncate font-semibold hover:underline" onClick={(e) => e.stopPropagation()}>{p.name}{p.variant_label ? ` — ${p.variant_label}` : ''}</Link>
                      <span className="block truncate text-xs text-ink-muted">{p.sku}{p.categories?.name ? ` · ${p.categories.name}` : ''}</span></div></div>) },
                { key: 'price', header: t('products.sellingPrice'), align: 'right', render: (p) => money(p.selling_price) },
                { key: 'cost', header: t('products.avgCost'), align: 'right', hideOnMobile: true, render: (p) => money(p.avg_cost) },
                { key: 'qty', header: t('products.inStockQty'), align: 'right', render: (p) => <span className="font-semibold">{formatNumber(p.qty_on_hand, lang)} <span className="text-xs font-normal text-ink-muted">{p.base_unit}</span></span> },
                { key: 'value', header: t('products.stockValue'), align: 'right', hideOnMobile: true, render: (p) => money(p.stock_value) },
                { key: 'status', header: t('common.status'), align: 'center', render: (p) => stockBadge(p, t) },
              ]} />
            <Pagination page={page} pageSize={PAGE} total={data!.count} onPage={setPage} />
          </>
        )}
      </Card>
    </div>
  );
}
