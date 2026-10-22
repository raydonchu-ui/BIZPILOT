import { useState } from 'react';
import { Link, useNavigate, useSearchParams } from 'react-router-dom';
import { useQuery } from '@tanstack/react-query';
import { AlertTriangle, Boxes, ClipboardCheck, Download, Package, PackageX, Plus } from 'lucide-react';
import { useI18n } from '../../../i18n';
import { useBiz } from '../../../lib/business';
import { supabase } from '../../../lib/supabase';
import { rpc, unwrap } from '../../../lib/api';
import { useAction } from '../../../lib/useAction';
import { useCategories, useSettings } from '../../../lib/hooks';
import { addDays, localToday } from '../../../lib/dates';
import { formatDate, formatDateTime, formatNumber } from '../../../lib/format';
import { downloadCsv } from '../../../lib/csv';
import { Badge, Button, Card, DataTable, EmptyState, Field, Input, Modal, PageHeader, PageLoader, Pagination, Select, StatCard, Tabs, useMoney } from '../../../components/ui';
import { stockBadge } from '../products/ProductsPage';

type Tab = 'stock' | 'movements' | 'expiry' | 'counts';
const PAGE = 30;

export default function InventoryPage({ initialTab }: { initialTab?: Tab }) {
  const { t } = useI18n();
  const { can } = useBiz();
  const [params, setParams] = useSearchParams();
  const tab = (params.get('tab') as Tab) || initialTab || 'stock';
  const setTab = (v: Tab) => setParams(v === 'stock' ? {} : { tab: v });
  return (
    <div>
      <PageHeader title={t('inventory.title')} subtitle={t('inventory.subtitle')} />
      <InventoryStats />
      <Tabs className="my-4" value={tab} onChange={setTab} items={[
        { value: 'stock', label: t('inventory.tabStock') }, { value: 'movements', label: t('inventory.tabMovements') },
        { value: 'expiry', label: t('inventory.tabExpiry') }, { value: 'counts', label: t('inventory.tabCounts'), hidden: !can('stock.adjust') }]} />
      {tab === 'stock' && <StockTab />}
      {tab === 'movements' && <MovementsTab />}
      {tab === 'expiry' && <ExpiryTab />}
      {tab === 'counts' && <CountsTab />}
    </div>
  );
}

function InventoryStats() {
  const { t } = useI18n();
  const { id } = useBiz();
  const money = useMoney();
  const { data } = useQuery({
    queryKey: ['inv-stats', id],
    queryFn: async () => {
      const rows = unwrap(await supabase.from('products').select('qty_on_hand,min_stock,stock_value').eq('business_id', id).eq('status', 'active').limit(10000)) as any[];
      return {
        total: rows.length, low: rows.filter((r) => Number(r.qty_on_hand) > 0 && Number(r.min_stock) > 0 && Number(r.qty_on_hand) <= Number(r.min_stock)).length,
        out: rows.filter((r) => Number(r.qty_on_hand) <= 0).length, value: rows.reduce((a, r) => a + Number(r.stock_value), 0),
      };
    },
  });
  return (
    <div className="grid grid-cols-2 gap-3 sm:gap-4 lg:grid-cols-4">
      <StatCard label={t('inventory.totalProducts')} value={data?.total ?? '…'} icon={<Package className="h-5 w-5" />} tone="blue" />
      <StatCard label={t('dashboard.lowStock')} value={data?.low ?? '…'} icon={<AlertTriangle className="h-5 w-5" />} tone="amber" to="/app/inventory?filter=low" />
      <StatCard label={t('dashboard.outOfStock')} value={data?.out ?? '…'} icon={<PackageX className="h-5 w-5" />} tone="red" to="/app/inventory?filter=out" />
      <StatCard label={t('dashboard.inventoryValue')} value={data ? money(data.value) : '…'} icon={<Boxes className="h-5 w-5" />} tone="purple" hint={t('inventory.atAvgCost')} />
    </div>
  );
}

function StockTab() {
  const { t, lang } = useI18n();
  const { id } = useBiz();
  const money = useMoney();
  const nav = useNavigate();
  const [params, setParams] = useSearchParams();
  const filter = params.get('filter') ?? 'all';
  const [cat, setCat] = useState('');
  const [q, setQ] = useState('');
  const cats = useCategories(id);
  const { data, isLoading } = useQuery({
    queryKey: ['inv-stock', id, cat, q],
    queryFn: async () => {
      let query = supabase.from('products').select('id,name,sku,base_unit,qty_on_hand,min_stock,avg_cost,stock_value,status,location,categories(name)').eq('business_id', id).eq('status', 'active').order('name').limit(2000);
      if (cat) query = query.eq('category_id', cat);
      if (q.trim()) query = query.ilike('name', `%${q.trim()}%`);
      return unwrap(await query) as any[];
    },
  });
  const rows = (data ?? []).filter((p) => filter === 'low' ? Number(p.qty_on_hand) > 0 && Number(p.min_stock) > 0 && Number(p.qty_on_hand) <= Number(p.min_stock)
    : filter === 'out' ? Number(p.qty_on_hand) <= 0 : true);
  const total = rows.reduce((a, r) => a + Number(r.stock_value), 0);
  return (
    <Card>
      <div className="mb-4 flex flex-col gap-3 md:flex-row">
        <Input className="md:w-72" placeholder={t('common.search')} value={q} onChange={(e) => setQ(e.target.value)} />
        <Select className="md:w-52" value={cat} onChange={(e) => setCat(e.target.value)}><option value="">{t('products.allCategories')}</option>{(cats.data ?? []).map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}</Select>
        <Select className="md:w-48" value={filter} onChange={(e) => setParams(e.target.value === 'all' ? {} : { filter: e.target.value })}>
          <option value="all">{t('common.all')}</option><option value="low">{t('products.lowStock')}</option><option value="out">{t('products.outOfStock')}</option>
        </Select>
        <Button variant="outline" className="md:ml-auto" icon={<Download className="h-4 w-4" />} onClick={() => downloadCsv('bizpilot-stock.csv', rows.map((r) => ({
          name: r.name, sku: r.sku, category: r.categories?.name, qty_on_hand: r.qty_on_hand, unit: r.base_unit, min_stock: r.min_stock,
          avg_cost: r.avg_cost, stock_value: Math.round(Number(r.stock_value)), location: r.location })))}>{t('common.exportCsv')}</Button>
      </div>
      {isLoading ? <PageLoader /> : (
        <DataTable rows={rows} rowKey={(r) => r.id} onRowClick={(r) => nav(`/app/products/${r.id}`)}
          empty={<EmptyState title={t('common.noResults')} />}
          footer={<tr><td className="px-3 py-3" colSpan={4}>{t('common.total')}</td><td className="px-3 py-3 text-right tabular-nums">{money(total)}</td><td /></tr>}
          columns={[
            { key: 'n', header: t('common.name'), render: (r) => <div><p className="font-semibold">{r.name}</p><p className="text-xs text-ink-muted">{r.sku}{r.categories?.name ? ` · ${r.categories.name}` : ''}</p></div> },
            { key: 'q', header: t('products.inStockQty'), align: 'right', render: (r) => `${formatNumber(r.qty_on_hand, lang)} ${r.base_unit}` },
            { key: 'm', header: t('products.minStockShort'), align: 'right', hideOnMobile: true, render: (r) => formatNumber(r.min_stock, lang) },
            { key: 'c', header: t('products.avgCost'), align: 'right', hideOnMobile: true, render: (r) => money(r.avg_cost) },
            { key: 'v', header: t('products.stockValue'), align: 'right', render: (r) => money(r.stock_value) },
            { key: 's', header: t('common.status'), align: 'center', render: (r) => stockBadge(r, t) },
          ]} />
      )}
    </Card>
  );
}

function MovementsTab() {
  const { t, lang } = useI18n();
  const { id, biz } = useBiz();
  const money = useMoney();
  const [type, setType] = useState('');
  const [from, setFrom] = useState(addDays(localToday(biz.timezone), -30));
  const [to, setTo] = useState(localToday(biz.timezone));
  const [page, setPage] = useState(0);
  const build = () => {
    let q = supabase.from('stock_movements').select('*, products(name,base_unit)', { count: 'exact' }).eq('business_id', id)
      .gte('occurred_at', `${from}T00:00:00+01:00`).lt('occurred_at', `${addDays(to, 1)}T00:00:00+01:00`).order('occurred_at', { ascending: false });
    if (type === 'adjustments') q = q.in('movement_type', ['damaged', 'expired', 'missing', 'found', 'correction', 'count']);
    else if (type) q = q.eq('movement_type', type);
    return q;
  };
  const { data, isLoading } = useQuery({
    queryKey: ['movements', id, type, from, to, page],
    queryFn: async () => { const r = await build().range(page * PAGE, page * PAGE + PAGE - 1); return { rows: unwrap(r) as any[], count: r.count ?? 0 }; },
  });
  const exportCsv = async () => {
    const rows = unwrap(await build().limit(10000)) as any[];
    downloadCsv('bizpilot-stock-movements.csv', rows.map((r) => ({ date: r.occurred_at, product: r.products?.name, type: t(`movementTypes.${r.movement_type}`),
      quantity: r.quantity, unit: r.products?.base_unit, unit_cost: r.unit_cost, value: r.value, qty_after: r.qty_after, reference: r.ref_number, reason: r.reason, cost_estimated: r.cost_estimated })));
  };
  return (
    <Card>
      <div className="mb-4 grid gap-3 sm:grid-cols-2 lg:grid-cols-5">
        <Field label={t('common.type')}>
          <Select value={type} onChange={(e) => { setType(e.target.value); setPage(0); }}>
            <option value="">{t('common.all')}</option><option value="adjustments">{t('inventory.allAdjustments')}</option>
            {['opening', 'purchase_receipt', 'sale', 'sale_return', 'supplier_return', 'damaged', 'expired', 'missing', 'found', 'correction', 'count'].map((k) => <option key={k} value={k}>{t(`movementTypes.${k}`)}</option>)}
          </Select>
        </Field>
        <Field label={t('common.from')}><Input type="date" value={from} onChange={(e) => { setFrom(e.target.value); setPage(0); }} /></Field>
        <Field label={t('common.to')}><Input type="date" value={to} onChange={(e) => { setTo(e.target.value); setPage(0); }} /></Field>
        <div className="flex items-end lg:col-span-2 lg:justify-end"><Button variant="outline" icon={<Download className="h-4 w-4" />} onClick={exportCsv}>{t('common.exportCsv')}</Button></div>
      </div>
      {isLoading ? <PageLoader /> : (
        <>
          <DataTable rows={data!.rows} rowKey={(r) => r.id} empty={<EmptyState title={t('inventory.noMovements')} />} columns={[
            { key: 'd', header: t('common.date'), render: (r) => formatDateTime(r.occurred_at, lang) },
            { key: 'p', header: t('dashboard.product'), render: (r) => <Link to={`/app/products/${r.product_id}`} className="font-semibold hover:underline">{r.products?.name}</Link> },
            { key: 't', header: t('common.type'), render: (r) => <span>{t(`movementTypes.${r.movement_type}`)}{r.cost_estimated && <Badge tone="amber" className="ml-1">{t('common.estimated')}</Badge>}</span> },
            { key: 'q', header: t('common.qty'), align: 'right', render: (r) => <span className={Number(r.quantity) < 0 ? 'text-red-600' : 'text-brand-700'}>{Number(r.quantity) > 0 ? '+' : ''}{formatNumber(r.quantity, lang)} {r.products?.base_unit}</span> },
            { key: 'v', header: t('inventory.valueChange'), align: 'right', hideOnMobile: true, render: (r) => money(r.value) },
            { key: 'r', header: t('common.reference'), hideOnMobile: true, render: (r) => <span className="text-xs">{r.ref_number ?? ''} {r.reason ?? ''}</span> },
          ]} />
          <Pagination page={page} pageSize={PAGE} total={data!.count} onPage={setPage} />
        </>
      )}
    </Card>
  );
}

function ExpiryTab() {
  const { t, lang } = useI18n();
  const { id, biz } = useBiz();
  const settings = useSettings(id);
  const days = settings.data?.expiry_alert_days ?? 30;
  const today = localToday(biz.timezone);
  const { data, isLoading } = useQuery({
    queryKey: ['expiry', id],
    queryFn: async () => unwrap(await supabase.from('stock_batches').select('*, products(name,base_unit,avg_cost)').eq('business_id', id).gt('remaining_qty', 0).not('expiry_date', 'is', null).order('expiry_date').limit(500)) as any[],
  });
  const money = useMoney();
  if (isLoading) return <PageLoader />;
  return (
    <Card>
      <p className="mb-4 text-sm text-ink-muted">{t('inventory.expiryIntro', { days })}</p>
      <DataTable rows={data ?? []} rowKey={(r) => r.id} empty={<EmptyState title={t('inventory.noBatches')} body={t('inventory.noBatchesBody')} />} columns={[
        { key: 'p', header: t('dashboard.product'), render: (r) => <Link to={`/app/products/${r.product_id}`} className="font-semibold hover:underline">{r.products?.name}</Link> },
        { key: 'b', header: t('inventory.batchCode'), render: (r) => r.batch_code ?? '—' },
        { key: 'e', header: t('inventory.expiryDate'), render: (r) => {
          const expired = r.expiry_date < today; const soon = r.expiry_date <= addDays(today, days);
          return <span className="flex items-center gap-2">{formatDate(r.expiry_date, lang)}{expired ? <Badge tone="red">{t('inventory.expired')}</Badge> : soon ? <Badge tone="amber">{t('inventory.expiresSoon')}</Badge> : null}</span>;
        } },
        { key: 'q', header: t('inventory.remaining'), align: 'right', render: (r) => `${formatNumber(r.remaining_qty, lang)} ${r.products?.base_unit}` },
        { key: 'v', header: t('inventory.estValue'), align: 'right', hideOnMobile: true, render: (r) => money(Number(r.remaining_qty) * Number(r.products?.avg_cost ?? 0)) },
      ]} />
      <p className="mt-3 text-xs text-ink-muted">{t('inventory.expiryWriteOffHint')}</p>
    </Card>
  );
}

function CountsTab() {
  const { t, lang } = useI18n();
  const { id } = useBiz();
  const nav = useNavigate();
  const cats = useCategories(id);
  const [open, setOpen] = useState(false);
  const [scope, setScope] = useState<'all' | 'category'>('all');
  const [cat, setCat] = useState('');
  const [notes, setNotes] = useState('');
  const { run, busy } = useAction();
  const { data, isLoading } = useQuery({
    queryKey: ['counts', id],
    queryFn: async () => unwrap(await supabase.from('stock_counts').select('*').eq('business_id', id).order('created_at', { ascending: false }).limit(100)) as any[],
  });
  const create = async () => {
    const cid = await run(() => rpc<string>('create_stock_count', { p_business: id, p_product_ids: null, p_category: scope === 'category' ? cat || null : null, p_notes: notes || null }));
    if (cid) nav(`/app/inventory/counts/${cid}`);
  };
  const tone = (s: string) => (s === 'completed' ? 'green' : s === 'cancelled' ? 'gray' : 'amber') as 'green' | 'gray' | 'amber';
  return (
    <Card>
      <div className="mb-4 flex items-center justify-between gap-3">
        <p className="text-sm text-ink-muted">{t('inventory.countsIntro')}</p>
        <Button icon={<Plus className="h-4 w-4" />} onClick={() => setOpen(true)}>{t('inventory.newCount')}</Button>
      </div>
      {isLoading ? <PageLoader /> : (
        <DataTable rows={data ?? []} rowKey={(r) => r.id} onRowClick={(r) => nav(`/app/inventory/counts/${r.id}`)}
          empty={<EmptyState icon={<ClipboardCheck className="h-6 w-6" />} title={t('inventory.noCounts')} body={t('inventory.countsIntro')} />}
          columns={[
            { key: 'n', header: t('common.reference'), render: (r) => <span className="font-semibold">{r.number}</span> },
            { key: 'd', header: t('common.date'), render: (r) => formatDateTime(r.created_at, lang) },
            { key: 's', header: t('common.status'), render: (r) => <Badge tone={tone(r.status)}>{t(`inventory.countStatus.${r.status}`)}</Badge> },
            { key: 'v', header: t('inventory.valueDifference'), align: 'right', render: (r) => r.adjustment_value == null ? '—' : <ValueCell v={r.adjustment_value} /> },
          ]} />
      )}
      <Modal open={open} onClose={() => setOpen(false)} title={t('inventory.newCount')}
        footer={<><Button variant="outline" onClick={() => setOpen(false)}>{t('common.cancel')}</Button><Button loading={busy} onClick={create}>{t('common.create')}</Button></>}>
        <div className="space-y-4">
          <Field label={t('inventory.countScope')}>
            <Select value={scope} onChange={(e) => setScope(e.target.value as any)}><option value="all">{t('inventory.scopeAll')}</option><option value="category">{t('inventory.scopeCategory')}</option></Select>
          </Field>
          {scope === 'category' && <Field label={t('common.category')}><Select value={cat} onChange={(e) => setCat(e.target.value)}><option value="">—</option>{(cats.data ?? []).map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}</Select></Field>}
          <Field label={t('common.notes')}><Input value={notes} onChange={(e) => setNotes(e.target.value)} /></Field>
        </div>
      </Modal>
    </Card>
  );
}

function ValueCell({ v }: { v: number }) {
  const money = useMoney();
  return <span className={Number(v) < 0 ? 'text-red-600' : Number(v) > 0 ? 'text-brand-700' : ''}>{money(v)}</span>;
}
