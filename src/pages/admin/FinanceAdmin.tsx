// Financial control centre for administrators. Figures are read from the records behind them; "net" is not profit,
// and the page says which costs are not recorded in the database.
import { useState } from 'react';
import { useQuery } from '@tanstack/react-query';
import { useI18n } from '../../i18n';
import { rpc } from '../../lib/api';
import { formatDateTime } from '../../lib/format';
import { Alert, Badge, Card, CardHeader, DataTable, Field, Input, PageHeader, PageLoader, Select, StatCard } from '../../components/ui';

const iso = (d: Date) => d.toISOString().slice(0, 10);
const fcfa = (n: unknown) => `${Math.round(Number(n) || 0).toLocaleString('fr-FR').replace(/\s/g, ' ')} FCFA`;

export function FinanceAdmin() {
  const { t, lang } = useI18n();
  const today = new Date();
  const [from, setFrom] = useState(iso(new Date(today.getTime() - 29 * 86400000)));
  const [to, setTo] = useState(iso(today));
  const [status, setStatus] = useState('');
  const overview = useQuery({ queryKey: ['admin-finance', from, to], queryFn: () => rpc<any>('admin_finance_overview', { p_from: from, p_to: to }) });
  const drill = useQuery({ queryKey: ['admin-finance-payments', from, to, status], queryFn: () => rpc<any[]>('admin_finance_payments', { p_from: from, p_to: to, p_status: status || null }) });
  const health = useQuery({ queryKey: ['admin-health'], queryFn: () => rpc<any>('admin_platform_health') });
  const o = overview.data;
  const valid = from <= to;

  return (
    <div className="space-y-4">
      <PageHeader title={t('finance.title')} subtitle={t('finance.subtitle')} />
      <Card>
        <div className="grid gap-3 sm:grid-cols-[repeat(2,minmax(0,200px))_auto] sm:items-end">
          <Field label={t('finance.from')}><Input type="date" value={from} max={to} onChange={(e) => setFrom(e.target.value)} /></Field>
          <Field label={t('finance.to')}><Input type="date" value={to} min={from} onChange={(e) => setTo(e.target.value)} /></Field>
          <div className="flex gap-2">
            <button type="button" className="min-h-10 rounded-lg px-3 text-sm font-semibold ring-1 ring-gray-200 hover:bg-gray-50 dark:ring-gray-700" onClick={() => { setFrom(iso(today)); setTo(iso(today)); }}>{t('finance.today')}</button>
            <button type="button" className="min-h-10 rounded-lg px-3 text-sm font-semibold ring-1 ring-gray-200 hover:bg-gray-50 dark:ring-gray-700" onClick={() => { setFrom(iso(new Date(today.getTime() - 29 * 86400000))); setTo(iso(today)); }}>{t('finance.last30')}</button>
          </div>
        </div>
        {!valid && <p className="mt-2 text-sm text-red-700">{t('finance.badRange')}</p>}
      </Card>

      {overview.isLoading ? <PageLoader /> : overview.error || !o ? <Alert tone="red">{t('finance.loadError')}</Alert> : (
        <>
          <div className="grid grid-cols-2 gap-3 lg:grid-cols-4">
            <StatCard label={t('finance.gross')} value={fcfa(o.collections.gross)} hint={t('finance.grossHint', { n: o.collections.count })} />
            <StatCard label={t('finance.refunds')} value={fcfa(o.collections.refunded.amount)} hint={t('finance.refundsHint', { n: o.collections.refunded.count })} />
            <StatCard label={t('finance.commission')} value={fcfa(o.commissions.accrued - o.commissions.reversed)} hint={t('finance.commissionHint', { onHold: fcfa(o.commissions.on_hold) })} />
            <StatCard label={t('finance.net')} value={fcfa(o.net.after_refunds_and_commission)} hint={t('finance.netHint')} />
          </div>
          <Alert tone="amber">{t('finance.notProfit', { items: o.not_recorded.map((k: string) => t(`finance.notRecorded.${k}`)).join(', ') })}</Alert>

          <div className="grid gap-4 lg:grid-cols-2">
            <Card>
              <CardHeader title={t('finance.byPlan')} subtitle={t('finance.firstRenewals', { first: o.collections.first_payments, renewals: o.collections.renewals })} />
              {o.collections.by_plan.length === 0 ? <p className="text-sm text-ink-muted">{t('finance.none')}</p> : (
                <ul className="divide-y divide-gray-100 text-sm dark:divide-gray-800">
                  {o.collections.by_plan.map((p: any) => <li key={p.plan_code} className="flex justify-between py-2"><span>{p.plan_code} · {p.n}</span><b>{fcfa(p.amount)}</b></li>)}
                </ul>
              )}
              <dl className="mt-4 grid grid-cols-2 gap-2 text-sm">
                <div><dt className="text-ink-muted">{t('finance.rejected')}</dt><dd>{o.collections.rejected.count} · {fcfa(o.collections.rejected.amount)}</dd></div>
                <div><dt className="text-ink-muted">{t('finance.pending')}</dt><dd>{o.collections.pending.count} · {fcfa(o.collections.pending.amount)}</dd></div>
              </dl>
            </Card>
            <Card>
              <CardHeader title={t('finance.creators')} subtitle={t('finance.creatorsSub')} />
              <dl className="grid grid-cols-2 gap-3 text-sm">
                <div><dt className="text-ink-muted">{t('finance.accrued')}</dt><dd className="font-bold">{fcfa(o.commissions.accrued)}</dd></div>
                <div><dt className="text-ink-muted">{t('finance.reversed')}</dt><dd className="font-bold">{fcfa(o.commissions.reversed)}</dd></div>
                <div><dt className="text-ink-muted">{t('finance.onHold')}</dt><dd className="font-bold">{fcfa(o.commissions.on_hold)}</dd></div>
                <div><dt className="text-ink-muted">{t('finance.availableNow')}</dt><dd className="font-bold">{fcfa(o.commissions.available)}</dd></div>
                <div><dt className="text-ink-muted">{t('finance.paidOut')}</dt><dd className="font-bold">{fcfa(o.payouts.paid_in_period)}</dd></div>
                <div><dt className="text-ink-muted">{t('finance.openPayouts')}</dt><dd className="font-bold">{fcfa(o.payouts.open)}</dd></div>
              </dl>
              <div className="mt-4">
                <Alert tone={o.reconciliation.balanced ? 'green' : 'amber'} title={o.reconciliation.balanced ? t('finance.balanced') : t('finance.differences')}>
                  {t('finance.checkLine', { missing: o.reconciliation.verified_payments_without_accrual, reversals: o.reconciliation.reversals_without_refund, overpaid: o.reconciliation.creators_paid_above_available })}
                </Alert>
              </div>
            </Card>
            <Card>
              <CardHeader title={t('finance.ai')} />
              <p className="text-sm">{t('finance.aiLine', { answers: o.ai.answers, failed: o.ai.failed, tokens: o.ai.tokens })}</p>
              <p className="mt-3 text-sm">{t('finance.storageLine', { files: o.storage.files, mb: (Number(o.storage.bytes) / 1048576).toFixed(1) })}</p>
            </Card>
            <Card>
              <CardHeader title={t('finance.health')} />
              {health.isLoading ? <PageLoader /> : health.data && (
                <dl className="grid grid-cols-2 gap-2 text-sm">
                  {['open_support', 'open_reports', 'open_disputes', 'stale_pending_payments', 'verifications_waiting', 'failed_automation_runs_7d', 'failed_online_payments_7d', 'failed_payouts'].map((k) => (
                    <div key={k} className="flex justify-between gap-2 rounded-lg bg-gray-50 px-3 py-2 dark:bg-gray-800/60">
                      <dt className="text-ink-muted">{t(`finance.health_${k}`)}</dt><dd className="font-bold">{health.data[k]}</dd>
                    </div>
                  ))}
                </dl>
              )}
            </Card>
          </div>

          <Card>
            <CardHeader title={t('finance.payments')} action={
              <Select aria-label={t('finance.status')} value={status} onChange={(e) => setStatus(e.target.value)}>
                <option value="">{t('finance.all')}</option>
                {['pending', 'verified', 'rejected', 'cancelled', 'refunded'].map((s) => <option key={s} value={s}>{t(`billing.paymentStatus.${s}`)}</option>)}
              </Select>} />
            <DataTable rows={drill.data ?? []} rowKey={(r) => r.id} empty={<p className="py-6 text-center text-sm text-ink-muted">{t('finance.none')}</p>} columns={[
              { key: 'd', header: t('common.date'), render: (r) => formatDateTime(r.submitted_at, lang) },
              { key: 'b', header: t('finance.business'), render: (r) => r.business_name },
              { key: 'p', header: t('billing.plan'), render: (r) => r.plan_code },
              { key: 'a', header: t('common.amount'), align: 'right', render: (r) => fcfa(r.amount) },
              { key: 's', header: t('common.status'), render: (r) => <Badge tone={r.status === 'verified' ? 'green' : r.status === 'refunded' || r.status === 'rejected' ? 'red' : 'amber'}>{t(`billing.paymentStatus.${r.status}`)}</Badge> },
              { key: 'r', header: t('finance.reference'), hideOnMobile: true, render: (r) => <span className="font-mono text-xs">{r.transaction_ref}</span> },
            ]} />
          </Card>
        </>
      )}
    </div>
  );
}
