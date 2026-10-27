// Premium automations: turn each one on or off, pick how often it runs, run it now, and retry a failed run.
// Automations only notify the seller or save drafts; they never change stock, prices, sales or money.
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { Play, RotateCcw } from 'lucide-react';
import { useI18n } from '../../../i18n';
import { useBiz } from '../../../lib/business';
import { rpc } from '../../../lib/api';
import { useAction } from '../../../lib/useAction';
import { formatDateTime } from '../../../lib/format';
import { Badge, Button, Card, CardHeader, Checkbox, EmptyState, PageHeader, PageLoader, Select, UpgradeNotice } from '../../../components/ui';

const KINDS = ['low_stock_alert', 'weekly_summary', 'restock_list', 'listing_gaps', 'pending_order_reminder', 'customer_followup', 'marketing_draft'] as const;

export default function AutomationsPage() {
  const { t, lang } = useI18n();
  const { id, has, can } = useBiz();
  const { run, busy } = useAction();
  const qc = useQueryClient();
  const enabledFeature = has('premium_automations');
  const list = useQuery({ queryKey: ['automations', id], enabled: enabledFeature && can('reports.view'), queryFn: () => rpc<any[]>('automation_list', { p_business: id }) });
  const history = useQuery({ queryKey: ['automation-history', id], enabled: enabledFeature && can('reports.view'), queryFn: () => rpc<any[]>('automation_history', { p_business: id }) });
  if (!can('reports.view')) return <EmptyState title={t('automations.noAccess')} />;
  if (!enabledFeature) return <div><PageHeader title={t('automations.title')} subtitle={t('automations.subtitle')} /><UpgradeNotice feature="premium_automations" /></div>;
  if (list.isLoading) return <PageLoader />;
  const refresh = () => { qc.invalidateQueries({ queryKey: ['automations', id] }); qc.invalidateQueries({ queryKey: ['automation-history', id] }); };
  const setAuto = async (kind: string, enabled: boolean, frequency: string) => {
    const r = await run(() => rpc('automation_set', { p_business: id, p_kind: kind, p_enabled: enabled, p_frequency: frequency }), t('common.saved'));
    if (r !== undefined) refresh();
  };
  const runNow = async (kind: string) => {
    const r = await run(() => rpc<any>('automation_run', { p_business: id, p_kind: kind }), t('automations.ran'));
    if (r !== undefined) refresh();
  };
  const retry = async (runId: string) => {
    const r = await run(() => rpc<any>('automation_retry', { p_run: runId }), t('automations.retried'));
    if (r !== undefined) refresh();
  };
  const rows = list.data ?? [];
  return (
    <div>
      <PageHeader title={t('automations.title')} subtitle={t('automations.subtitle')} />
      <Card>
        <CardHeader title={t('automations.listTitle')} subtitle={t('automations.listSub')} />
        <ul className="divide-y divide-gray-100 dark:divide-gray-800">
          {KINDS.map((k) => {
            const a = rows.find((x) => x.kind === k) ?? { enabled: false, frequency: 'daily' };
            return (
              <li key={k} className="flex flex-col gap-3 py-4 sm:flex-row sm:items-center sm:justify-between">
                <div className="min-w-0 flex-1">
                  <p className="font-semibold">{t(`automations.kinds.${k}.title`)}</p>
                  <p className="text-sm text-ink-muted">{t(`automations.kinds.${k}.body`)}</p>
                  <p className="mt-1 text-xs text-ink-muted">
                    {a.last_run_at ? t('automations.lastRun', { date: formatDateTime(a.last_run_at, lang) }) : t('automations.neverRun')}
                    {a.last_status && <> · <Badge tone={a.last_status === 'succeeded' ? 'green' : a.last_status === 'failed' ? 'red' : 'gray'}>{t(`automations.status.${a.last_status}`)}</Badge></>}
                  </p>
                </div>
                <div className="flex flex-wrap items-center gap-3">
                  <Checkbox label={t('automations.on')} checked={Boolean(a.enabled)} onChange={(v) => setAuto(k, v, a.frequency)} disabled={!can('settings.manage') || busy} />
                  <Select aria-label={t('automations.frequency')} value={a.frequency} disabled={!can('settings.manage') || busy}
                    onChange={(e) => setAuto(k, Boolean(a.enabled), e.target.value)}>
                    <option value="daily">{t('automations.daily')}</option>
                    <option value="weekly">{t('automations.weekly')}</option>
                  </Select>
                  <Button size="sm" variant="outline" icon={<Play className="h-4 w-4" />} disabled={!a.enabled || !can('settings.manage')} loading={busy} onClick={() => runNow(k)}>
                    {t('automations.runNow')}
                  </Button>
                </div>
              </li>
            );
          })}
        </ul>
      </Card>

      <Card className="mt-4">
        <CardHeader title={t('automations.historyTitle')} subtitle={t('automations.historySub')} />
        {(history.data ?? []).length === 0 ? <p className="text-sm text-ink-muted">{t('automations.noHistory')}</p> : (
          <ul className="divide-y divide-gray-100 text-sm dark:divide-gray-800">
            {(history.data ?? []).map((r: any) => (
              <li key={r.id} className="flex flex-wrap items-center justify-between gap-2 py-2">
                <div>
                  <span className="font-semibold">{t(`automations.kinds.${r.kind}.title`)}</span>
                  <span className="ml-2 text-xs text-ink-muted">{formatDateTime(r.started_at, lang)} · {t(`automations.trigger.${r.trigger}`)} · #{r.attempt}</span>
                  {r.error && <p className="text-xs text-red-700">{r.error}</p>}
                </div>
                <div className="flex items-center gap-2">
                  <Badge tone={r.status === 'succeeded' ? 'green' : r.status === 'failed' ? 'red' : 'gray'}>{t(`automations.status.${r.status}`)}</Badge>
                  {r.status === 'failed' && r.attempt < 3 && can('settings.manage') && (
                    <Button size="sm" variant="outline" icon={<RotateCcw className="h-4 w-4" />} loading={busy} onClick={() => retry(r.id)}>{t('automations.retry')}</Button>
                  )}
                </div>
              </li>
            ))}
          </ul>
        )}
      </Card>
      <p className="mt-4 text-sm text-ink-muted">{t('automations.reportsNote')}</p>
    </div>
  );
}
