// Administrator queue for blue-tick applications: check the documents and the rules, then approve or reject with a reason.
// Only platform administrators can call these functions; the server checks it again.
import { useState } from 'react';
import { useQuery } from '@tanstack/react-query';
import clsx from 'clsx';
import { useI18n } from '../../i18n';
import { rpc } from '../../lib/api';
import { useAction } from '../../lib/useAction';
import { openFile } from '../../lib/hooks';
import { formatDate, formatDateTime } from '../../lib/format';
import { Badge, Button, Card, ConfirmDialog, EmptyState, PageHeader, PageLoader, Textarea, Field } from '../../components/ui';

const FILTERS = ['submitted', 'approved', 'rejected', 'all'] as const;

export function VerificationAdmin() {
  const { t, lang } = useI18n();
  const { run, busy } = useAction();
  const [filter, setFilter] = useState<(typeof FILTERS)[number]>('submitted');
  const [dialog, setDialog] = useState<{ mode: 'reject' | 'revoke'; item: any } | null>(null);
  const [reason, setReason] = useState('');
  const q = useQuery({
    queryKey: ['admin-verification', filter],
    queryFn: () => rpc<any[]>('admin_verification_applications', { p_status: filter === 'all' ? null : filter }),
  });
  const close = () => { setDialog(null); setReason(''); };
  const approve = async (item: any) => {
    const r = await run(() => rpc('admin_review_verification', { p_application: item.id, p_decision: 'approve', p_reason: null }), t('premium.admin.decided'));
    if (r !== undefined) q.refetch();
  };
  const confirmDialog = async () => {
    if (!dialog) return;
    const why = reason.trim();
    if (!why) return;
    const r = dialog.mode === 'reject'
      ? await run(() => rpc('admin_review_verification', { p_application: dialog.item.id, p_decision: 'reject', p_reason: why }), t('premium.admin.decided'))
      : await run(() => rpc('admin_revoke_verification', { p_business: dialog.item.business_id, p_reason: why }), t('premium.admin.revokeDone'));
    if (r !== undefined) { close(); q.refetch(); }
  };
  const open = (path: string) => run(() => openFile(path));
  if (q.isLoading) return <PageLoader />;
  const rows = q.data ?? [];
  return (
    <div>
      <PageHeader title={t('premium.admin.title')} subtitle={t('premium.admin.subtitle')} />
      <div className="mb-4 flex flex-wrap gap-2" role="group" aria-label={t('premium.admin.title')}>
        {FILTERS.map((f) => (
          <button key={f} type="button" aria-pressed={filter === f} onClick={() => setFilter(f)}
            className={clsx('min-h-9 rounded-full px-3 text-sm font-semibold ring-1 ring-inset', filter === f ? 'bg-brand-600 text-white ring-brand-600' : 'bg-white ring-gray-200 dark:bg-gray-900 dark:ring-gray-700')}>
            {t(`premium.admin.filter.${f}`)}
          </button>
        ))}
      </div>
      {rows.length === 0 ? <EmptyState title={t('premium.admin.none')} /> : (
        <div className="grid gap-4 lg:grid-cols-2">
          {rows.map((a: any) => (
            <Card key={a.id}>
              <div className="flex flex-wrap items-start justify-between gap-2">
                <div>
                  <p className="font-bold">{a.business_name}</p>
                  <p className="text-xs text-ink-muted">{a.slug ? `/s/${a.slug}` : ''} · {t('premium.admin.plan')}: {a.plan_code}</p>
                </div>
                <Badge tone={a.status === 'approved' ? 'green' : a.status === 'rejected' ? 'red' : 'amber'}>{a.status}</Badge>
              </div>
              <dl className="mt-3 grid grid-cols-2 gap-2 text-sm">
                <div><dt className="text-ink-muted">{t('premium.verify.legalName')}</dt><dd>{a.legal_name}</dd></div>
                <div><dt className="text-ink-muted">{t('premium.verify.idType')}</dt><dd>{t(`premium.verify.idTypes.${a.id_type}`)}{a.id_last4 ? ` · ···${a.id_last4}` : ''}</dd></div>
                <div><dt className="text-ink-muted">{t('premium.admin.submitted')}</dt><dd>{formatDateTime(a.submitted_at, lang)}</dd></div>
                {a.expires_at && <div><dt className="text-ink-muted">{t('premium.admin.expires')}</dt><dd>{formatDate(a.expires_at, lang)}</dd></div>}
              </dl>
              <ul className="mt-3 space-y-1 text-sm">
                <li className={a.eligibility.eligible ? 'text-brand-700' : 'text-red-700'}>
                  {a.eligibility.eligible ? t('premium.admin.eligible') : `${t('premium.admin.notEligible')}: ${(a.eligibility.reasons ?? []).map((r: string) => t(`premium.verify.reasons.${r}`)).join(' ')}`}
                </li>
              </ul>
              {a.decision_reason && <p className="mt-2 text-sm text-ink-muted">{a.decision_reason}</p>}
              <div className="mt-3 flex flex-wrap gap-2">
                <Button size="sm" variant="outline" onClick={() => open(a.id_document_path)}>{t('premium.admin.openDoc')}: {t(`premium.verify.idTypes.${a.id_type}`)}</Button>
                {a.business_document_path && <Button size="sm" variant="outline" onClick={() => open(a.business_document_path)}>{t('premium.admin.openDoc')}: {t('premium.verify.businessDocument')}</Button>}
              </div>
              <div className="mt-3 flex flex-wrap gap-2">
                {['submitted', 'under_review'].includes(a.status) && (
                  <>
                    <Button size="sm" loading={busy} disabled={!a.eligibility.eligible} onClick={() => approve(a)}>{t('premium.admin.approve')}</Button>
                    <Button size="sm" variant="outline" onClick={() => setDialog({ mode: 'reject', item: a })}>{t('premium.admin.reject')}</Button>
                  </>
                )}
                {a.status === 'approved' && <Button size="sm" variant="outline" onClick={() => setDialog({ mode: 'revoke', item: a })}>{t('premium.admin.revoke')}</Button>}
              </div>
            </Card>
          ))}
        </div>
      )}
      <ConfirmDialog open={Boolean(dialog)} onClose={close} danger loading={busy}
        title={dialog?.mode === 'revoke' ? t('premium.admin.revoke') : t('premium.admin.reject')}
        confirmLabel={dialog?.mode === 'revoke' ? t('premium.admin.revoke') : t('premium.admin.reject')}
        onConfirm={confirmDialog}>
        <Field label={dialog?.mode === 'revoke' ? t('premium.admin.revokeReason') : t('premium.admin.reasonLabel')} required>
          <Textarea rows={3} maxLength={1000} value={reason} onChange={(e) => setReason(e.target.value)} />
        </Field>
        {!reason.trim() && <p className="mt-2 text-xs text-ink-muted">{t('premium.admin.reasonRequired')}</p>}
      </ConfirmDialog>
    </div>
  );
}
