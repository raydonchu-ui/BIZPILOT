// Mobile Money received through Fapshi: the Fapshi account balance (read on the server with the
// Fapshi keys, which never reach the browser) and every payment the server has confirmed with
// Fapshi, refreshed automatically. The money itself is collected into the Fapshi account.
import { useMemo, useState } from 'react';
import { useQuery } from '@tanstack/react-query';
import { ExternalLink, RefreshCw } from 'lucide-react';
import { useI18n } from '../../i18n';
import { supabase } from '../../lib/supabase';
import { unwrap, useRpc } from '../../lib/api';
import { fapshiBalance } from '../../lib/market';
import { errorMessage } from '../../lib/errors';
import { formatDateTime, formatMoney } from '../../lib/format';
import { Alert, Badge, Card, DataTable, EmptyState, PageHeader, PageLoader, Select, StatCard, Tone } from '../../components/ui';

const REFRESH_MS = 15_000;
const DAY = 86_400_000;
const statusTone: Record<string, Tone> = { successful: 'green', pending: 'amber', created: 'gray', failed: 'red', expired: 'gray', error: 'red' };

function useFapshiTotals() {
  return useQuery({
    queryKey: ['admin-fapshi-totals'], refetchInterval: REFRESH_MS,
    queryFn: async () => {
      const since = new Date(Date.now() - 30 * DAY).toISOString();
      const rows = unwrap(await supabase.from('online_payments').select('kind, status, amount, amount_received, verified_at, created_at')
        .gte('created_at', since).limit(10000)) as { kind: string; status: string; amount: number; amount_received: number | null; verified_at: string | null; created_at: string }[];
      const startToday = new Date(); startToday.setHours(0, 0, 0, 0);
      const sum = (from: number, kind?: string) => rows
        .filter((r) => r.status === 'successful' && r.verified_at && new Date(r.verified_at).getTime() >= from && (!kind || r.kind === kind))
        .reduce((s, r) => s + Number(r.amount_received ?? r.amount), 0);
      const count = (from: number) => rows.filter((r) => r.status === 'successful' && r.verified_at && new Date(r.verified_at).getTime() >= from).length;
      return {
        today: sum(startToday.getTime()), todayCount: count(startToday.getTime()),
        week: sum(Date.now() - 7 * DAY), month: sum(Date.now() - 30 * DAY),
        monthSubs: sum(Date.now() - 30 * DAY, 'subscription'), monthOrders: sum(Date.now() - 30 * DAY, 'order'),
        // Requests still open in the last 30 minutes: customers who have not approved on their phone yet.
        waiting: rows.filter((r) => ['created', 'pending'].includes(r.status) && Date.now() - new Date(r.created_at).getTime() < 30 * 60_000).length,
      };
    },
  });
}

/** Overview card: Mobile Money received today. */
export function FapshiTodayStat() {
  const { t, lang } = useI18n();
  const q = useFapshiTotals();
  return <StatCard label={t('fapshiAdmin.today')} value={q.data ? formatMoney(q.data.today, lang) : '…'} hint={q.data ? t('fapshiAdmin.payments', { n: q.data.todayCount }) : undefined} tone="green" to="/admin/fapshi" />;
}

/** Whether Fapshi pushes payment requests to the payer's phone (direct pay), from its last answer. */
function DirectPayStatus({ info }: { info: Awaited<ReturnType<typeof fapshiBalance>> }) {
  const { t, lang } = useI18n();
  const d = info.direct_pay;
  const mode = info.live ? t('fapshiAdmin.modeLive') : t('fapshiAdmin.modeSandbox');
  const last = d?.last_error && (!d.ok || !d.at || new Date(d.last_error.at) > new Date(d.at)) ? d.last_error : null;
  const lastError = last && (
    <div className="mt-4"><Alert tone="amber" title={t('fapshiAdmin.lastErrorTitle')}>
      {t('fapshiAdmin.lastError', { time: formatDateTime(last.at, lang), where: last.where, message: last.message })}</Alert></div>
  );
  if (!d || typeof d.ok !== 'boolean') return <>{lastError}<div className="mt-4"><Alert tone="blue" title={t('fapshiAdmin.directUnknownTitle', { mode })}>{t('fapshiAdmin.directUnknown')}</Alert></div></>;
  if (d.ok) return <>{lastError}<div className="mt-4"><Alert tone="green" title={t('fapshiAdmin.directOkTitle', { mode })}>{t('fapshiAdmin.directOk', { time: formatDateTime(d.at, lang) })}</Alert></div></>;
  return (
    <>{lastError}<div className="mt-4"><Alert tone="red" title={t('fapshiAdmin.directOffTitle', { mode })}>
      <p>{t('fapshiAdmin.directOff', { time: formatDateTime(d.at, lang), message: d.message ?? `HTTP ${d.http_status ?? ''}` })}</p>
      <p className="mt-2 font-semibold">{t('fapshiAdmin.directHowTitle')}</p>
      <ol className="mt-1 list-decimal space-y-0.5 pl-5">{t('fapshiAdmin.directHow').split('|').map((x) => <li key={x}>{x}</li>)}</ol>
    </Alert></div></>
  );
}

export function FapshiAdmin() {
  const { t, lang, has } = useI18n();
  const [filter, setFilter] = useState('successful');
  const totals = useFapshiTotals();
  const balance = useQuery({ queryKey: ['admin-fapshi-balance'], queryFn: fapshiBalance, refetchInterval: 60_000, retry: false });
  const list = useRpc<any[]>('admin_market_payments', { p_filter: 'all' }, { refetchInterval: REFRESH_MS });
  const rows = useMemo(() => (list.data ?? []).filter((p) => filter === 'all' || (filter === 'open' ? ['created', 'pending'].includes(p.status) : p.status === filter)), [list.data, filter]);
  const s = totals.data;
  return (
    <div>
      <PageHeader title={t('admin.nav.fapshi')} subtitle={t('fapshiAdmin.sub')}
        actions={<a href="https://dashboard.fapshi.com" target="_blank" rel="noreferrer" className="inline-flex items-center gap-1.5 rounded-xl border border-gray-300 px-3 py-2 text-sm font-semibold hover:bg-gray-50 dark:border-gray-700 dark:hover:bg-gray-800">
          <ExternalLink className="h-4 w-4" />{t('fapshiAdmin.openDashboard')}</a>} />
      <div className="grid grid-cols-2 gap-4 lg:grid-cols-4">
        <StatCard label={t('fapshiAdmin.balance')} tone="blue"
          value={balance.data ? formatMoney(balance.data.balance, lang, balance.data.currency || 'XAF') : balance.isLoading ? '…' : '—'}
          hint={balance.data ? t('fapshiAdmin.balanceHint') : balance.error ? t('fapshiAdmin.balanceUnavailable') : undefined} />
        <StatCard label={t('fapshiAdmin.today')} value={s ? formatMoney(s.today, lang) : '…'} hint={s ? t('fapshiAdmin.payments', { n: s.todayCount }) : undefined} />
        <StatCard label={t('fapshiAdmin.week')} value={s ? formatMoney(s.week, lang) : '…'} />
        <StatCard label={t('fapshiAdmin.month')} value={s ? formatMoney(s.month, lang) : '…'} tone="amber"
          hint={s ? t('fapshiAdmin.split', { subs: formatMoney(s.monthSubs, lang), orders: formatMoney(s.monthOrders, lang) }) : undefined} />
      </div>
      {balance.error && (
        <div className="mt-4"><Alert tone="red" title={t('fapshiAdmin.connectionTitle')}>
          <p>{errorMessage(balance.error, t, has)}</p>
          <p className="mt-2 font-semibold">{t('fapshiAdmin.checkTitle')}</p>
          <ol className="mt-1 list-decimal space-y-0.5 pl-5">{t('fapshiAdmin.checkSteps').split('|').map((x) => <li key={x}>{x}</li>)}</ol>
        </Alert></div>
      )}
      {balance.data && <DirectPayStatus info={balance.data} />}
      <Card className="mt-4">
        <div className="mb-3 flex flex-wrap items-center gap-3">
          <div className="w-56"><Select value={filter} onChange={(e) => setFilter(e.target.value)} aria-label={t('common.status')}>
            {['successful', 'open', 'failed', 'all'].map((k) => <option key={k} value={k}>{t(`fapshiAdmin.filter.${k}`)}</option>)}
          </Select></div>
          {s && s.waiting > 0 && <Badge tone="amber">{t('fapshiAdmin.waiting', { n: s.waiting })}</Badge>}
          <span className="ml-auto inline-flex items-center gap-1 text-xs text-ink-muted"><RefreshCw className="h-3.5 w-3.5" />{t('fapshiAdmin.auto')}</span>
        </div>
        {list.isLoading ? <PageLoader /> : (
          <DataTable rows={rows} rowKey={(r) => r.id} empty={<EmptyState title={t('fapshiAdmin.none')} />} columns={[
            { key: 'd', header: t('common.date'), hideOnMobile: true, render: (p) => formatDateTime(p.verified_at ?? p.created_at, lang) },
            { key: 'w', header: t('madmin.forWhat'), render: (p) => <div>
              <p className="font-semibold">{p.kind === 'order' ? t('fapshiAdmin.order', { n: p.order_number ?? '' }) : t('fapshiAdmin.subscription', { plan: p.plan_code ?? '', period: p.billing_period ? t(`site.pricing.${p.billing_period}`) : '' })}</p>
              <p className="text-xs text-ink-muted">{p.business_name}</p>
              <p className="text-xs text-ink-muted md:hidden">{formatDateTime(p.verified_at ?? p.created_at, lang)}</p></div> },
            { key: 'p', header: t('fapshiAdmin.payer'), hideOnMobile: true, render: (p) => <div><p>{p.payer_name ?? '—'}</p>
              {p.medium && <p className="text-xs text-ink-muted">{p.medium === 'orange money' ? 'Orange Money' : p.medium === 'mobile money' ? 'MTN MoMo' : p.medium}</p>}</div> },
            { key: 's', header: t('common.status'), render: (p) => <div className="flex flex-wrap gap-1"><Badge tone={statusTone[p.status] ?? 'gray'}>{t(`orders.onlineStatus.${p.status}`)}</Badge>
              {p.mismatch && <Badge tone="red">{t('madmin.mismatch')}</Badge>}{p.needs_refund && !p.refunded_at && <Badge tone="amber">{t('madmin.needsRefund')}</Badge>}</div> },
            { key: 'a', header: t('common.amount'), align: 'right', render: (p) => <span className="font-semibold">{formatMoney(p.amount_received ?? p.amount, lang)}</span> },
            { key: 't', header: 'Fapshi ID', hideOnMobile: true, render: (p) => <span className="font-mono text-xs">{p.trans_id ?? '—'}</span> },
          ]} />
        )}
        <p className="mt-3 text-xs text-ink-muted">{t('fapshiAdmin.note')}</p>
      </Card>
    </div>
  );
}
