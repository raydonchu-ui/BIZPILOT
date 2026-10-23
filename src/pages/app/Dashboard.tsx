import { useEffect, useMemo, useState } from 'react';
import { Link } from 'react-router-dom';
import { useQuery } from '@tanstack/react-query';
import clsx from 'clsx';
import {
  AlertTriangle, ArrowRight, Bot, Box, ChevronRight, Coins, Hourglass, MessageSquareText, Package, PackageX, Receipt,
  ShoppingBag, ShoppingCart, Sparkles, TrendingUp, UserPlus,
} from 'lucide-react';
import { useI18n } from '../../i18n';
import { useBiz } from '../../lib/business';
import { useAuth } from '../../lib/auth';
import { useRpc, unwrap } from '../../lib/api';
import { supabase } from '../../lib/supabase';
import { grainFor } from '../../lib/dates';
import { formatCompact, formatNumber, formatPct, formatRelative, pctChange } from '../../lib/format';
import { Alert, Card, CardHeader, EmptyState, ErrorState, LinkButton, PageLoader, Select, StatCard, useMoney } from '../../components/ui';
import { PeriodPicker, usePeriod } from '../../components/PeriodPicker';
import { DonutChart, HBar, SalesProfitChart, ValueTrendChart, CHART_COLORS } from '../../components/charts';
import { Insight, InsightCard } from '../../components/Insights';
import { useQuickActions } from '../../components/layout/AppLayout';
import { dashboardVisitedKey } from './SetupChecklist';

function greetingKey() {
  const h = new Date().getHours();
  return h < 12 ? 'dashboard.goodMorning' : h < 18 ? 'dashboard.goodAfternoon' : 'dashboard.goodEvening';
}

export default function Dashboard() {
  const { can, id } = useBiz();
  useEffect(() => { try { localStorage.setItem(dashboardVisitedKey(id), '1'); } catch { /* ignore */ } }, [id]);
  return can('reports.view') ? <OwnerDashboard /> : <CounterDashboard />;
}

function Greeting({ right }: { right?: React.ReactNode }) {
  const { t } = useI18n();
  const { context } = useAuth();
  const first = (context?.profile?.full_name ?? '').split(' ')[0];
  return (
    <div className="mb-5 flex flex-col gap-3 sm:flex-row sm:items-end sm:justify-between">
      <div>
        <h1 className="text-2xl font-extrabold tracking-tight sm:text-3xl">{t(greetingKey(), { name: first })} <span aria-hidden>👋</span></h1>
        <p className="mt-1 text-sm text-ink-muted dark:text-gray-400">{t('dashboard.subtitle')}</p>
      </div>
      {right}
    </div>
  );
}

function OwnerDashboard() {
  const { t, lang } = useI18n();
  const { id, has, biz } = useBiz();
  const money = useMoney();
  const [period, setPeriod] = usePeriod('this_month');
  const [grainSel, setGrainSel] = useState<'auto' | 'day' | 'week' | 'month'>('auto');
  const grain = grainSel === 'auto' ? grainFor(period.from, period.to) : grainSel;
  const args = { p_business: id, p_from: period.from, p_to: period.to };
  const summary = useRpc<any>('dashboard_summary', args);
  const series = useRpc<any[]>('sales_timeseries', { ...args, p_grain: grain });
  const top = useRpc<any[]>('top_products', { ...args, p_limit: 5 });
  const cats = useRpc<any[]>('category_performance', args, { enabled: has('basic_analytics') });
  const inv = useRpc<any[]>('inventory_value_series', args);
  const insights = useRpc<Insight[]>('business_insights', args, { enabled: has('basic_analytics') });

  if (summary.isLoading) return <PageLoader />;
  if (summary.error) return <ErrorState error={summary.error} onRetry={() => summary.refetch()} />;
  const s = summary.data;
  const cur = s.period; const prev = s.previous;
  const dq = s.data_quality;
  const growing = Number(cur.net_sales) > 0 && Number(cur.net_sales) > Number(prev.net_sales) && Number(prev.net_sales) > 0;
  const noSalesEver = Number(dq.sales_count) === 0;

  const catData = (cats.data ?? []).filter((c) => Number(c.revenue) > 0);
  const catTop = catData.slice(0, 5);
  const catOther = catData.slice(5).reduce((a, c) => a + Number(c.revenue), 0);
  const donut = [...catTop.map((c) => ({ name: c.category ?? t('common.uncategorised'), value: Number(c.revenue) })), ...(catOther > 0 ? [{ name: t('dashboard.others'), value: catOther }] : [])];
  const totalCat = donut.reduce((a, c) => a + c.value, 0);

  return (
    <div>
      <Greeting right={<PeriodPicker value={period} onChange={setPeriod} />} />

      {growing && (
        <div className="mb-4 flex items-center gap-3 rounded-2xl bg-gradient-to-r from-brand-700 to-brand-600 px-4 py-3 text-white">
          <TrendingUp className="h-6 w-6 shrink-0" />
          <div className="text-sm"><p className="font-bold">{t('dashboard.growingTitle')}</p><p className="text-brand-50">{t('dashboard.growingBody', { pct: formatPct(pctChange(Number(cur.net_sales), Number(prev.net_sales)), lang, 0) })}</p></div>
        </div>
      )}
      {s.history_clamped && <div className="mb-4"><Alert tone="blue">{t('dashboard.historyClamped')}</Alert></div>}
      {noSalesEver && (
        <div className="mb-4"><Alert tone="green" title={t('dashboard.welcomeTitle')} action={<LinkButton to="/app/setup" size="sm">{t('nav.setup')}</LinkButton>}>{t('dashboard.welcomeBody')}</Alert></div>
      )}

      <div className="grid grid-cols-2 gap-3 md:grid-cols-3 xl:grid-cols-5 sm:gap-4">
        <StatCard label={t('dashboard.totalSales')} value={money(cur.net_sales)} icon={<ShoppingCart className="h-5 w-5" />} tone="green" delta={pctChange(Number(cur.net_sales), Number(prev.net_sales))} to="/app/sales" />
        <StatCard label={t('dashboard.totalPurchases')} value={money(cur.purchases_total)} icon={<ShoppingBag className="h-5 w-5" />} tone="red" delta={pctChange(Number(cur.purchases_total), Number(prev.purchases_total))} inverse to={has('purchases') ? '/app/purchases' : undefined} />
        <StatCard label={t('dashboard.grossProfit')} value={money(cur.gross_profit)} icon={<Coins className="h-5 w-5" />} tone="amber" delta={pctChange(Number(cur.gross_profit), Number(prev.gross_profit))} />
        <StatCard label={t('dashboard.productsSold')} value={formatNumber(cur.units_sold, lang)} icon={<Box className="h-5 w-5" />} tone="blue" delta={pctChange(Number(cur.units_sold), Number(prev.units_sold))} />
        <StatCard label={t('dashboard.inventoryValue')} value={money(s.inventory_value)} icon={<Package className="h-5 w-5" />} tone="purple"
          delta={pctChange(Number(s.inventory_value), Number(s.inventory_value_at_start))} deltaSuffix={t('dashboard.vsPeriodStart')} to="/app/inventory" />
      </div>

      <div className="mt-4 grid gap-4 xl:grid-cols-12">
        <Card className="xl:col-span-5">
          <CardHeader title={t('dashboard.salesOverview')} subtitle={t('dashboard.salesOverviewSub')}
            action={<Select value={grainSel} onChange={(e) => setGrainSel(e.target.value as any)} className="!h-8 w-28 text-xs">
              <option value="auto">{t(`grain.${grainFor(period.from, period.to)}`)}</option>
              <option value="day">{t('grain.day')}</option><option value="week">{t('grain.week')}</option><option value="month">{t('grain.month')}</option>
            </Select>} />
          {series.data && series.data.some((d) => Number(d.net_sales) !== 0)
            ? <SalesProfitChart data={series.data.map((d) => ({ ...d, net_sales: Number(d.net_sales), gross_profit: Number(d.gross_profit) }))} grain={grain} />
            : <EmptyState icon={<ShoppingCart className="h-6 w-6" />} title={t('dashboard.noSalesPeriod')} body={t('dashboard.noSalesPeriodBody')} action={<LinkButton to="/app/sales/new" size="sm">{t('nav.newSale')}</LinkButton>} />}
        </Card>

        <Card className="xl:col-span-4">
          <CardHeader title={t('dashboard.topSelling')} action={has('basic_analytics') && <Link to="/app/reports?tab=products" className="text-sm font-semibold text-brand-700 dark:text-brand-400">{t('common.viewAll')}</Link>} />
          {(top.data ?? []).length === 0 ? <p className="py-10 text-center text-sm text-ink-muted">{t('dashboard.noTopProducts')}</p> : (
            <table className="w-full text-sm">
              <thead><tr className="text-left text-xs text-ink-muted"><th className="pb-2 font-semibold">#</th><th className="pb-2 font-semibold">{t('dashboard.product')}</th><th className="pb-2 text-right font-semibold">{t('dashboard.unitsSold')}</th><th className="pb-2 text-right font-semibold">{t('dashboard.revenue')}</th></tr></thead>
              <tbody>
                {(top.data ?? []).map((p, i) => (
                  <tr key={p.id} className="border-t border-gray-100 dark:border-gray-800">
                    <td className="py-2.5 text-ink-muted">{i + 1}</td>
                    <td className="max-w-[140px] truncate py-2.5 font-medium"><Link to={`/app/products/${p.id}`} className="hover:underline">{p.name}</Link></td>
                    <td className="py-2.5 text-right tabular-nums">{formatNumber(p.units, lang)}</td>
                    <td className="py-2.5 text-right tabular-nums">{money(p.revenue)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          )}
        </Card>

        <div className="space-y-4 xl:col-span-3">
          <Card className="bg-gradient-to-br from-brand-50 to-white dark:from-brand-950/50 dark:to-gray-900">
            <div className="flex items-start gap-3">
              <span className="flex h-12 w-12 shrink-0 items-center justify-center rounded-2xl bg-brand-700 text-white"><Bot className="h-7 w-7" /></span>
              <div><p className="font-extrabold">{t('advisor.cardTitle')}</p><p className="mt-1 text-xs text-ink-muted dark:text-gray-400">{t('advisor.cardBody')}</p></div>
            </div>
            <LinkButton to="/app/advisor" block className="mt-4" icon={<MessageSquareText className="h-4 w-4" />}>{t('advisor.askQuestion')}</LinkButton>
          </Card>
          <QuickActionsCard />
        </div>
      </div>

      <div className="mt-4 grid gap-4 lg:grid-cols-2 xl:grid-cols-12">
        <Card className="xl:col-span-3">
          <CardHeader title={t('dashboard.stockAlerts')} action={<Link to="/app/inventory" className="text-sm font-semibold text-brand-700 dark:text-brand-400">{t('common.viewAll')}</Link>} />
          <ul className="space-y-1">
            <AlertRow to="/app/inventory?filter=low" icon={<AlertTriangle className="h-4 w-4" />} tone="red" label={t('dashboard.lowStock')} count={s.low_stock} />
            <AlertRow to="/app/inventory?filter=out" icon={<PackageX className="h-4 w-4" />} tone="red" label={t('dashboard.outOfStock')} count={s.out_of_stock} />
            <AlertRow to={has('advanced_analytics') ? '/app/reports?tab=slow' : '/app/inventory'} icon={<Hourglass className="h-4 w-4" />} tone="amber" label={t('dashboard.slowMoving')} count={s.slow_moving} />
            <AlertRow to="/app/inventory?tab=expiry" icon={<AlertTriangle className="h-4 w-4" />} tone="blue" label={t('dashboard.expiringSoon')} count={s.expiring_soon} />
          </ul>
        </Card>

        <Card className="xl:col-span-5">
          <CardHeader title={t('dashboard.categoryPerformance')} subtitle={t('dashboard.byNetSales')} />
          {!has('basic_analytics') ? <p className="py-8 text-center text-sm text-ink-muted">{t('dashboard.upgradeForCategories')}</p>
            : donut.length === 0 ? <p className="py-8 text-center text-sm text-ink-muted">{t('common.noData')}</p> : (
            <div className="grid items-center gap-4 sm:grid-cols-2">
              <DonutChart data={donut} centerValue={`${formatCompact(totalCat, lang)} ${biz.currency === 'XAF' ? 'FCFA' : biz.currency}`} centerLabel={t('dashboard.totalSales')} />
              <ul className="space-y-2 text-sm">
                {donut.map((d, i) => (
                  <li key={d.name} className="flex items-center gap-2">
                    <span className="h-2.5 w-2.5 shrink-0 rounded-full" style={{ background: CHART_COLORS[i % CHART_COLORS.length] }} />
                    <span className="flex-1 truncate">{d.name}</span><span className="font-semibold tabular-nums">{formatPct((d.value / totalCat) * 100, lang, 0)}</span>
                  </li>
                ))}
              </ul>
            </div>
          )}
        </Card>

        <RecentActivity className="lg:col-span-2 xl:col-span-4" />
      </div>

      <div className="mt-4 grid gap-4 xl:grid-cols-12">
        <Card className="xl:col-span-6">
          <CardHeader title={t('dashboard.inventoryTrend')} subtitle={t('dashboard.inventoryTrendSub')} />
          {inv.data && inv.data.length > 1 ? <ValueTrendChart data={inv.data.map((d) => ({ day: d.day, value: Number(d.value) }))} />
            : <p className="py-10 text-center text-sm text-ink-muted">{t('common.noData')}</p>}
        </Card>
        <Card className="xl:col-span-6">
          <CardHeader title={t('dashboard.profitBreakdown')} subtitle={t('dashboard.profitBreakdownSub')} />
          <ProfitBreakdown p={cur} />
        </Card>
      </div>

      {has('basic_analytics') && (
        <Card className="mt-4">
          <CardHeader title={<span className="flex items-center gap-2"><Sparkles className="h-5 w-5 text-brand-600" />{t('dashboard.attention')}</span>}
            subtitle={t('dashboard.attentionSub')} action={<Link to="/app/advisor" className="text-sm font-semibold text-brand-700 dark:text-brand-400">{t('advisor.askQuestion')}</Link>} />
          {insights.isLoading ? <PageLoader /> : (insights.data ?? []).length === 0 ? <p className="py-6 text-center text-sm text-ink-muted">{t('dashboard.nothingUrgent')}</p> : (
            <div className="grid gap-3 lg:grid-cols-2">
              {(insights.data ?? []).slice(0, 6).map((i, idx) => <InsightCard key={idx} insight={i} compact />)}
            </div>
          )}
        </Card>
      )}

      {(Number(dq.estimated_cost_entries) > 0 || Number(dq.zero_cost_products_sold) > 0) && (
        <p className="mt-4 text-xs text-ink-muted dark:text-gray-400">{t('dashboard.dataQualityNote')}</p>
      )}
    </div>
  );
}

function AlertRow({ to, icon, tone, label, count }: { to: string; icon: React.ReactNode; tone: 'red' | 'amber' | 'blue'; label: string; count: number }) {
  const { t } = useI18n();
  const c = { red: 'bg-red-600', amber: 'bg-amber-500', blue: 'bg-blue-600' }[tone];
  return (
    <li>
      <Link to={to} className="flex items-center gap-3 rounded-xl px-2 py-2.5 hover:bg-gray-50 dark:hover:bg-gray-800">
        <span className={clsx('flex h-8 w-8 items-center justify-center rounded-full text-white', c)}>{icon}</span>
        <span className="flex-1 text-sm font-medium">{label}</span>
        <span className={clsx('text-sm font-semibold', Number(count) > 0 ? 'text-red-600' : 'text-ink-muted')}>{t('dashboard.nProducts', { n: count })}</span>
      </Link>
    </li>
  );
}

function ProfitBreakdown({ p }: { p: any }) {
  const { t, lang } = useI18n();
  const money = useMoney();
  const net = Number(p.net_sales);
  if (net <= 0) return <p className="py-10 text-center text-sm text-ink-muted">{t('dashboard.noSalesPeriod')}</p>;
  const rows = [
    { label: t('dashboard.netSales'), v: net, color: '#156834' },
    { label: t('dashboard.cogs'), v: Number(p.cogs), color: '#f59e0b' },
    { label: t('dashboard.operatingExpenses'), v: Number(p.operating_expenses), color: '#ef4444' },
    ...(Number(p.stock_losses) !== 0 ? [{ label: t('dashboard.stockLosses'), v: Number(p.stock_losses), color: '#9ca3af' }] : []),
    { label: t('dashboard.operatingProfit'), v: Number(p.operating_profit), color: '#0f3f24' },
  ];
  return (
    <div className="space-y-3.5">
      {rows.map((r) => <HBar key={r.label} label={r.label} value={Math.abs(r.v)} max={net} color={r.v < 0 ? '#dc2626' : r.color}
        right={`${money(r.v)} · ${formatPct((r.v / net) * 100, lang, 0)}`} />)}
      <p className="pt-1 text-xs text-ink-muted dark:text-gray-400">{t('dashboard.operatingProfitNote')}</p>
    </div>
  );
}

function QuickActionsCard() {
  const { t } = useI18n();
  const actions = useQuickActions().slice(0, 5);
  return (
    <Card>
      <CardHeader title={t('nav.quickActions')} className="!mb-2" />
      <ul>
        {actions.map((a) => (
          <li key={a.key}>
            <Link to={a.to} className="flex items-center gap-3 rounded-xl px-1 py-2 hover:bg-gray-50 dark:hover:bg-gray-800">
              <span className={clsx('flex h-9 w-9 items-center justify-center rounded-lg', a.tone)}><a.icon className="h-5 w-5" /></span>
              <span className="flex-1 text-sm font-medium">{t(a.key === 'stocktake' ? 'inventory.newCount' : `nav.${a.key}`)}</span>
              <ChevronRight className="h-4 w-4 text-gray-400" />
            </Link>
          </li>
        ))}
      </ul>
    </Card>
  );
}

function RecentActivity({ className }: { className?: string }) {
  const { t, lang } = useI18n();
  const { id, can, has } = useBiz();
  const money = useMoney();
  const { data, isLoading } = useQuery({
    queryKey: ['recent_activity', id],
    queryFn: async () => {
      const [sales, purchases, expenses, products, customers] = await Promise.all([
        supabase.from('sales').select('id,number,total,created_at').eq('business_id', id).order('created_at', { ascending: false }).limit(5),
        can('purchases.manage') && has('purchases') ? supabase.from('purchases').select('id,number,total,created_at,status').eq('business_id', id).neq('status', 'draft').order('created_at', { ascending: false }).limit(3) : Promise.resolve({ data: [], error: null }),
        can('expenses.manage') && has('expenses') ? supabase.from('expenses').select('id,number,amount,description,created_at').eq('business_id', id).neq('status', 'voided').order('created_at', { ascending: false }).limit(3) : Promise.resolve({ data: [], error: null }),
        supabase.from('products').select('id,name,updated_at').eq('business_id', id).order('updated_at', { ascending: false }).limit(2),
        can('customers.manage') ? supabase.from('customers').select('id,name,created_at').eq('business_id', id).order('created_at', { ascending: false }).limit(2) : Promise.resolve({ data: [], error: null }),
      ]);
      const rows = [
        ...(unwrap(sales) as any[]).map((r) => ({ key: 's' + r.id, at: r.created_at, icon: ShoppingCart, tone: 'text-brand-700 bg-brand-50', title: t('dashboard.actSale', { n: r.number }), right: '+ ' + money(r.total), rightTone: 'text-brand-700', to: `/app/sales/${r.id}` })),
        ...((purchases as any).data ?? []).map((r: any) => ({ key: 'p' + r.id, at: r.created_at, icon: ShoppingBag, tone: 'text-red-600 bg-red-50', title: t('dashboard.actPurchase', { n: r.number }), right: '- ' + money(r.total), rightTone: 'text-red-600', to: `/app/purchases/${r.id}` })),
        ...((expenses as any).data ?? []).map((r: any) => ({ key: 'e' + r.id, at: r.created_at, icon: Receipt, tone: 'text-amber-600 bg-amber-50', title: t('dashboard.actExpense'), sub: r.description, right: '- ' + money(r.amount), rightTone: 'text-red-600', to: '/app/expenses' })),
        ...(unwrap(products) as any[]).map((r) => ({ key: 'pr' + r.id, at: r.updated_at, icon: Package, tone: 'text-blue-600 bg-blue-50', title: t('dashboard.actProduct'), right: r.name, rightTone: 'text-ink-soft', to: `/app/products/${r.id}` })),
        ...((customers as any).data ?? []).map((r: any) => ({ key: 'c' + r.id, at: r.created_at, icon: UserPlus, tone: 'text-violet-600 bg-violet-50', title: t('dashboard.actCustomer'), right: r.name, rightTone: 'text-ink-soft', to: `/app/customers/${r.id}` })),
      ];
      return rows.sort((a, b) => b.at.localeCompare(a.at)).slice(0, 6);
    },
  });
  return (
    <Card className={className}>
      <CardHeader title={t('dashboard.recentActivity')} action={can('sales.view') && <Link to="/app/sales" className="text-sm font-semibold text-brand-700 dark:text-brand-400">{t('common.viewAll')}</Link>} />
      {isLoading ? <PageLoader /> : (data ?? []).length === 0 ? <p className="py-8 text-center text-sm text-ink-muted">{t('common.noData')}</p> : (
        <ul className="space-y-1">
          {(data ?? []).map((r: any) => (
            <li key={r.key}>
              <Link to={r.to} className="flex items-center gap-3 rounded-xl px-1 py-2 hover:bg-gray-50 dark:hover:bg-gray-800">
                <span className={clsx('flex h-9 w-9 shrink-0 items-center justify-center rounded-full', r.tone)}><r.icon className="h-4 w-4" /></span>
                <span className="min-w-0 flex-1"><span className="block truncate text-sm font-medium">{r.title}</span><span className="block truncate text-xs text-ink-muted">{r.sub ?? formatRelative(r.at, lang)}</span></span>
                <span className={clsx('max-w-[40%] truncate text-sm font-semibold tabular-nums', r.rightTone)}>{r.right}</span>
              </Link>
            </li>
          ))}
        </ul>
      )}
    </Card>
  );
}

function CounterDashboard() {
  const { t } = useI18n();
  const { id } = useBiz();
  const money = useMoney();
  const { data, isLoading, error, refetch } = useRpc<any>('counter_summary', { p_business: id });
  const actions = useQuickActions();
  const items = useMemo(() => actions, [actions]);
  if (isLoading) return <PageLoader />;
  if (error) return <ErrorState error={error} onRetry={() => refetch()} />;
  return (
    <div>
      <Greeting />
      <div className="grid grid-cols-2 gap-3 sm:gap-4 lg:grid-cols-4">
        <StatCard label={t('dashboard.mySalesToday')} value={data.my_sales_today} icon={<ShoppingCart className="h-5 w-5" />} />
        <StatCard label={t('dashboard.myTotalToday')} value={money(data.my_total_today)} icon={<Coins className="h-5 w-5" />} tone="amber" />
        <StatCard label={t('dashboard.lowStock')} value={data.low_stock} icon={<AlertTriangle className="h-5 w-5" />} tone="red" to="/app/inventory?filter=low" />
        <StatCard label={t('dashboard.outOfStock')} value={data.out_of_stock} icon={<PackageX className="h-5 w-5" />} tone="red" to="/app/inventory?filter=out" />
      </div>
      <Card className="mt-4">
        <CardHeader title={t('nav.quickActions')} />
        <div className="grid grid-cols-2 gap-3 sm:grid-cols-4">
          {items.map((a) => (
            <Link key={a.key} to={a.to} className="flex flex-col items-center gap-2 rounded-2xl border border-gray-100 p-4 text-center text-sm font-semibold hover:bg-gray-50 dark:border-gray-800 dark:hover:bg-gray-800">
              <span className={clsx('flex h-12 w-12 items-center justify-center rounded-2xl', a.tone)}><a.icon className="h-6 w-6" /></span>
              {t(a.key === 'stocktake' ? 'inventory.newCount' : `nav.${a.key}`)}
            </Link>
          ))}
        </div>
      </Card>
      <div className="mt-6 flex justify-center"><LinkButton to="/app/sales/new" size="lg" icon={<ArrowRight className="h-5 w-5" />}>{t('nav.newSale')}</LinkButton></div>
    </div>
  );
}
