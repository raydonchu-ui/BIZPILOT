// The blue tick: what it means, what the store needs, and the application. Paying for Verified Premium does not
// approve anything; an administrator reviews the documents and decides.
import { FormEvent, useState } from 'react';
import { Link } from 'react-router-dom';
import { useQuery } from '@tanstack/react-query';
import { BadgeCheck, Upload } from 'lucide-react';
import { useI18n } from '../../../i18n';
import { useBiz } from '../../../lib/business';
import { rpc } from '../../../lib/api';
import { useAction } from '../../../lib/useAction';
import { uploadFile } from '../../../lib/hooks';
import { formatDate } from '../../../lib/format';
import { Alert, Badge, Button, Card, CardHeader, Field, Input, PageLoader, ErrorState, Select } from '../../../components/ui';

const ID_TYPES = ['national_id', 'passport', 'business_registration'] as const;

export function VerificationPanel() {
  const { t, lang } = useI18n();
  const { id, can } = useBiz();
  const { run, busy } = useAction();
  const [form, setForm] = useState({ legal_name: '', id_type: 'national_id', id_last4: '', id_document_path: '', business_document_path: '' });
  const [uploading, setUploading] = useState<string | null>(null);
  const q = useQuery({ queryKey: ['verification', id], enabled: Boolean(id), queryFn: () => rpc<any>('verification_status', { p_business: id }) });
  if (q.isLoading) return <PageLoader />;
  if (q.error || !q.data) return <ErrorState error={q.error ?? { message: 'not_found' }} />;
  const v = q.data;
  const e = v.eligibility;
  const app = v.application;
  const open = app && ['submitted', 'under_review'].includes(app.status);
  const canApply = can('store.manage') && e?.eligible && !open;
  const statusKey = app && ['rejected', 'withdrawn', 'revoked', 'expired'].includes(app.status) ? app.status : v.verification === 'verified' ? 'verified' : v.verification === 'pending' ? 'pending' : v.verification === 'rejected' ? 'rejected_store' : (app?.status ?? 'none');
  const statusLabel = t(`premium.verify.statuses.${statusKey}`);
  const attach = async (key: 'id_document_path' | 'business_document_path', file?: File) => {
    if (!file) return;
    setUploading(key);
    try {
      const path = await run(() => uploadFile(id, 'verification', file));
      if (path) setForm((f) => ({ ...f, [key]: path }));
    } finally { setUploading(null); }
  };
  const submit = async (ev: FormEvent) => {
    ev.preventDefault();
    if (!form.id_document_path) return;
    const r = await run(() => rpc('verification_apply', { p_business: id, p: form }), t('premium.verify.submitted'));
    if (r) q.refetch();
  };
  const withdraw = async () => {
    const r = await run(() => rpc('verification_withdraw', { p_application: app.id }), t('premium.verify.withdrawn'));
    if (r !== undefined) q.refetch();
  };
  return (
    <div className="grid gap-4 lg:grid-cols-[minmax(0,1fr)_360px]">
      <div className="space-y-4">
        <Card>
          <div className="flex items-start gap-3">
            <BadgeCheck className={v.blue_tick ? 'h-8 w-8 text-sky-500' : 'h-8 w-8 text-gray-300'} aria-hidden />
            <div className="flex-1">
              <CardHeader title={t('premium.verify.title')} />
              <p className="text-sm text-ink-muted">{t('premium.verify.subtitle')}</p>
              <p className="mt-3 font-semibold">{v.blue_tick ? t('premium.verify.tickOn') : t('premium.verify.tickOff')}
                {v.blue_tick && v.expires_at && <span className="block text-sm font-normal text-ink-muted">{t('premium.verify.tickOnUntil', { date: formatDate(v.expires_at, lang) })}</span>}</p>
              {!v.premium_active && (
                <div className="mt-3"><Alert tone="amber">{t('premium.verify.needPremium', { plan: v.plan_code })}
                  {' '}<Link to="/app/billing" className="font-semibold underline">{t('premium.verify.upgrade')}</Link></Alert></div>
              )}
            </div>
          </div>
        </Card>

        <Card>
          <CardHeader title={t('premium.verify.statusTitle')} action={<Badge tone={statusKey === 'verified' || statusKey === 'approved' ? 'green' : open || statusKey === 'pending' ? 'amber' : 'gray'}>{statusLabel}</Badge>} />
          {v.verification_note && !open && <p className="text-sm">{v.verification_note}</p>}
          {app?.decision_reason && !open && <p className="mt-1 text-sm text-ink-muted">{app.decision_reason}</p>}
          {open && <p className="text-sm">{t('premium.verify.submitted')}</p>}
          {open && can('store.manage') && <div className="mt-3"><Button variant="outline" size="sm" loading={busy} onClick={withdraw}>{t('premium.verify.withdraw')}</Button></div>}
        </Card>

        {canApply && (
          <Card>
            <CardHeader title={t('premium.verify.applyTitle')} />
            <form onSubmit={submit} className="grid gap-4 sm:grid-cols-2">
              <Field className="sm:col-span-2" label={t('premium.verify.legalName')} required>
                <Input maxLength={120} minLength={3} value={form.legal_name} onChange={(ev) => setForm({ ...form, legal_name: ev.target.value })} />
              </Field>
              <Field label={t('premium.verify.idType')} required>
                <Select value={form.id_type} onChange={(ev) => setForm({ ...form, id_type: ev.target.value })}>
                  {ID_TYPES.map((k) => <option key={k} value={k}>{t(`premium.verify.idTypes.${k}`)}</option>)}
                </Select>
              </Field>
              <Field label={t('premium.verify.idLast4')} hint={t('premium.verify.idLast4Hint')} optional>
                <Input inputMode="numeric" maxLength={4} pattern="[0-9]{0,4}" autoComplete="off" value={form.id_last4}
                  onChange={(ev) => setForm({ ...form, id_last4: ev.target.value.replace(/\D/g, '').slice(0, 4) })} />
              </Field>
              <Field className="sm:col-span-2" label={t('premium.verify.idDocument')} required hint={t('premium.verify.uploadHint')}>
                <label className="flex min-h-11 cursor-pointer items-center gap-2 rounded-lg border border-dashed border-gray-300 px-3 py-2 text-sm dark:border-gray-700">
                  <Upload className="h-4 w-4" />{uploading === 'id_document_path' ? '…' : form.id_document_path ? t('premium.verify.uploaded') : t('premium.verify.idDocument')}
                  <input type="file" accept="image/jpeg,image/png,application/pdf" className="sr-only" onChange={(ev) => attach('id_document_path', ev.target.files?.[0])} />
                </label>
              </Field>
              <Field className="sm:col-span-2" label={t('premium.verify.businessDocument')} optional>
                <label className="flex min-h-11 cursor-pointer items-center gap-2 rounded-lg border border-dashed border-gray-300 px-3 py-2 text-sm dark:border-gray-700">
                  <Upload className="h-4 w-4" />{uploading === 'business_document_path' ? '…' : form.business_document_path ? t('premium.verify.uploaded') : t('premium.verify.businessDocument')}
                  <input type="file" accept="image/jpeg,image/png,application/pdf" className="sr-only" onChange={(ev) => attach('business_document_path', ev.target.files?.[0])} />
                </label>
              </Field>
              <div className="sm:col-span-2 flex justify-end">
                <Button type="submit" loading={busy} disabled={!form.id_document_path || form.legal_name.trim().length < 3}>{t('premium.verify.submit')}</Button>
              </div>
            </form>
          </Card>
        )}
      </div>

      <Card>
        <CardHeader title={t('premium.verify.eligibilityTitle')} />
        {e ? (
          <ul className="space-y-2 text-sm">
            {(e.reasons ?? []).map((r: string) => <li key={r} className="text-red-700">{t(`premium.verify.reasons.${r}`)}</li>)}
          </ul>
        ) : <p className="text-sm text-ink-muted">{t('premium.verify.reapply')}</p>}
        {e?.eligible && <p className="mt-3 text-sm text-brand-700">{t('premium.verify.eligible')}</p>}
        <p className="mt-4 text-xs text-ink-muted">{t('premium.verify.reapply')}</p>
      </Card>
    </div>
  );
}
