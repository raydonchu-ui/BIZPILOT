import { ReactNode, useMemo, useState } from 'react';
import { Link, useSearchParams } from 'react-router-dom';
import { useQuery } from '@tanstack/react-query';
import { Download, Lock, Printer } from 'lucide-react';
import { useI18n } from '../../../i18n';
import { useBiz } from '../../../lib/business';
import { supabase } from '../../../lib/supabase';
import { unwrap, useRpc } from '../../../lib/api';
import { downloadCsv } from '../../../lib/csv';
import { daysBetween, grainFor } from '../../../lib/dates';
import { formatDate, formatDateTime, formatNumber, formatPct } from '../../../lib/format';
import { Alert, Badge, Button, Card, CardHeader, Column, DataTable, ErrorState, PageHeader, PageLoader, Select, Tabs, UpgradeNotice, useMoney } from '../../../components/ui';
import { PeriodPicker, usePeriod } from '../../../components/PeriodPicker';
import { HBar, SalesProfitChart } from '../../../components/charts';
import { Period } from '../../../lib/dates';

type Tab = 'pl' | 'sales' | 'channels' | 'products' | 'categories' | 'valuation' | 'slow' | 'aging' | 'restock' | 'suppliers' | 'customers' | 'discrepancies' | 'efficiency' | 'payments';
const FEATURE: Partial<Record<Tab, string>> = { pl: 'basic_analytics', channels: 'basic_analytics', products: 'basic_analytics', categories: 'basic_analytics', slow: 'advanced_analytics', aging: 'advanced_analytics', restock: 'restock', suppliers: 'advanced_analytics', discrepancies: 'advanced_analytics', efficiency: 'advanced_analytics' };

export default function ReportsPage() {
  const { t } = useI18n();
  const { has, can } = useBiz();
  const [params, setParams] = useSearchParams();
  const tab = (params.get('tab') as Tab) || 'pl';
  const [period, setPeriod] = usePeriod('this_month');
  if (!can('reports.view')) return <ErrorState error={{ message: 'permission_denied' }} />;
  const tabs: Tab[] = ['pl', 'sales', 'channels', 'products', 'categories', 'valuation', 'restock', 'slow', 'aging', 'suppliers', 'customers', 'discrepancies', 'efficiency', 'payments'];
  const feature = FEATURE[tab];
  const periodless = ['valuation', 'restock', 'slow', 'aging', 'customers'].includes(tab);
  return (
    <div>
      <PageHeader title={t('nav.reports')} subtitle={t('reports.subtitle')} actions={<>
        {!periodless && <PeriodPicker value={period} onChange={setPeriod} />}
        <Button variant="outline" icon={<Printer className="h-4 w-4" />} onClick={() => window.print()}>{t('common.printPdf')}</Button></>} />
      <Tabs className="mb-4 no-print" value={tab} onChange={(v) => setParams({ tab: v })} items={tabs.map((x) => ({ value: x, label: <span className="inline-flex items-center gap-1">{t(`reports.tabs.${x}`)}{FEATURE[x] && !has(FEATURE[x]!) && <Lock className="h-3 w-3 opacity-60" />}</span> }))} />
      <div className="print-only mb-3"><p className="text-lg font-bold">{t(`reports.tabs.${tab}`)}</p>{!periodless && <p>{formatDate(period.from, 'fr')} – {formatDate(period.to, 'fr')}</p>}</div>
      {feature && !has(feature) ? <UpgradeNotice feature={feature} /> : (
        <>
          {tab === 'pl' && <ProfitLoss period={period} />}
          {tab === 'sales' && <SalesReport period={period} />}
          {tab === 'channels' && <ChannelsReport period={period} />}
          {tab === 'products' && <ProductsReport period={period} />}
          {tab === 'categories' && <CategoriesReport period={period} />}
          {tab === 'valuation' && <ValuationReport />}
          {tab === 'restock' && <RestockReport />}
          {tab === 'slow' && <SlowReport />}
          {tab === 'aging' && <AgingReport />}
          {tab === 'suppliers' && <SuppliersReport period={period} />}
          {tab === 'customers' && <CustomersReport />}
          {tab === 'discrepancies' && <DiscrepancyReport period={period} />}
          {tab === 'efficiency' && <EfficiencyReport period={period} />}
          {tab === 'payments' && <PaymentsReport period={period} />}
        </>
      )}
    </div>
  );
}

function ExportButton({ name, rows }: { name: string; rows: () => Record<string, unknown>[] }) {
  const { t } = useI18n();
  const { has } = useBiz();
  if (!has('reports_export')) return <Link to="/app/billing" className="inline-flex items-center gap-1 text-xs font-semibold text-ink-muted no-print"><Lock className="h-3.5 w-3.5" />{t('reports.exportLocked')}</Link>;
  return <Button size="sm" variant="outline" className="no-print" icon={<Download className="h-4 w-4" />} onClick={() => downloadCsv(`bizpilot-${name}.csv`, rows())}>{t('common.exportCsv')}</Button>;
}

function Q<T>({ q, children }: { q: { isLoading: boolean; error: unknown; data?: T; refetch: () => void }; children: (d: T) => ReactNode }) {
  if (q.isLoading) return <PageLoader />;
  if (q.error) return <ErrorState error={q.error} onRetry={() => q.refetch()} />;
  return <>{children(q.data as T)}</>;
}

function DataQualityNote({ dq, clamped }: { dq: any; clamped?: boolean }) {
  const { t } = useI18n();
  const notes: string[] = [];
  if (clamped) notes.push(t('reports.dq.clamped'));
  if (Number(dq?.estimated_cost_entries) > 0) notes.push(t('reports.dq.estimated', { n: dq.estimated_cost_entries }));
  if (Number(dq?.zero_cost_products_sold) > 0) notes.push(t('reports.dq.zeroCost', { n: dq.zero_cost_products_sold }));
  if (!notes.length) return null;
  return <div className="mt-4"><Alert tone="amber" title={t('reports.dq.title')}><ul className="list-disc pl-5">{notes.map((n) => <li key={n}>{n}</li>)}</ul></Alert></div>;
}

function ProfitLoss({ period }: { period: Period }) {
  const { t, lang } = useI18n();
  const { id } = useBiz();
  const money = useMoney();
  const q = useRpc<any>('profit_and_loss', { p_business: id, p_from: period.from, p_to: period.to });
  return (
    <Q q={q}>{(p) => {
      const net = Number(p.net_sales);
      const rows: [string, number, string?, boolean?][] = [
        [t('reports.pl.grossSales'), Number(p.gross_sales), t('reports.pl.grossSalesHint')],
        [t('reports.pl.returns'), -Number(p.returns)],
        [t('reports.pl.tax'), -Number(p.tax_collected), t('reports.pl.taxHint')],
        [t('reports.pl.netSales'), net, undefined, true],
        [t('reports.pl.cogs'), -Number(p.cogs), t('reports.pl.cogsHint')],
        [t('reports.pl.grossProfit'), Number(p.gross_profit), undefined, true],
        [t('reports.pl.expenses'), -Number(p.operating_expenses)],
        [t('reports.pl.stockLosses'), -Number(p.stock_losses), t('reports.pl.stockLossesHint')],
        [t('reports.pl.operatingProfit'), Number(p.operating_profit), t('reports.pl.operatingProfitHint'), true],
      ];
      return (
        <div className="grid gap-4 lg:grid-cols-3">
          <Card className="lg:col-span-2">
            <CardHeader title={t('reports.pl.title')} subtitle={`${formatDate(p.effective_from, lang)} – ${formatDate(period.to, lang)}`} action={<ExportButton name="profit-and-loss" rows={() => rows.map(([l, v]) => ({ line: l, amount: v }))} />} />
            <table className="w-full text-sm">
              <tbody>
                {rows.map(([l, v, hint, bold]) => (
                  <tr key={l} className={bold ? 'border-t-2 border-gray-200 font-bold dark:border-gray-700' : 'border-t border-gray-100 dark:border-gray-800'}>
                    <td className="py-2.5 pr-3">{l}{hint && <span className="block text-xs font-normal text-ink-muted">{hint}</span>}</td>
                    <td className={`py-2.5 text-right tabular-nums ${v < 0 ? 'text-red-600' : ''}`}>{money(v)}</td>
                    <td className="w-20 py-2.5 text-right text-xs text-ink-muted">{net > 0 ? formatPct((v / net) * 100, lang, 0) : ''}</td>
                  </tr>
                ))}
              </tbody>
            </table>
            <p className="mt-3 text-xs text-ink-muted">{t('reports.pl.definitions')}</p>
            <DataQualityNote dq={p.data_quality} clamped={p.effective_from > period.from} />
          </Card>
          <div className="space-y-4">
            <Card>
              <CardHeader title={t('reports.pl.byCategory')} />
              {p.expenses_by_category.length === 0 ? <p className="text-sm text-ink-muted">{t('common.noData')}</p> :
                <div className="space-y-3">{p.expenses_by_category.map((e: any) => <HBar key={e.category} label={t(`expenseCategories.${e.category}`)} value={Number(e.amount)} max={Number(p.expenses_by_category[0].amount)} color="#ef4444" right={money(e.amount)} />)}</div>}
            </Card>
            <Card>
              <CardHeader title={t('reports.pl.cashView')} subtitle={t('reports.pl.cashViewSub')} />
              <dl className="space-y-2 text-sm">
                {[['cash_received', 1], ['refunds_paid', -1], ['supplier_payments', -1], ['expenses_paid', -1]].map(([k, s]) => (
                  <div key={k as string} className="flex justify-between"><dt>{t(`reports.pl.${k}`)}</dt><dd className="tabular-nums">{money(Number(p[k as string]) * (s as number))}</dd></div>
                ))}
                <div className="flex justify-between"><dt>{t('reports.pl.purchases')}</dt><dd className="tabular-nums">{money(p.purchases_total)}</dd></div>
                <div className="flex justify-between"><dt>{t('reports.pl.creditSales')}</dt><dd className="tabular-nums">{money(p.credit_sales)}</dd></div>
              </dl>
            </Card>
            {Number(p.tax_collected) > 0 && <Card><CardHeader title={t('reports.pl.taxSummary')} /><dl className="space-y-2 text-sm">
              <div className="flex justify-between"><dt>{t('reports.pl.taxCollected')}</dt><dd>{money(p.tax_collected)}</dd></div>
              <div className="flex justify-between"><dt>{t('reports.pl.taxOnPurchases')}</dt><dd>{money(p.purchase_tax)}</dd></div></dl>
              <p className="mt-2 text-xs text-ink-muted">{t('settings.taxDisclaimer')}</p></Card>}
          </div>
        </div>
      );
    }}</Q>
  );
}

function SalesReport({ period }: { period: Period }) {
  const { t, lang } = useI18n();
  const { id, has } = useBiz();
  const money = useMoney();
  const grain = grainFor(period.from, period.to);
  const series = useRpc<any[]>('sales_timeseries', { p_business: id, p_from: period.from, p_to: period.to, p_grain: grain });
  const week = useRpc<any>('weekday_pattern', { p_business: id, p_from: period.from, p_to: period.to }, { enabled: has('basic_analytics') && daysBetween(period.from, period.to) >= 27 });
  const methods = useQuery({
    queryKey: ['pay-methods', id, period],
    queryFn: async () => {
      const rows = unwrap(await supabase.from('payments').select('method,amount,kind').eq('business_id', id).in('kind', ['sale_payment', 'customer_payment', 'customer_refund'])
        .gte('paid_at', `${period.from}T00:00:00+01:00`).lte('paid_at', `${period.to}T23:59:59+01:00`).limit(20000)) as any[];
      const m: Record<string, number> = {};
      rows.forEach((r) => { m[r.method] = (m[r.method] ?? 0) + (r.kind === 'customer_refund' ? -1 : 1) * Number(r.amount); });
      return Object.entries(m).sort((a, b) => b[1] - a[1]);
    },
  });
  return (
    <Q q={series}>{(s) => (
      <div className="grid gap-4 lg:grid-cols-3">
        <Card className="lg:col-span-2">
          <CardHeader title={t('reports.sales.trend')} subtitle={t(`grain.${grain}`)} action={<ExportButton name="sales-trend" rows={() => s.map((r) => ({ period: r.bucket, net_sales: r.net_sales, gross_profit: r.gross_profit, transactions: r.transactions }))} />} />
          <SalesProfitChart data={s.map((d) => ({ ...d, net_sales: Number(d.net_sales), gross_profit: Number(d.gross_profit) }))} grain={grain} />
          <DataTable dense rows={[...s].reverse()} rowKey={(r) => r.bucket} columns={[
            { key: 'b', header: t('common.period'), render: (r) => formatDate(r.bucket, lang) },
            { key: 'n', header: t('dashboard.netSales'), align: 'right', render: (r) => money(r.net_sales) },
            { key: 'g', header: t('dashboard.grossProfit'), align: 'right', render: (r) => money(r.gross_profit) },
            { key: 't', header: t('reports.sales.transactions'), align: 'right', render: (r) => r.transactions },
          ]} />
        </Card>
        <div className="space-y-4">
          <Card>
            <CardHeader title={t('reports.sales.byMethod')} subtitle={t('reports.sales.byMethodSub')} />
            {(methods.data ?? []).length === 0 ? <p className="text-sm text-ink-muted">{t('common.noData')}</p> :
              <div className="space-y-3">{methods.data!.map(([m, v]) => <HBar key={m} label={t(`methods.${m}`)} value={v} max={methods.data![0][1]} color="#18813e" right={money(v)} />)}</div>}
          </Card>
          <Card>
            <CardHeader title={t('reports.sales.weekday')} subtitle={t('reports.sales.weekdaySub')} />
            {!week.data ? <p className="text-sm text-ink-muted">{t('reports.sales.weekdayNeedsData')}</p> : (
              <div className="space-y-3">{week.data.pattern.map((d: any) => <HBar key={d.dow} label={t(`reports.dow.${d.dow}`)} value={Number(d.avg_net_sales)} max={Math.max(...week.data.pattern.map((x: any) => Number(x.avg_net_sales)), 1)} color="#47bd6f" right={money(d.avg_net_sales)} />)}</div>
            )}
          </Card>
        </div>
      </div>
    )}</Q>
  );
}

function ProductsReport({ period }: { period: Period }) {
  const { t, lang } = useI18n();
  const { id } = useBiz();
  const money = useMoney();
  const [sort, setSort] = useState<'units' | 'revenue' | 'gross_profit' | 'margin_pct'>('revenue');
  const q = useRpc<any[]>('product_performance', { p_business: id, p_from: period.from, p_to: period.to });
  return (
    <Q q={q}>{(rows) => {
      const sold = rows.filter((r) => Number(r.units) !== 0 || Number(r.revenue) !== 0);
      const sorted = [...sold].sort((a, b) => Number(b[sort] ?? -1e9) - Number(a[sort] ?? -1e9));
      const topRev = [...sold].sort((a, b) => Number(b.revenue) - Number(a.revenue))[0];
      const topGp = [...sold].sort((a, b) => Number(b.gross_profit) - Number(a.gross_profit))[0];
      return (
        <Card>
          <CardHeader title={t('reports.products.title')} subtitle={t('reports.products.sub')} action={<div className="flex gap-2">
            <Select className="!h-8 w-48 text-xs" value={sort} onChange={(e) => setSort(e.target.value as any)}>
              <option value="revenue">{t('reports.products.byRevenue')}</option><option value="units">{t('reports.products.byUnits')}</option>
              <option value="gross_profit">{t('reports.products.byProfit')}</option><option value="margin_pct">{t('reports.products.byMargin')}</option>
            </Select>
            <ExportButton name="product-performance" rows={() => sorted.map((r) => ({ product: r.name, sku: r.sku, category: r.category, units: r.units, revenue: r.revenue, cogs: r.cogs, gross_profit: r.gross_profit, margin_pct: r.margin_pct, sales: r.sale_count, units_per_day: r.units_per_day, qty_on_hand: r.qty_on_hand }))} /></div>} />
          {topRev && topGp && topRev.id !== topGp.id && <div className="mb-4"><Alert tone="blue">{t('reports.products.revenueVsProfit', { rev: topRev.name, gp: topGp.name })}</Alert></div>}
          <DataTable rows={sorted} rowKey={(r) => r.id} empty={<p className="py-8 text-center text-sm text-ink-muted">{t('dashboard.noSalesPeriod')}</p>} columns={[
            { key: 'rank', header: '#', render: (r) => sorted.indexOf(r) + 1 },
            { key: 'n', header: t('dashboard.product'), render: (r) => <Link to={`/app/products/${r.id}`} className="font-semibold hover:underline">{r.name}</Link> },
            { key: 'u', header: t('dashboard.unitsSold'), align: 'right', render: (r) => `${formatNumber(r.units, lang)} ${r.base_unit}` },
            { key: 'r', header: t('dashboard.revenue'), align: 'right', render: (r) => money(r.revenue) },
            { key: 'c', header: t('dashboard.cogs'), align: 'right', hideOnMobile: true, render: (r) => money(r.cogs) },
            { key: 'g', header: t('dashboard.grossProfit'), align: 'right', render: (r) => <span className={Number(r.gross_profit) < 0 ? 'text-red-600' : ''}>{money(r.gross_profit)}</span> },
            { key: 'm', header: t('products.margin'), align: 'right', render: (r) => r.margin_pct == null ? '—' : <span className={Number(r.margin_pct) < 10 ? 'text-amber-700' : ''}>{formatPct(r.margin_pct, lang)}</span> },
            { key: 'v', header: t('reports.products.perDay'), align: 'right', hideOnMobile: true, render: (r) => formatNumber(r.units_per_day, lang, 2) },
          ]} />
        </Card>
      );
    }}</Q>
  );
}

function CategoriesReport({ period }: { period: Period }) {
  const { t, lang } = useI18n();
  const { id } = useBiz();
  const money = useMoney();
  const q = useRpc<any[]>('category_performance', { p_business: id, p_from: period.from, p_to: period.to });
  return (
    <Q q={q}>{(rows) => (
      <Card>
        <CardHeader title={t('reports.tabs.categories')} action={<ExportButton name="categories" rows={() => rows.map((r) => ({ category: r.category ?? t('common.uncategorised'), units: r.units, revenue: r.revenue, gross_profit: r.gross_profit, margin_pct: r.margin_pct, revenue_share_pct: r.revenue_share_pct, inventory_value: r.inventory_value, products: r.products }))} />} />
        <DataTable rows={rows} rowKey={(r) => r.id ?? 'none'} empty={<p className="py-8 text-center text-sm text-ink-muted">{t('common.noData')}</p>} columns={[
          { key: 'c', header: t('common.category'), render: (r) => <span className="font-semibold">{r.category ?? t('common.uncategorised')}</span> },
          { key: 'u', header: t('dashboard.unitsSold'), align: 'right', render: (r) => formatNumber(r.units, lang) },
          { key: 'r', header: t('dashboard.revenue'), align: 'right', render: (r) => money(r.revenue) },
          { key: 's', header: t('reports.share'), align: 'right', hideOnMobile: true, render: (r) => formatPct(r.revenue_share_pct, lang) },
          { key: 'g', header: t('dashboard.grossProfit'), align: 'right', render: (r) => money(r.gross_profit) },
          { key: 'm', header: t('products.margin'), align: 'right', render: (r) => formatPct(r.margin_pct, lang) },
          { key: 'i', header: t('reports.inventoryInvestment'), align: 'right', hideOnMobile: true, render: (r) => money(r.inventory_value) },
        ]} />
      </Card>
    )}</Q>
  );
}

function ValuationReport() {
  const { t, lang } = useI18n();
  const { id } = useBiz();
  const money = useMoney();
  const q = useQuery({
    queryKey: ['valuation', id],
    queryFn: async () => {
      const rows = unwrap(await supabase.from('products').select('id,name,sku,base_unit,qty_on_hand,avg_cost,stock_value,selling_price,categories(name)').eq('business_id', id).neq('qty_on_hand', 0).order('stock_value', { ascending: false }).limit(5000)) as any[];
      const est = unwrap(await supabase.from('stock_movements').select('product_id').eq('business_id', id).eq('cost_estimated', true).limit(5000)) as any[];
      const set = new Set(est.map((e) => e.product_id));
      return rows.map((r) => ({ ...r, estimated: set.has(r.id) }));
    },
  });
  return (
    <Q q={q}>{(rows) => {
      const total = rows.reduce((a, r) => a + Number(r.stock_value), 0);
      const retail = rows.reduce((a, r) => a + Number(r.qty_on_hand) * Number(r.selling_price), 0);
      return (
        <Card>
          <CardHeader title={t('reports.valuation.title')} subtitle={t('reports.valuation.sub')} action={<ExportButton name="inventory-valuation" rows={() => rows.map((r) => ({ product: r.name, sku: r.sku, category: r.categories?.name, qty: r.qty_on_hand, unit: r.base_unit, avg_cost: r.avg_cost, value: Math.round(Number(r.stock_value)), cost_estimated: r.estimated }))} />} />
          <div className="mb-4 grid gap-3 sm:grid-cols-3">
            <div className="rounded-xl bg-gray-50 p-3 dark:bg-gray-800/60"><p className="text-xs text-ink-muted">{t('reports.valuation.atCost')}</p><p className="text-xl font-extrabold">{money(total)}</p></div>
            <div className="rounded-xl bg-gray-50 p-3 dark:bg-gray-800/60"><p className="text-xs text-ink-muted">{t('reports.valuation.atRetail')}</p><p className="text-xl font-extrabold">{money(retail)}</p></div>
            <div className="rounded-xl bg-gray-50 p-3 dark:bg-gray-800/60"><p className="text-xs text-ink-muted">{t('reports.valuation.potentialMargin')}</p><p className="text-xl font-extrabold">{money(retail - total)}</p></div>
          </div>
          <DataTable rows={rows} rowKey={(r) => r.id} columns={[
            { key: 'n', header: t('dashboard.product'), render: (r) => <span><Link to={`/app/products/${r.id}`} className="font-semibold hover:underline">{r.name}</Link>{r.estimated && <Badge tone="amber" className="ml-1">{t('common.estimated')}</Badge>}</span> },
            { key: 'q', header: t('products.inStockQty'), align: 'right', render: (r) => `${formatNumber(r.qty_on_hand, lang)} ${r.base_unit}` },
            { key: 'c', header: t('products.avgCost'), align: 'right', render: (r) => money(r.avg_cost) },
            { key: 'v', header: t('products.stockValue'), align: 'right', render: (r) => money(r.stock_value) },
            { key: 's', header: t('reports.share'), align: 'right', hideOnMobile: true, render: (r) => total ? formatPct((Number(r.stock_value) / total) * 100, lang) : '—' },
          ]} />
          <p className="mt-3 text-xs text-ink-muted">{t('reports.valuation.method')}</p>
        </Card>
      );
    }}</Q>
  );
}

function RestockReport() {
  const { t, lang } = useI18n();
  const { id } = useBiz();
  const money = useMoney();
  const [lookback, setLookback] = useState(30);
  const q = useRpc<any[]>('restock_recommendations', { p_business: id, p_lookback: lookback });
  const tone = { urgent: 'red', soon: 'amber', plan: 'blue' } as const;
  return (
    <Q q={q}>{(rows) => (
      <Card>
        <CardHeader title={t('reports.restock.title')} subtitle={t('reports.restock.sub', { days: lookback })} action={<div className="flex gap-2">
          <Select className="!h-8 w-36 text-xs" value={lookback} onChange={(e) => setLookback(Number(e.target.value))}>{[14, 30, 60, 90].map((d) => <option key={d} value={d}>{t('reports.restock.lookback', { n: d })}</option>)}</Select>
          <ExportButton name="restock" rows={() => rows.map((r) => ({ product: r.name, priority: r.priority, qty_on_hand: r.qty_on_hand, incoming: r.incoming, avg_daily: r.avg_daily, days_of_cover: r.days_of_cover, lead_days: r.lead_days, recommended_qty: r.recommended_qty, purchase_units: r.recommended_purchase_units, purchase_unit: r.purchase_unit, supplier: r.supplier_name, estimated_cost: r.estimated_cost, confidence: r.confidence }))} /></div>} />
        <DataTable rows={rows} rowKey={(r) => r.product_id} empty={<p className="py-8 text-center text-sm text-ink-muted">{t('reports.restock.none')}</p>} columns={[
          { key: 'n', header: t('dashboard.product'), render: (r) => <div><Link to={`/app/products/${r.product_id}`} className="font-semibold hover:underline">{r.name}</Link><p className="text-xs text-ink-muted">{r.supplier_name ?? ''}</p></div> },
          { key: 'p', header: t('reports.restock.priority'), render: (r) => <Badge tone={tone[r.priority as keyof typeof tone]}>{t(`reports.restock.p_${r.priority}`)}</Badge> },
          { key: 'q', header: t('products.inStockQty'), align: 'right', render: (r) => `${formatNumber(r.qty_on_hand, lang)}${Number(r.incoming) ? ` (+${formatNumber(r.incoming, lang)})` : ''}` },
          { key: 'd', header: t('reports.restock.perDay'), align: 'right', render: (r) => formatNumber(r.avg_daily, lang, 2) },
          { key: 'c', header: t('reports.restock.cover'), align: 'right', render: (r) => r.days_of_cover == null ? '—' : `${formatNumber(r.days_of_cover, lang, 0)} ${t('common.days')}` },
          { key: 'r', header: t('reports.restock.recommended'), align: 'right', render: (r) => <b>{formatNumber(r.recommended_qty, lang)} {r.base_unit}{r.recommended_purchase_units ? <span className="block text-xs font-normal text-ink-muted">≈ {r.recommended_purchase_units} {r.purchase_unit}</span> : null}</b> },
          { key: 'e', header: t('reports.restock.estCost'), align: 'right', hideOnMobile: true, render: (r) => money(r.estimated_cost) },
          { key: 'f', header: t('reports.restock.confidence'), hideOnMobile: true, render: (r) => <Badge tone={r.confidence === 'high' ? 'green' : r.confidence === 'medium' ? 'blue' : 'gray'}>{t(`reports.conf.${r.confidence}`)}</Badge> },
        ]} />
        <p className="mt-3 text-xs text-ink-muted">{t('reports.restock.method')}</p>
      </Card>
    )}</Q>
  );
}

function SlowReport() {
  const { t, lang } = useI18n();
  const { id } = useBiz();
  const money = useMoney();
  const q = useRpc<any[]>('slow_moving_products', { p_business: id, p_days: null });
  return (
    <Q q={q}>{(rows) => (
      <Card>
        <CardHeader title={t('reports.slow.title')} subtitle={t('reports.slow.sub', { days: rows[0]?.window_days ?? 30 })} action={<ExportButton name="slow-moving" rows={() => rows.map((r) => ({ product: r.name, classification: r.classification, qty: r.qty_on_hand, stock_value: Math.round(r.stock_value), units_in_window: r.units_in_window, days_of_cover: r.days_of_cover, margin_pct: r.price_margin_pct, last_sold_at: r.last_sold_at, last_received_at: r.last_received_at }))} />} />
        <div className="mb-4"><Alert tone="blue">{t('reports.slow.note')}</Alert></div>
        <DataTable rows={rows} rowKey={(r) => r.id} empty={<p className="py-8 text-center text-sm text-ink-muted">{t('reports.slow.none')}</p>} columns={[
          { key: 'n', header: t('dashboard.product'), render: (r) => <Link to={`/app/products/${r.id}`} className="font-semibold hover:underline">{r.name}</Link> },
          { key: 'c', header: t('common.type'), render: (r) => <Badge tone={r.classification === 'no_sales' ? 'red' : 'amber'}>{t(`reports.slow.${r.classification}`)}</Badge> },
          { key: 'v', header: t('products.stockValue'), align: 'right', render: (r) => money(r.stock_value) },
          { key: 'u', header: t('reports.slow.soldInWindow'), align: 'right', render: (r) => formatNumber(r.units_in_window, lang) },
          { key: 'd', header: t('reports.restock.cover'), align: 'right', hideOnMobile: true, render: (r) => r.days_of_cover == null ? '∞' : `${formatNumber(r.days_of_cover, lang, 0)} ${t('common.days')}` },
          { key: 'm', header: t('products.margin'), align: 'right', render: (r) => formatPct(r.price_margin_pct, lang) },
          { key: 'l', header: t('reports.slow.lastSold'), hideOnMobile: true, render: (r) => r.last_sold_at ? formatDate(r.last_sold_at, lang) : t('insights.never') },
          { key: 'o', header: '', render: (r) => r.was_out_of_stock_in_window ? <Badge tone="gray">{t('reports.slow.wasOut')}</Badge> : null },
        ]} />
      </Card>
    )}</Q>
  );
}

function AgingReport() {
  const { t, lang } = useI18n();
  const { id } = useBiz();
  const money = useMoney();
  const q = useRpc<any>('inventory_aging', { p_business: id });
  return (
    <Q q={q}>{(d) => {
      const b = d.buckets;
      const max = Math.max(1, ...Object.values(b).map(Number));
      return (
        <div className="grid gap-4 lg:grid-cols-3">
          <Card>
            <CardHeader title={t('reports.aging.buckets')} subtitle={t('reports.aging.sub')} />
            <div className="space-y-3">
              {[['d0_30', '0–30'], ['d31_60', '31–60'], ['d61_90', '61–90'], ['d90_plus', '90+']].map(([k, l]) => <HBar key={k} label={`${l} ${t('common.days')}`} value={Number(b[k])} max={max} color={k === 'd90_plus' ? '#ef4444' : '#47bd6f'} right={money(b[k])} />)}
            </div>
            <p className="mt-3 text-xs text-ink-muted">{t('reports.aging.method')}</p>
          </Card>
          <Card className="lg:col-span-2">
            <CardHeader title={t('reports.aging.products')} action={<ExportButton name="inventory-aging" rows={() => d.products.map((r: any) => ({ product: r.name, qty: r.qty_on_hand, value: r.value, weighted_age_days: r.weighted_age_days, oldest_days: r.oldest_days }))} />} />
            <DataTable rows={d.products} rowKey={(r: any) => r.id} columns={[
              { key: 'n', header: t('dashboard.product'), render: (r: any) => <Link to={`/app/products/${r.id}`} className="font-semibold hover:underline">{r.name}</Link> },
              { key: 'q', header: t('products.inStockQty'), align: 'right', render: (r: any) => `${formatNumber(r.qty_on_hand, lang)} ${r.base_unit}` },
              { key: 'v', header: t('products.stockValue'), align: 'right', render: (r: any) => money(r.value) },
              { key: 'a', header: t('reports.aging.avgAge'), align: 'right', render: (r: any) => `${r.weighted_age_days ?? '—'} ${t('common.days')}` },
              { key: 'o', header: t('reports.aging.oldest'), align: 'right', hideOnMobile: true, render: (r: any) => `${r.oldest_days ?? '—'} ${t('common.days')}` },
            ] as Column<any>[]} />
          </Card>
        </div>
      );
    }}</Q>
  );
}

function SuppliersReport({ period }: { period: Period }) {
  const { t, lang } = useI18n();
  const { id } = useBiz();
  const money = useMoney();
  const q = useRpc<any>('supplier_comparison', { p_business: id, p_from: period.from, p_to: period.to });
  return (
    <Q q={q}>{(d) => (
      <div className="space-y-4">
        <Card>
          <CardHeader title={t('reports.suppliers.title')} action={<ExportButton name="suppliers" rows={() => d.suppliers.map((s: any) => ({ supplier: s.name, purchases: s.purchases, purchased: s.purchased, on_time: s.on_time, tracked: s.deliveries_tracked, avg_lead_days: s.avg_lead_days, returns: s.returns_count, balance: s.balance, terms_days: s.payment_terms_days }))} />} />
          <DataTable rows={d.suppliers} rowKey={(r: any) => r.id} empty={<p className="py-8 text-center text-sm text-ink-muted">{t('common.noData')}</p>} columns={[
            { key: 'n', header: t('purchases.supplier'), render: (s: any) => <Link to={`/app/suppliers/${s.id}`} className="font-semibold hover:underline">{s.name}</Link> },
            { key: 'p', header: t('reports.suppliers.purchased'), align: 'right', render: (s: any) => `${money(s.purchased)} (${s.purchases})` },
            { key: 'o', header: t('reports.suppliers.onTime'), align: 'right', render: (s: any) => s.deliveries_tracked ? `${s.on_time}/${s.deliveries_tracked}` : '—' },
            { key: 'l', header: t('reports.suppliers.avgLead'), align: 'right', hideOnMobile: true, render: (s: any) => s.avg_lead_days == null ? '—' : `${formatNumber(s.avg_lead_days, lang, 1)} ${t('common.days')}` },
            { key: 'r', header: t('reports.suppliers.returns'), align: 'right', hideOnMobile: true, render: (s: any) => s.returns_count },
            { key: 't', header: t('parties.paymentTerms'), align: 'right', hideOnMobile: true, render: (s: any) => s.payment_terms_days == null ? '—' : `${s.payment_terms_days} ${t('common.days')}` },
            { key: 'b', header: t('parties.weOwe'), align: 'right', render: (s: any) => money(s.balance) },
          ] as Column<any>[]} />
        </Card>
        <Card>
          <CardHeader title={t('reports.suppliers.prices')} subtitle={t('reports.suppliers.pricesSub')} />
          <DataTable rows={d.price_comparison} rowKey={(r: any) => r.product_id + r.supplier_id} empty={<p className="py-6 text-center text-sm text-ink-muted">{t('reports.suppliers.noComparison')}</p>} columns={[
            { key: 'p', header: t('dashboard.product'), render: (r: any) => <span className="font-semibold">{r.product_name}</span> },
            { key: 's', header: t('purchases.supplier'), render: (r: any) => r.supplier_name },
            { key: 'a', header: t('reports.suppliers.avgCost'), align: 'right', render: (r: any) => `${money(r.avg_unit_cost)}/${r.base_unit}` },
            { key: 'm', header: t('reports.suppliers.minCost'), align: 'right', hideOnMobile: true, render: (r: any) => money(r.min_unit_cost) },
            { key: 'l', header: t('reports.suppliers.last'), hideOnMobile: true, render: (r: any) => formatDate(r.last_purchase, lang) },
          ] as Column<any>[]} />
        </Card>
      </div>
    )}</Q>
  );
}

function CustomersReport() {
  const { t, lang } = useI18n();
  const { id } = useBiz();
  const money = useMoney();
  const q = useRpc<any[]>('customer_balances', { p_business: id });
  return (
    <Q q={q}>{(rows) => {
      const owing = rows.filter((r) => Number(r.balance) !== 0);
      return (
        <Card>
          <CardHeader title={t('reports.tabs.customers')} subtitle={t('reports.customers.sub')} action={<ExportButton name="customer-balances" rows={() => owing.map((c) => ({ customer: c.name, phone: c.phone, balance: c.balance, overdue: c.overdue, oldest_due: c.oldest_due, last_sale: c.last_sale }))} />} />
          <DataTable rows={owing} rowKey={(r) => r.id} empty={<p className="py-8 text-center text-sm text-ink-muted">{t('reports.customers.none')}</p>} columns={[
            { key: 'n', header: t('pos.customer'), render: (c) => <Link to={`/app/customers/${c.id}`} className="font-semibold hover:underline">{c.name}</Link> },
            { key: 'b', header: t('parties.owesUs'), align: 'right', render: (c) => money(c.balance) },
            { key: 'o', header: t('parties.overdue'), align: 'right', render: (c) => Number(c.overdue) > 0 ? <span className="text-red-600">{money(c.overdue)}</span> : '—' },
            { key: 'd', header: t('reports.customers.oldestDue'), hideOnMobile: true, render: (c) => c.oldest_due ? formatDate(c.oldest_due, lang) : '' },
            { key: 'l', header: t('parties.lastSale'), hideOnMobile: true, render: (c) => c.last_sale ? formatDate(c.last_sale, lang) : '' },
          ]} />
        </Card>
      );
    }}</Q>
  );
}

function DiscrepancyReport({ period }: { period: Period }) {
  const { t, lang } = useI18n();
  const { id } = useBiz();
  const money = useMoney();
  const q = useRpc<any>('inventory_discrepancies', { p_business: id, p_from: period.from, p_to: period.to });
  return (
    <Q q={q}>{(d) => (
      <div className="space-y-4">
        {d.negative_stock.length > 0 && <Alert tone="red" title={t('reports.disc.negative')}>{d.negative_stock.map((p: any) => `${p.name} (${p.qty_on_hand})`).join(', ')}</Alert>}
        <Card>
          <CardHeader title={t('reports.disc.adjustments')} subtitle={t('reports.disc.adjustmentsSub')} action={<ExportButton name="adjustments" rows={() => d.adjustments.map((a: any) => ({ product: a.name, adjustments: a.adjustments, loss_events: a.loss_events, net_quantity: a.net_quantity, loss_value: a.loss_value }))} />} />
          <DataTable rows={d.adjustments} rowKey={(r: any) => r.id} empty={<p className="py-6 text-center text-sm text-ink-muted">{t('reports.disc.none')}</p>} columns={[
            { key: 'n', header: t('dashboard.product'), render: (r: any) => <span className="font-semibold">{r.name}{Number(r.loss_events) >= 2 && <Badge tone="red" className="ml-1">{t('reports.disc.repeated')}</Badge>}</span> },
            { key: 'a', header: t('reports.disc.count'), align: 'right', render: (r: any) => r.adjustments },
            { key: 'q', header: t('reports.disc.netQty'), align: 'right', render: (r: any) => `${formatNumber(r.net_quantity, lang)} ${r.base_unit}` },
            { key: 'v', header: t('reports.disc.lossValue'), align: 'right', render: (r: any) => <span className={Number(r.loss_value) > 0 ? 'text-red-600' : 'text-brand-700'}>{money(r.loss_value)}</span> },
          ] as Column<any>[]} />
        </Card>
        <Card>
          <CardHeader title={t('reports.disc.counts')} />
          <DataTable rows={d.count_differences} rowKey={(r: any) => r.number + r.name} empty={<p className="py-6 text-center text-sm text-ink-muted">{t('common.noData')}</p>} columns={[
            { key: 'c', header: t('common.reference'), render: (r: any) => <div><p className="font-semibold">{r.number}</p><p className="text-xs text-ink-muted">{formatDateTime(r.completed_at, lang)}</p></div> },
            { key: 'p', header: t('dashboard.product'), render: (r: any) => r.name },
            { key: 'd', header: t('inventory.difference'), align: 'right', render: (r: any) => `${formatNumber(r.system_qty_at_completion, lang)} → ${formatNumber(r.counted_qty, lang)}` },
            { key: 'v', header: t('inventory.valueDifference'), align: 'right', render: (r: any) => money(r.value_difference) },
            { key: 'r', header: t('common.reason'), hideOnMobile: true, render: (r: any) => r.reason },
          ] as Column<any>[]} />
        </Card>
      </div>
    )}</Q>
  );
}

function EfficiencyReport({ period }: { period: Period }) {
  const { t, lang } = useI18n();
  const { id } = useBiz();
  const money = useMoney();
  const q = useRpc<any[]>('purchasing_efficiency', { p_business: id, p_from: period.from, p_to: period.to });
  const tone = { no_sales_after_purchase: 'red', possible_overbuying: 'amber', stocked_out: 'purple', balanced: 'green' } as const;
  return (
    <Q q={q}>{(rows) => (
      <Card>
        <CardHeader title={t('reports.eff.title')} subtitle={t('reports.eff.sub')} action={<ExportButton name="purchasing-efficiency" rows={() => rows.map((r) => ({ product: r.name, received_qty: r.received_qty, received_value: r.received_value, sold_qty: r.sold_qty, ratio: r.bought_to_sold_ratio, days_of_cover: r.days_of_cover, assessment: r.assessment }))} />} />
        <DataTable rows={rows} rowKey={(r) => r.id} empty={<p className="py-8 text-center text-sm text-ink-muted">{t('reports.eff.none')}</p>} columns={[
          { key: 'n', header: t('dashboard.product'), render: (r) => <Link to={`/app/products/${r.id}`} className="font-semibold hover:underline">{r.name}</Link> },
          { key: 'r', header: t('reports.eff.received'), align: 'right', render: (r) => `${formatNumber(r.received_qty, lang)} · ${money(r.received_value)}` },
          { key: 's', header: t('reports.eff.sold'), align: 'right', render: (r) => formatNumber(r.sold_qty, lang) },
          { key: 'x', header: t('reports.eff.ratio'), align: 'right', render: (r) => r.bought_to_sold_ratio ?? '—' },
          { key: 'c', header: t('reports.restock.cover'), align: 'right', hideOnMobile: true, render: (r) => r.days_of_cover == null ? '—' : `${r.days_of_cover} ${t('common.days')}` },
          { key: 'a', header: t('reports.eff.assessment'), render: (r) => <Badge tone={tone[r.assessment as keyof typeof tone]}>{t(`reports.eff.${r.assessment}`)}</Badge> },
        ]} />
      </Card>
    )}</Q>
  );
}

/** Where sales happen (shop, WhatsApp, Facebook, phone, marketplace…): revenue net of returns, cost, profit and balances. */
function ChannelsReport({ period }: { period: Period }) {
  const { t } = useI18n();
  const { id } = useBiz();
  const money = useMoney();
  const q = useRpc<any[]>('sales_by_channel', { p_business: id, p_from: period.from, p_to: period.to });
  return (
    <Card>
      <CardHeader title={t('reports.tabs.channels')} subtitle={t('reports.channels.sub')}
        action={<ExportButton name={`sales-by-channel-${period.from}-to-${period.to}`} rows={() => (q.data ?? []).map((r) => ({ channel: t(`channels.${r.channel}`), sales: r.sales, cancelled: r.cancelled,
          revenue_net_of_returns: r.revenue, cost_of_goods: r.cost, gross_profit: r.gross_profit, paid: r.paid, outstanding: r.outstanding, sales_missing_cost: r.missing_cost }))} />} />
      <Q q={q}>{(rows) => {
        const total = rows.reduce((a, r) => a + Number(r.revenue), 0);
        const missing = rows.reduce((a, r) => a + Number(r.missing_cost), 0);
        return rows.length === 0 ? <p className="py-8 text-center text-sm text-ink-muted">{t('common.noData')}</p> : (
          <>
            {missing > 0 && <div className="mb-3"><Alert tone="amber">{t('reports.channels.estimated', { n: missing })}</Alert></div>}
            <div className="mb-4 space-y-2">
              {rows.map((r) => (
                <div key={r.channel}>
                  <div className="flex justify-between text-sm"><span className="font-semibold">{t(`channels.${r.channel}`)}</span><span>{money(r.revenue)} · {total > 0 ? Math.round((Number(r.revenue) / total) * 100) : 0}%</span></div>
                  <div className="mt-1 h-2 rounded-full bg-gray-100 dark:bg-gray-800"><div className="h-2 rounded-full bg-brand-600" style={{ width: `${total > 0 ? Math.max(2, (Number(r.revenue) / total) * 100) : 0}%` }} /></div>
                </div>
              ))}
            </div>
            <DataTable rows={rows} rowKey={(r) => r.channel} columns={[
              { key: 'c', header: t('sales.channel'), render: (r) => <span className="font-semibold">{t(`channels.${r.channel}`)}</span> },
              { key: 'n', header: t('reports.channels.sales'), align: 'right', render: (r) => <span>{r.sales}{Number(r.cancelled) > 0 && <span className="block text-xs text-ink-muted">{t('reports.channels.cancelled', { n: r.cancelled })}</span>}</span> },
              { key: 'r', header: t('reports.channels.revenue'), align: 'right', render: (r) => money(r.revenue) },
              { key: 'g', header: t('dashboard.grossProfit'), align: 'right', hideOnMobile: true, render: (r) => <span>{money(r.gross_profit)}{Number(r.missing_cost) > 0 && <span className="block text-xs text-amber-700">{t('reports.channels.estimatedShort')}</span>}</span> },
              { key: 'p', header: t('common.paid'), align: 'right', hideOnMobile: true, render: (r) => money(r.paid) },
              { key: 'o', header: t('sales.outstanding'), align: 'right', render: (r) => Number(r.outstanding) > 0 ? <span className="text-amber-700">{money(r.outstanding)}</span> : '—' },
            ]} />
            <p className="mt-3 text-xs text-ink-muted">{t('reports.channels.note')}</p>
          </>
        );
      }}</Q>
    </Card>
  );
}

function PaymentsReport({ period }: { period: Period }) {
  const { t, lang } = useI18n();
  const { id } = useBiz();
  const money = useMoney();
  const [kind, setKind] = useState('');
  const q = useQuery({
    queryKey: ['payments-report', id, period, kind],
    queryFn: async () => {
      let query = supabase.from('payments').select('*, customers(name), suppliers(name), sales(number), purchases(number), expenses(description)').eq('business_id', id)
        .gte('paid_at', `${period.from}T00:00:00+01:00`).lte('paid_at', `${period.to}T23:59:59+01:00`).order('paid_at', { ascending: false }).limit(2000);
      if (kind) query = query.eq('kind', kind);
      return unwrap(await query) as any[];
    },
  });
  const totals = useMemo(() => {
    const rows = q.data ?? [];
    return { in: rows.filter((r) => r.direction === 'in').reduce((a, r) => a + Number(r.amount), 0), out: rows.filter((r) => r.direction === 'out').reduce((a, r) => a + Number(r.amount), 0) };
  }, [q.data]);
  return (
    <Card>
      <CardHeader title={t('reports.tabs.payments')} subtitle={t('reports.payments.sub', { inn: money(totals.in), out: money(totals.out) })} action={<div className="flex gap-2">
        <Select className="!h-8 w-48 text-xs" value={kind} onChange={(e) => setKind(e.target.value)}><option value="">{t('common.all')}</option>{['sale_payment', 'customer_payment', 'customer_refund', 'supplier_payment', 'supplier_refund', 'expense_payment', 'expense_refund'].map((k) => <option key={k} value={k}>{t(`paymentKinds.${k}`)}</option>)}</Select>
        <ExportButton name="payments" rows={() => (q.data ?? []).map((p) => ({ date: p.paid_at, kind: p.kind, direction: p.direction, method: p.method, amount: p.amount, reference: p.reference, party: p.customers?.name ?? p.suppliers?.name ?? '', document: p.sales?.number ?? p.purchases?.number ?? p.expenses?.description ?? '' }))} /></div>} />
      <Q q={q}>{(rows) => (
        <DataTable rows={rows} rowKey={(r) => r.id} empty={<p className="py-8 text-center text-sm text-ink-muted">{t('common.noData')}</p>} columns={[
          { key: 'd', header: t('common.date'), render: (p) => formatDateTime(p.paid_at, lang) },
          { key: 'k', header: t('common.type'), render: (p) => t(`paymentKinds.${p.kind}`) },
          { key: 'm', header: t('common.method'), render: (p) => <span>{t(`methods.${p.method}`)}{p.reference && <span className="block font-mono text-xs text-ink-muted">{p.reference}</span>}</span> },
          { key: 'p', header: t('reports.payments.party'), hideOnMobile: true, render: (p) => p.customers?.name ?? p.suppliers?.name ?? p.expenses?.description ?? '' },
          { key: 'doc', header: t('common.reference'), hideOnMobile: true, render: (p) => p.sales ? <Link to={`/app/sales/${p.sale_id}`} className="hover:underline">{p.sales.number}</Link> : p.purchases ? <Link to={`/app/purchases/${p.purchase_id}`} className="hover:underline">{p.purchases.number}</Link> : '' },
          { key: 'a', header: t('common.amount'), align: 'right', render: (p) => <span className={p.direction === 'out' ? 'text-red-600' : 'text-brand-700'}>{p.direction === 'out' ? '− ' : '+ '}{money(p.amount)}</span> },
        ]} />
      )}</Q>
    </Card>
  );
}
