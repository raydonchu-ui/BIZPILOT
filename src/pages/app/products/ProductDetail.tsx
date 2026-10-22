import { useState } from 'react';
import { Link, useParams } from 'react-router-dom';
import { useQuery } from '@tanstack/react-query';
import { Archive, ArrowLeft, Edit, PackagePlus, RotateCcw, SlidersHorizontal } from 'lucide-react';
import { useI18n } from '../../../i18n';
import { useBiz } from '../../../lib/business';
import { supabase } from '../../../lib/supabase';
import { unwrap } from '../../../lib/api';
import { Product } from '../../../lib/hooks';
import { useAction } from '../../../lib/useAction';
import { formatDate, formatDateTime, formatNumber, formatPct } from '../../../lib/format';
import { Badge, Button, Card, CardHeader, ConfirmDialog, DataTable, ErrorState, KeyValue, LinkButton, PageHeader, PageLoader, Tabs, useMoney } from '../../../components/ui';
import { AdjustStockModal, OpeningStockModal } from '../../../components/StockModals';
import { ProductThumb, stockBadge } from './ProductsPage';

type Tab = 'movements' | 'sales' | 'purchases' | 'prices' | 'batches';

export default function ProductDetail() {
  const { id: pid } = useParams();
  const { t, lang } = useI18n();
  const { can, has } = useBiz();
  const money = useMoney();
  const { run, busy } = useAction();
  const [tab, setTab] = useState<Tab>('movements');
  const [adjust, setAdjust] = useState(false);
  const [openStock, setOpenStock] = useState(false);
  const [archiveOpen, setArchiveOpen] = useState(false);
  const q = useQuery({
    queryKey: ['product', pid],
    queryFn: async () => unwrap(await supabase.from('products').select('*, categories(name), product_units(*), suppliers:preferred_supplier_id(id,name)').eq('id', pid!).single()) as Product & { suppliers: any },
  });
  const tabData = useQuery({
    queryKey: ['product-tab', pid, tab],
    queryFn: async () => {
      if (tab === 'movements') return unwrap(await supabase.from('stock_movements').select('*').eq('product_id', pid!).order('occurred_at', { ascending: false }).limit(200));
      if (tab === 'sales') return unwrap(await supabase.from('sale_lines').select('*, sales(id,number,sold_at)').eq('product_id', pid!).order('id', { ascending: false }).limit(200));
      if (tab === 'purchases') return unwrap(await supabase.from('purchase_lines').select('*, purchases(id,number,purchase_date,status,suppliers(name))').eq('product_id', pid!).limit(200));
      if (tab === 'prices') return unwrap(await supabase.from('product_price_history').select('*').eq('product_id', pid!).order('changed_at', { ascending: false }).limit(100));
      return unwrap(await supabase.from('stock_batches').select('*').eq('product_id', pid!).order('expiry_date'));
    },
  });
  if (q.isLoading) return <PageLoader />;
  if (q.error) return <ErrorState error={q.error} onRetry={() => q.refetch()} />;
  const p = q.data!;
  const margin = Number(p.selling_price) > 0 ? ((Number(p.selling_price) - Number(p.avg_cost)) / Number(p.selling_price)) * 100 : null;
  const toggleArchive = async () => {
    await run(async () => unwrap(await supabase.from('products').update({ status: p.status === 'active' ? 'archived' : 'active' }).eq('id', p.id)), t('common.saved'));
    setArchiveOpen(false);
  };
  const rows = (tabData.data ?? []) as any[];
  return (
    <div>
      <PageHeader
        back={<Link to="/app/products" className="mb-2 inline-flex items-center gap-1 text-sm text-ink-muted hover:text-ink"><ArrowLeft className="h-4 w-4" />{t('nav.products')}</Link>}
        title={<span className="flex items-center gap-3"><ProductThumb path={p.image_path} name={p.name} />{p.name}{p.variant_label ? ` — ${p.variant_label}` : ''}</span>}
        subtitle={<span className="flex flex-wrap items-center gap-2">{p.sku}{p.barcode && ` · ${p.barcode}`}{p.categories?.name && ` · ${p.categories.name}`} {stockBadge(p, t)}</span>}
        actions={can('products.manage') && <>
          {can('stock.adjust') && p.status === 'active' && <Button variant="outline" icon={<SlidersHorizontal className="h-4 w-4" />} onClick={() => setAdjust(true)}>{t('inventory.adjust')}</Button>}
          {p.status === 'active' && <Button variant="outline" icon={<PackagePlus className="h-4 w-4" />} onClick={() => setOpenStock(true)}>{t('products.openingStock')}</Button>}
          <Button variant="outline" icon={p.status === 'active' ? <Archive className="h-4 w-4" /> : <RotateCcw className="h-4 w-4" />} onClick={() => setArchiveOpen(true)}>{p.status === 'active' ? t('common.archive') : t('common.restore')}</Button>
          <LinkButton to={`/app/products/${p.id}/edit`} icon={<Edit className="h-4 w-4" />}>{t('common.edit')}</LinkButton>
        </>} />

      <div className="grid gap-4 lg:grid-cols-3">
        <Card className="lg:col-span-2">
          <CardHeader title={t('products.stockAndValue')} />
          <KeyValue cols={4} items={[
            { label: t('products.inStockQty'), value: `${formatNumber(p.qty_on_hand, lang)} ${p.base_unit}` },
            { label: t('products.avgCost'), value: money(p.avg_cost) },
            { label: t('products.stockValue'), value: money(p.stock_value) },
            { label: t('products.sellingPrice'), value: money(p.selling_price) },
            { label: t('products.margin'), value: margin === null ? '—' : <span className={margin < 0 ? 'text-red-600' : ''}>{formatPct(margin, lang)}</span> },
            { label: t('products.lastCost'), value: money(p.purchase_cost) },
            { label: t('products.minStockShort'), value: `${formatNumber(p.min_stock, lang)} ${p.base_unit}` },
            { label: t('products.preferredSupplier'), value: p.suppliers?.name ?? '—' },
          ]} />
          {margin !== null && margin < 0 && <p className="mt-3 rounded-lg bg-red-50 px-3 py-2 text-sm text-red-800">{t('products.belowCostWarning')}</p>}
        </Card>
        <Card>
          <CardHeader title={t('products.units')} />
          <ul className="space-y-2 text-sm">
            <li className="flex justify-between"><span>1 {p.base_unit} <Badge tone="gray">{t('products.base')}</Badge></span><span>{money(p.selling_price)}</span></li>
            {(p.product_units ?? []).filter((u) => u.active).map((u) => (
              <li key={u.id} className="flex justify-between gap-2"><span>1 {u.name} = {formatNumber(u.factor, lang)} {p.base_unit}{u.is_default_purchase && <Badge tone="blue" className="ml-1">{t('products.purchaseUnit')}</Badge>}</span>
                <span>{money(u.selling_price ?? Number(p.selling_price) * Number(u.factor))}</span></li>
            ))}
          </ul>
          {p.location && <p className="mt-4 text-sm text-ink-muted">{t('products.location')}: {p.location}</p>}
          {p.description && <p className="mt-2 text-sm text-ink-muted">{p.description}</p>}
        </Card>
      </div>

      <Card className="mt-4">
        <Tabs value={tab} onChange={setTab} className="mb-4" items={[
          { value: 'movements', label: t('products.tabMovements') }, { value: 'sales', label: t('products.tabSales'), hidden: !can('sales.view') },
          { value: 'purchases', label: t('products.tabPurchases'), hidden: !can('purchases.manage') || !has('purchases') },
          { value: 'prices', label: t('products.tabPrices'), hidden: !can('products.manage') }, { value: 'batches', label: t('products.tabBatches'), hidden: !p.track_expiry }]} />
        {tabData.isLoading ? <PageLoader /> : tab === 'movements' ? (
          <DataTable rows={rows} rowKey={(r) => r.id} empty={<p className="py-6 text-center text-sm text-ink-muted">{t('common.noData')}</p>} columns={[
            { key: 'at', header: t('common.date'), render: (r) => formatDateTime(r.occurred_at, lang) },
            { key: 'type', header: t('common.type'), render: (r) => <span>{t(`movementTypes.${r.movement_type}`)}{r.cost_estimated && <Badge tone="amber" className="ml-1">{t('common.estimated')}</Badge>}</span> },
            { key: 'ref', header: t('common.reference'), hideOnMobile: true, render: (r) => r.ref_number ?? r.reason ?? '—' },
            { key: 'qty', header: t('common.qty'), align: 'right', render: (r) => <span className={Number(r.quantity) < 0 ? 'text-red-600' : 'text-brand-700'}>{Number(r.quantity) > 0 ? '+' : ''}{formatNumber(r.quantity, lang)}</span> },
            { key: 'cost', header: t('products.unitCost'), align: 'right', hideOnMobile: true, render: (r) => money(r.unit_cost) },
            { key: 'after', header: t('products.balanceAfter'), align: 'right', render: (r) => formatNumber(r.qty_after, lang) },
            { key: 'avg', header: t('products.avgAfter'), align: 'right', hideOnMobile: true, render: (r) => money(r.avg_cost_after) },
          ]} />
        ) : tab === 'sales' ? (
          <DataTable rows={rows} rowKey={(r) => r.id} empty={<p className="py-6 text-center text-sm text-ink-muted">{t('common.noData')}</p>} columns={[
            { key: 'n', header: t('sales.number'), render: (r) => <Link className="font-semibold hover:underline" to={`/app/sales/${r.sales?.id}`}>{r.sales?.number}</Link> },
            { key: 'd', header: t('common.date'), render: (r) => formatDateTime(r.sales?.sold_at, lang) },
            { key: 'q', header: t('common.qty'), align: 'right', render: (r) => `${formatNumber(r.quantity, lang)} ${r.unit_name}` },
            { key: 'a', header: t('common.amount'), align: 'right', render: (r) => money(r.net_amount) },
            { key: 'c', header: t('common.cost'), align: 'right', hideOnMobile: true, render: (r) => money(r.cost_amount) },
          ]} />
        ) : tab === 'purchases' ? (
          <DataTable rows={rows} rowKey={(r) => r.id} empty={<p className="py-6 text-center text-sm text-ink-muted">{t('common.noData')}</p>} columns={[
            { key: 'n', header: t('purchases.number'), render: (r) => <Link className="font-semibold hover:underline" to={`/app/purchases/${r.purchases?.id}`}>{r.purchases?.number}</Link> },
            { key: 'd', header: t('common.date'), render: (r) => formatDate(r.purchases?.purchase_date, lang) },
            { key: 's', header: t('purchases.supplier'), hideOnMobile: true, render: (r) => r.purchases?.suppliers?.name },
            { key: 'q', header: t('purchases.ordered'), align: 'right', render: (r) => `${formatNumber(r.qty_ordered, lang)} ${r.unit_name}` },
            { key: 'r', header: t('purchases.received'), align: 'right', render: (r) => formatNumber(r.qty_received, lang) },
            { key: 'u', header: t('purchases.unitCost'), align: 'right', render: (r) => money(r.unit_cost) },
            { key: 'l', header: t('purchases.landedCost'), align: 'right', hideOnMobile: true, render: (r) => r.landed_unit_cost_base ? money(r.landed_unit_cost_base) : '—' },
          ]} />
        ) : tab === 'prices' ? (
          <DataTable rows={rows} rowKey={(r) => String(r.id)} empty={<p className="py-6 text-center text-sm text-ink-muted">{t('common.noData')}</p>} columns={[
            { key: 'd', header: t('common.date'), render: (r) => formatDateTime(r.changed_at, lang) },
            { key: 'c', header: t('products.lastCost'), align: 'right', render: (r) => `${money(r.old_purchase_cost)} → ${money(r.new_purchase_cost)}` },
            { key: 'p', header: t('products.sellingPrice'), align: 'right', render: (r) => `${money(r.old_selling_price)} → ${money(r.new_selling_price)}` },
          ]} />
        ) : (
          <DataTable rows={rows} rowKey={(r) => r.id} empty={<p className="py-6 text-center text-sm text-ink-muted">{t('common.noData')}</p>} columns={[
            { key: 'b', header: t('inventory.batchCode'), render: (r) => r.batch_code ?? '—' },
            { key: 'e', header: t('inventory.expiryDate'), render: (r) => r.expiry_date ? formatDate(r.expiry_date, lang) : '—' },
            { key: 'r', header: t('inventory.received'), align: 'right', render: (r) => formatNumber(r.received_qty, lang) },
            { key: 'm', header: t('inventory.remaining'), align: 'right', render: (r) => formatNumber(r.remaining_qty, lang) },
          ]} />
        )}
      </Card>

      <AdjustStockModal open={adjust} onClose={() => setAdjust(false)} product={p} />
      <OpeningStockModal open={openStock} onClose={() => setOpenStock(false)} product={p} />
      <ConfirmDialog open={archiveOpen} onClose={() => setArchiveOpen(false)} onConfirm={toggleArchive} loading={busy}
        title={p.status === 'active' ? t('products.archiveTitle') : t('products.restoreTitle')} body={p.status === 'active' ? t('products.archiveBody') : t('products.restoreBody')} />
    </div>
  );
}
