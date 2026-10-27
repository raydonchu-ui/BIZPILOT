// Creator programme for administrators: program settings, creator decisions, referral checks, payout queue and
// reconciliation. Every action is checked on the server and recorded in the audit log.
import { FormEvent, useState } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import clsx from 'clsx';
import { useI18n } from '../../i18n';
import { rpc } from '../../lib/api';
import { useAction } from '../../lib/useAction';
import { formatDateTime } from '../../lib/format';
import { Alert, Badge, Button, Card, CardHeader, Checkbox, ConfirmDialog, Field, Input, PageHeader, PageLoader, Select, Textarea } from '../../components/ui';

const fcfa = (n: unknown) => `${Math.round(Number(n) || 0).toLocaleString('fr-FR').replace(/\s/g, ' ')} FCFA`;

type Dialog = { kind: 'decision'; creator: any; decision: string } | { kind: 'payout'; payout: any; status: string } | { kind: 'adjust'; creator: any };

export function CreatorsAdmin() {
  const { t, lang } = useI18n();
  const { run, busy } = useAction();
  const qc = useQueryClient();
  const [statusFilter, setStatusFilter] = useState<string>('');
  const [payoutFilter, setPayoutFilter] = useState<string>('requested');
  const [dialog, setDialog] = useState<Dialog | null>(null);
  const [reason, setReason] = useState('');
  const [reference, setReference] = useState('');
  const [rate, setRate] = useState('5');
  const [applies, setApplies] = useState('both');
  const [amount, setAmount] = useState('');
  const [openRef, setOpenRef] = useState<string | null>(null);
  const cfg = useQuery({ queryKey: ['admin-creator-program'], queryFn: () => rpc<any>('admin_creator_program_get') });
  const creators = useQuery({ queryKey: ['admin-creators', statusFilter], queryFn: () => rpc<any[]>('admin_creator_list', { p_status: statusFilter || null }) });
  const payouts = useQuery({ queryKey: ['admin-payouts', payoutFilter], queryFn: () => rpc<any[]>('admin_list_payouts', { p_status: payoutFilter || null }) });
  const referrals = useQuery({ queryKey: ['admin-creator-refs', openRef], enabled: Boolean(openRef), queryFn: () => rpc<any[]>('admin_creator_referrals', { p_user: openRef }) });
  const [reconcile, setReconcile] = useState<any>(null);
  const [enabledOn, setEnabledOn] = useState<boolean | null>(null);
  if (cfg.isLoading || creators.isLoading || payouts.isLoading) return <PageLoader />;
  const refresh = () => { qc.invalidateQueries({ queryKey: ['admin-creators'] }); qc.invalidateQueries({ queryKey: ['admin-payouts'] }); };
  const close = () => { setDialog(null); setReason(''); setReference(''); setAmount(''); };

  const saveProgram = async (e: FormEvent<HTMLFormElement>) => {
    e.preventDefault();
    const f = new FormData(e.currentTarget);
    const r = await run(() => rpc('admin_set_creator_program', { p: {
      enabled: enabledOn ?? Boolean(c.enabled), default_rate: Number(f.get('default_rate')), min_rate: Number(f.get('min_rate')),
      max_rate: Number(f.get('max_rate')), applies_to: String(f.get('applies_to')), hold_days: Number(f.get('hold_days')),
      payout_minimum: Number(f.get('payout_minimum')), attribution_months: Number(f.get('attribution_months')) } }), t('common.saved'));
    if (r !== undefined) qc.invalidateQueries({ queryKey: ['admin-creator-program'] });
  };
  const confirm = async () => {
    if (!dialog) return;
    let r: unknown;
    if (dialog.kind === 'decision') {
      const d = dialog.decision;
      if (d === 'approve') r = await run(() => rpc('admin_review_creator', { p_user: dialog.creator.user_id, p_decision: 'approve', p_rate: Number(rate), p_applies: applies }), t('creatorAdmin.done'));
      else r = await run(() => rpc('admin_review_creator', { p_user: dialog.creator.user_id, p_decision: d, p_reason: reason.trim() || null }), t('creatorAdmin.done'));
    } else if (dialog.kind === 'payout') {
      r = await run(() => rpc('admin_set_payout_status', { p_request: dialog.payout.id, p_status: dialog.status, p_reference: reference.trim() || null, p_note: reason.trim() || null }), t('creatorAdmin.done'));
    } else {
      r = await run(() => rpc('admin_creator_adjustment', { p_user: dialog.creator.user_id, p_amount: Number(amount), p_reason: reason.trim() }), t('creatorAdmin.done'));
    }
    if (r !== undefined) { close(); refresh(); }
  };
  const runReconcile = async () => {
    const r = await run(() => rpc<any>('admin_creator_reconcile'));
    if (r) setReconcile(r);
  };
  const needsReason = dialog && (dialog.kind === 'adjust' || (dialog.kind === 'decision' && dialog.decision !== 'approve') || (dialog.kind === 'payout' && ['cancelled', 'failed', 'reversed'].includes(dialog.status)));
  const needsRef = dialog?.kind === 'payout' && dialog.status === 'paid';
  const c = cfg.data ?? {};

  return (
    <div className="space-y-4">
      <PageHeader title={t('creatorAdmin.title')} subtitle={t('creatorAdmin.subtitle')} />

      <Card>
        <CardHeader title={t('creatorAdmin.program')} subtitle={t('creatorAdmin.programSub')} />
        <form onSubmit={saveProgram} key={JSON.stringify(c)} className="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
          <div className="sm:col-span-2 lg:col-span-4"><Checkbox label={t('creatorAdmin.enabled')} checked={enabledOn ?? Boolean(c.enabled)} onChange={(v) => setEnabledOn(v)} hint={t('creatorAdmin.enabledHint')} /></div>
          <Field label={t('creatorAdmin.minRate')} hint="2 – 10"><Input name="min_rate" type="number" step="0.5" min={2} max={10} defaultValue={c.min_rate ?? 2} /></Field>
          <Field label={t('creatorAdmin.defaultRate')}><Input name="default_rate" type="number" step="0.5" min={2} max={10} defaultValue={c.default_rate ?? 5} /></Field>
          <Field label={t('creatorAdmin.maxRate')}><Input name="max_rate" type="number" step="0.5" min={2} max={10} defaultValue={c.max_rate ?? 10} /></Field>
          <Field label={t('creatorAdmin.appliesTo')}>
            <Select name="applies_to" defaultValue={c.applies_to ?? 'both'}>
              <option value="both">{t('creatorAdmin.both')}</option><option value="initial">{t('creatorAdmin.initial')}</option><option value="renewal">{t('creatorAdmin.renewal')}</option>
            </Select>
          </Field>
          <Field label={t('creatorAdmin.holdDays')}><Input name="hold_days" type="number" min={0} max={90} defaultValue={c.hold_days ?? 7} /></Field>
          <Field label={t('creatorAdmin.payoutMinimum')}><Input name="payout_minimum" type="number" min={0} defaultValue={c.payout_minimum ?? 5000} /></Field>
          <Field label={t('creatorAdmin.attributionMonths')}><Input name="attribution_months" type="number" min={1} max={36} defaultValue={c.attribution_months ?? 12} /></Field>
          <div className="flex items-end justify-end"><Button type="submit" loading={busy}>{t('common.save')}</Button></div>
        </form>
        <p className="mt-3 text-xs text-ink-muted">{t('creatorAdmin.enableNote')}</p>
      </Card>

      <Card>
        <CardHeader title={t('creatorAdmin.creators')} action={
          <Select aria-label={t('creatorAdmin.filter')} value={statusFilter} onChange={(e) => setStatusFilter(e.target.value)}>
            <option value="">{t('creatorAdmin.all')}</option>
            {['pending', 'approved', 'rejected', 'suspended'].map((s) => <option key={s} value={s}>{t(`creator.status.${s}`)}</option>)}
          </Select>} />
        {(creators.data ?? []).length === 0 ? <p className="text-sm text-ink-muted">{t('creatorAdmin.none')}</p> : (
          <ul className="divide-y divide-gray-100 dark:divide-gray-800">
            {(creators.data ?? []).map((cr: any) => (
              <li key={cr.user_id} className="py-3">
                <div className="flex flex-wrap items-center justify-between gap-2">
                  <div>
                    <p className="font-semibold">{cr.display_name} <Badge tone={cr.status === 'approved' ? 'green' : cr.status === 'pending' ? 'amber' : 'red'}>{t(`creator.status.${cr.status}`)}</Badge></p>
                    <p className="text-xs text-ink-muted">{cr.referral_code} · {formatDateTime(cr.created_at, lang)}{cr.commission_rate != null && ` · ${cr.commission_rate}% (${cr.applies_to})`}</p>
                    {cr.decision_reason && <p className="text-xs text-ink-muted">{cr.decision_reason}</p>}
                    <p className="text-xs text-ink-muted">{t('creatorAdmin.balanceLine', { pending: fcfa(cr.balance.pending), available: fcfa(cr.balance.withdrawable), paid: fcfa(cr.balance.paid) })}</p>
                  </div>
                  <div className="flex flex-wrap gap-2">
                    {cr.status === 'pending' && <Button size="sm" onClick={() => { setRate(String(c.default_rate ?? 5)); setApplies(c.applies_to ?? 'both'); setDialog({ kind: 'decision', creator: cr, decision: 'approve' }); }}>{t('creatorAdmin.approve')}</Button>}
                    {cr.status === 'pending' && <Button size="sm" variant="outline" onClick={() => setDialog({ kind: 'decision', creator: cr, decision: 'reject' })}>{t('creatorAdmin.reject')}</Button>}
                    {cr.status === 'approved' && <Button size="sm" variant="outline" onClick={() => setDialog({ kind: 'decision', creator: cr, decision: 'suspend' })}>{t('creatorAdmin.suspend')}</Button>}
                    {cr.status === 'suspended' && <Button size="sm" onClick={() => setDialog({ kind: 'decision', creator: cr, decision: 'reactivate' })}>{t('creatorAdmin.reactivate')}</Button>}
                    <Button size="sm" variant="outline" onClick={() => setOpenRef(openRef === cr.user_id ? null : cr.user_id)}>{t('creatorAdmin.referrals')}</Button>
                    <Button size="sm" variant="outline" onClick={() => setDialog({ kind: 'adjust', creator: cr })}>{t('creatorAdmin.adjust')}</Button>
                  </div>
                </div>
                {openRef === cr.user_id && (
                  <div className="mt-3 rounded-xl bg-gray-50 p-3 text-sm dark:bg-gray-800/60">
                    {referrals.isLoading ? <PageLoader /> : (referrals.data ?? []).length === 0 ? <p>{t('creatorAdmin.noReferrals')}</p> : (
                      <ul className="space-y-1">
                        {(referrals.data ?? []).map((r: any) => (
                          <li key={r.business_id} className={clsx(r.shared_member && 'text-red-700')}>
                            {r.business_name} · {formatDateTime(r.attributed_at, lang)} · {t('creatorAdmin.payments', { n: r.verified_payments })}
                            {r.shared_member && <> · <b>{t('creatorAdmin.sharedMember')}</b></>}
                          </li>
                        ))}
                      </ul>
                    )}
                  </div>
                )}
              </li>
            ))}
          </ul>
        )}
      </Card>

      <Card>
        <CardHeader title={t('creatorAdmin.payouts')} action={
          <Select aria-label={t('creatorAdmin.filter')} value={payoutFilter} onChange={(e) => setPayoutFilter(e.target.value)}>
            <option value="">{t('creatorAdmin.all')}</option>
            {['requested', 'approved', 'processing', 'paid', 'failed', 'cancelled', 'reversed'].map((s) => <option key={s} value={s}>{t(`creator.payoutStatus.${s}`)}</option>)}
          </Select>} />
        {(payouts.data ?? []).length === 0 ? <p className="text-sm text-ink-muted">{t('creatorAdmin.noPayouts')}</p> : (
          <ul className="divide-y divide-gray-100 text-sm dark:divide-gray-800">
            {(payouts.data ?? []).map((p: any) => {
              const next: string[] = p.status === 'requested' ? ['approved', 'cancelled'] : p.status === 'approved' ? ['processing', 'cancelled']
                : p.status === 'processing' ? ['paid', 'failed'] : p.status === 'paid' ? ['reversed'] : [];
              return (
                <li key={p.id} className="flex flex-wrap items-center justify-between gap-2 py-3">
                  <div>
                    <p className="font-semibold">{p.display_name} · {fcfa(p.amount)}</p>
                    <p className="text-xs text-ink-muted">{t(`methods.${p.provider}`)} · {p.phone} · {p.account_name ?? ''} · {formatDateTime(p.requested_at, lang)}</p>
                    {p.provider_reference && <p className="font-mono text-xs">{p.provider_reference}</p>}
                    {p.decision_note && <p className="text-xs text-ink-muted">{p.decision_note}</p>}
                  </div>
                  <div className="flex flex-wrap items-center gap-2">
                    <Badge tone={p.status === 'paid' ? 'green' : p.status === 'requested' ? 'amber' : 'gray'}>{t(`creator.payoutStatus.${p.status}`)}</Badge>
                    {next.map((n) => (
                      <Button key={n} size="sm" variant={n === 'cancelled' || n === 'failed' || n === 'reversed' ? 'outline' : 'primary'}
                        onClick={() => setDialog({ kind: 'payout', payout: p, status: n })}>{t(`creatorAdmin.to.${n}`)}</Button>
                    ))}
                  </div>
                </li>
              );
            })}
          </ul>
        )}
      </Card>

      <Card>
        <CardHeader title={t('creatorAdmin.reconcile')} subtitle={t('creatorAdmin.reconcileSub')} action={<Button size="sm" variant="outline" loading={busy} onClick={runReconcile}>{t('creatorAdmin.runCheck')}</Button>} />
        {reconcile && (
          <Alert tone={reconcile.balanced ? 'green' : 'amber'} title={reconcile.balanced ? t('creatorAdmin.balanced') : t('creatorAdmin.differences')}>
            {t('creatorAdmin.checkLine', { missing: reconcile.verified_payments_without_accrual, reversals: reconcile.reversals_without_refund, overpaid: reconcile.creators_paid_above_available })}
          </Alert>
        )}
      </Card>

      <ConfirmDialog open={Boolean(dialog)} onClose={close} loading={busy} danger={dialog?.kind === 'decision' && dialog.decision !== 'approve'}
        title={dialog?.kind === 'decision' ? t(`creatorAdmin.to.${dialog.decision}`) : dialog?.kind === 'payout' ? t(`creatorAdmin.to.${dialog.status}`) : t('creatorAdmin.adjust')}
        confirmLabel={t('creatorAdmin.confirm')} onConfirm={confirm}>
        {dialog?.kind === 'decision' && dialog.decision === 'approve' && (
          <div className="grid gap-3 sm:grid-cols-2">
            <Field label={t('creatorAdmin.rate')} hint={`${c.min_rate ?? 2} – ${c.max_rate ?? 10}`}><Input type="number" step="0.5" min={c.min_rate ?? 2} max={c.max_rate ?? 10} value={rate} onChange={(e) => setRate(e.target.value)} /></Field>
            <Field label={t('creatorAdmin.appliesTo')}>
              <Select value={applies} onChange={(e) => setApplies(e.target.value)}>
                <option value="both">{t('creatorAdmin.both')}</option><option value="initial">{t('creatorAdmin.initial')}</option><option value="renewal">{t('creatorAdmin.renewal')}</option>
              </Select>
            </Field>
          </div>
        )}
        {dialog?.kind === 'adjust' && <Field label={t('creatorAdmin.amount')} hint={t('creatorAdmin.amountHint')}><Input inputMode="numeric" value={amount} onChange={(e) => setAmount(e.target.value.replace(/[^\d-]/g, ''))} /></Field>}
        {needsRef && <Field label={t('creatorAdmin.reference')} hint={t('creatorAdmin.referenceHint')}><Input maxLength={80} value={reference} onChange={(e) => setReference(e.target.value)} /></Field>}
        {(needsReason || dialog?.kind === 'payout') && (
          <Field label={t('creatorAdmin.reason')} required={Boolean(needsReason)} className="mt-3"><Textarea rows={2} maxLength={500} value={reason} onChange={(e) => setReason(e.target.value)} /></Field>
        )}
        {needsReason && !reason.trim() && <p className="mt-2 text-xs text-ink-muted">{t('creatorAdmin.reasonRequired')}</p>}
      </ConfirmDialog>
    </div>
  );
}
