import { useState } from 'react';
import { useNavigate, useSearchParams } from 'react-router-dom';
import { useQuery } from '@tanstack/react-query';
import { CloudOff, Download, Plus, RefreshCw, ShoppingCart, Trash2 } from 'lucide-react';
import { useI18n } from '../../../i18n';
import { useBiz } from '../../../lib/business';
import { supabase } from '../../../lib/supabase';
import { unwrap } from '../../../lib/api';
import { addDays, localToday } from '../../../lib/dates';
import { formatDateTime, formatMoney } from '../../../lib/format';
import { downloadCsv } from '../../../lib/csv';
import { errorMessage } from '../../../lib/errors';
import { discardQueued, retryQueued, syncQueue, useOfflineQueue } from '../../../lib/offline';
import { Alert, Badge, Button, Card, CardHeader, ConfirmDialog, DataTable, EmptyState, ErrorState, Field, Input, LinkButton, PageHeader, PageLoader, Pagination, Select, useMoney } from '../../../components/ui';

const CHANNEL_KEYS = ['in_person', 'whatsapp', 'facebook', 'instagram', 'tiktok', 'phone', 'marketplace', 'other'];

const PAGE = 25;

export function saleStatus(s: any) {
  if (s.cancelled_at) return { key: 'cancelled', tone: 'gray' as const, owed: 0 };
  const charge = Number(s.total) - Number(s.returned_total) + Number(s.refunded_total);
  const owed = charge - Number(s.paid_total);
  if (Number(s.returned_total) >= Number(s.total) && Number(s.total) > 0) return { key: 'returned', tone: 'gray' as const, owed: 0 };
  if (owed <= 0) return { key: Number(s.returned_total) > 0 ? 'partially_returned' : 'paid', tone: 'green' as const, owed: 0 };
  if (Number(s.paid_total) > 0) return { key: 'partial', tone: 'amber' as const, owed };
  return { key: 'credit', tone: 'red' as const, owed };
}

export default function SalesPage() {
  const { t, lang } = useI18n();
  const { id, biz, can } = useBiz();
  const money = useMoney();
  const nav = useNavigate();
  const [params] = useSearchParams();
  const [from, setFrom] = useState(addDays(localToday(biz.timezone), -6));
  const [to, setTo] = useState(localToday(biz.timezone));
  const [q, setQ] = useState('');
  const [channel, setChannel] = useState(params.get('channel') ?? '');
  const [page, setPage] = useState(0);
  const build = () => {
    let query = supabase.from('sales').select('*, customers(name)', { count: 'exact' }).eq('business_id', id)
      .gte('sold_at', `${from}T00:00:00+01:00`).lt('sold_at', `${addDays(to, 1)}T00:00:00+01:00`).order('sold_at', { ascending: false });
    if (q.trim()) query = query.ilike('number', `%${q.trim()}%`);
    if (channel) query = query.eq('channel', channel);
    return query;
  };
  const { data, isLoading, error, refetch } = useQuery({
    queryKey: ['sales', id, from, to, q, channel, page],
    queryFn: async () => { const r = await build().range(page * PAGE, page * PAGE + PAGE - 1); return { rows: unwrap(r) as any[], count: r.count ?? 0 }; },
  });
  const totals = useQuery({
    queryKey: ['sales-totals', id, from, to, q, channel],
    queryFn: async () => {
      const rows = unwrap(await build().select('*').limit(10000)) as any[];
      return rows.reduce((a, r) => ({ n: a.n + 1, total: a.total + Number(r.total) - Number(r.returned_total), owed: a.owed + saleStatus(r).owed }), { n: 0, total: 0, owed: 0 });
    },
  });
  const exportCsv = async () => {
    const rows = unwrap(await build().limit(10000)) as any[];
    downloadCsv(`bizpilot-sales-${from}-to-${to}.csv`, rows.map((s) => ({ number: s.number, date: s.sold_at, channel: s.channel ?? '', status: saleStatus(s).key, customer: s.customers?.name ?? '', subtotal: s.subtotal,
      discounts: Number(s.line_discount_total) + Number(s.sale_discount), total: s.total, tax: s.tax_total, cost: Math.round(Number(s.cost_total)),
      returned: s.returned_total, paid: s.paid_total, outstanding: saleStatus(s).owed, offline: s.offline })));
  };
  return (
    <div>
      <PageHeader title={t('nav.sales')} subtitle={t('sales.subtitle')} actions={<>
        <Button variant="outline" icon={<Download className="h-4 w-4" />} onClick={exportCsv}>{t('common.exportCsv')}</Button>
        {can('sales.create') && <LinkButton to="/app/sales/new" icon={<Plus className="h-4 w-4" />}>{t('nav.newSale')}</LinkButton>}</>} />
      <OfflineQueuePanel forceOpen={params.get('offline') === '1'} />
      <Card>
        <div className="mb-4 grid gap-3 sm:grid-cols-2 lg:grid-cols-5">
          <Field label={t('common.from')}><Input type="date" value={from} max={to} onChange={(e) => { setFrom(e.target.value); setPage(0); }} /></Field>
          <Field label={t('common.to')}><Input type="date" value={to} min={from} onChange={(e) => { setTo(e.target.value); setPage(0); }} /></Field>
          <Field label={t('common.search')}><Input placeholder="S-00012" value={q} onChange={(e) => { setQ(e.target.value); setPage(0); }} /></Field>
          <Field label={t('sales.channel')}><Select value={channel} onChange={(e) => { setChannel(e.target.value); setPage(0); }}><option value="">{t('common.all')}</option>{CHANNEL_KEYS.map((c) => <option key={c} value={c}>{t(`channels.${c}`)}</option>)}</Select></Field>
          <div className="flex items-end gap-4 text-sm">
            {totals.data && <><span>{t('sales.count', { n: totals.data.n })}</span><span>{t('common.total')}: <b>{money(totals.data.total)}</b></span></>}
          </div>
        </div>
        {isLoading ? <PageLoader /> : error ? <ErrorState error={error} onRetry={() => refetch()} /> : (
          <>
            <DataTable rows={data!.rows} rowKey={(r) => r.id} onRowClick={(r) => nav(`/app/sales/${r.id}`)}
              empty={<EmptyState icon={<ShoppingCart className="h-6 w-6" />} title={t('sales.emptyTitle')} body={t('sales.emptyBody')} action={can('sales.create') && <LinkButton to="/app/sales/new" size="sm">{t('nav.newSale')}</LinkButton>} />}
              columns={[
                { key: 'n', header: t('sales.number'), render: (s) => <span className="font-semibold">{s.number}{s.offline && <Badge tone="gray" className="ml-1">{t('offline.badge')}</Badge>}</span> },
                { key: 'd', header: t('common.date'), render: (s) => formatDateTime(s.sold_at, lang) },
                { key: 'ch', header: t('sales.channel'), hideOnMobile: true, render: (s) => s.channel ? <span className="text-sm">{t(`channels.${s.channel}`)}</span> : '' },
                { key: 'c', header: t('pos.customer'), hideOnMobile: true, render: (s) => s.customers?.name ?? <span className="text-ink-muted">{t('common.walkIn')}</span> },
                { key: 't', header: t('common.total'), align: 'right', render: (s) => money(s.total) },
                { key: 's', header: t('common.status'), align: 'center', render: (s) => { const st = saleStatus(s); return <Badge tone={st.tone}>{t(`sales.status.${st.key}`)}</Badge>; } },
                { key: 'o', header: t('sales.outstanding'), align: 'right', hideOnMobile: true, render: (s) => { const st = saleStatus(s); return st.owed > 0 ? <span className="text-amber-700">{money(st.owed)}</span> : ''; } },
              ]} />
            <Pagination page={page} pageSize={PAGE} total={data!.count} onPage={setPage} />
          </>
        )}
      </Card>
    </div>
  );
}

function OfflineQueuePanel({ forceOpen }: { forceOpen: boolean }) {
  const { t, lang, has } = useI18n();
  const { id } = useBiz();
  const { items, online } = useOfflineQueue(id);
  const [discard, setDiscard] = useState<string | null>(null);
  const [syncing, setSyncing] = useState(false);
  if (!items.length && !forceOpen) return null;
  return (
    <Card className="mb-4 border-amber-200 dark:border-amber-900">
      <CardHeader title={<span className="flex items-center gap-2"><CloudOff className="h-5 w-5 text-amber-600" />{t('offline.queueTitle')}</span>} subtitle={t('offline.queueSub')}
        action={<Button size="sm" variant="outline" icon={<RefreshCw className="h-4 w-4" />} loading={syncing} disabled={!online} onClick={async () => { setSyncing(true); await syncQueue(); setSyncing(false); }}>{t('offline.syncNow')}</Button>} />
      {items.length === 0 ? <p className="text-sm text-ink-muted">{t('offline.queueEmpty')}</p> : (
        <ul className="divide-y divide-gray-100 dark:divide-gray-800">
          {items.map((i) => (
            <li key={i.client_ref} className="flex flex-col gap-2 py-3 sm:flex-row sm:items-center">
              <div className="flex-1 text-sm">
                <p className="font-semibold">{formatDateTime(i.created_at, lang)} · {formatMoney(i.summary.total, lang)} · {t('offline.items', { n: i.summary.items })}</p>
                {i.status === 'pending' ? <Badge tone="amber">{t('offline.waiting')}</Badge> : (
                  <div className="mt-1"><Alert tone="red" title={t('offline.needsAttention')}>{errorMessage(i.error, t, has)}</Alert></div>
                )}
              </div>
              <div className="flex gap-2">
                {i.status === 'failed' && <Button size="sm" variant="outline" onClick={() => retryQueued(i.client_ref)}>{t('common.retry')}</Button>}
                <Button size="sm" variant="ghost" className="text-red-600" icon={<Trash2 className="h-4 w-4" />} onClick={() => setDiscard(i.client_ref)}>{t('offline.discard')}</Button>
              </div>
            </li>
          ))}
        </ul>
      )}
      <ConfirmDialog open={Boolean(discard)} onClose={() => setDiscard(null)} danger title={t('offline.discardTitle')} body={t('offline.discardBody')}
        onConfirm={() => { discardQueued(discard!); setDiscard(null); }} />
    </Card>
  );
}
