import { useState } from 'react';
import { useQuery } from '@tanstack/react-query';
import { Smartphone } from 'lucide-react';
import { useI18n } from '../../../i18n';
import { useBiz } from '../../../lib/business';
import { useAuth } from '../../../lib/auth';
import { supabase } from '../../../lib/supabase';
import { rpc, unwrap } from '../../../lib/api';
import { useAction } from '../../../lib/useAction';
import { uploadFile } from '../../../lib/hooks';
import { formatDate, formatDateTime, formatMoney } from '../../../lib/format';
import { Alert, Badge, Button, Card, CardHeader, DataTable, ErrorState, Field, Input, KeyValue, Modal, PageHeader, Select, Textarea, Tone } from '../../../components/ui';
import { Plan, PlanCards, planLimitLines, usePlans } from '../../public/PlanCards';

const stateTone: Record<string, Tone> = { free: 'gray', trial: 'blue', active: 'green', renewal_due: 'amber', grace: 'red', expired: 'red', cancelled: 'amber', suspended: 'red' };

export function usePaymentInstructions() {
  return useQuery({
    queryKey: ['payment_instructions'],
    queryFn: async () => (unwrap(await supabase.from('app_config').select('value').eq('key', 'payment_instructions').maybeSingle()) as any)?.value ?? {},
  });
}

export default function BillingPage() {
  const { t, lang } = useI18n();
  const { id, biz, can } = useBiz();
  const { refreshContext } = useAuth();
  const { run, busy } = useAction();
  const [choice, setChoice] = useState<{ plan: Plan; period: 'monthly' | 'annual' } | null>(null);
  const instr = usePaymentInstructions();
  const plans = usePlans();
  const history = useQuery({
    queryKey: ['billing', id], enabled: can('billing.manage'),
    queryFn: async () => unwrap(await supabase.from('billing_payments').select('*').eq('business_id', id).order('submitted_at', { ascending: false })) as any[],
  });
  if (!can('billing.manage')) return <ErrorState error={{ message: 'permission_denied' }} />;
  const s = biz.subscription;
  const planName = lang === 'fr' ? biz.plan.name_fr : biz.plan.name_en;
  const planLabel = (code: string) => { const p = plans.data?.find((x) => x.code === code); return p ? (lang === 'fr' ? p.name_fr : p.name_en) : code; };
  const configured = ['mtn_momo', 'orange_money'].filter((m) => instr.data?.[m]?.enabled && instr.data?.[m]?.number);
  return (
    <div>
      <PageHeader title={t('nav.billing')} subtitle={t('billing.subtitle')} />
      <div className="grid gap-4 lg:grid-cols-3">
        <Card className="lg:col-span-2">
          <CardHeader title={t('billing.currentPlan')} />
          <div className="flex flex-wrap items-center gap-3"><p className="text-2xl font-extrabold">{planName}</p><Badge tone={stateTone[s.state] ?? 'gray'}>{t(`subscriptionState.${s.state}`)}</Badge>{s.payment_pending && <Badge tone="amber">{t('billing.paymentPending')}</Badge>}</div>
          <div className="mt-4"><KeyValue cols={3} items={[
            { label: t('billing.subscribedPlan'), value: planLabel(s.plan_code) },
            ...(s.trial_ends_at && s.state === 'trial' ? [{ label: t('billing.trialEnds'), value: formatDate(s.trial_ends_at, lang) }] : []),
            ...(s.current_period_end ? [{ label: t('billing.periodEnds'), value: formatDate(s.current_period_end, lang) }] : []),
            ...(s.state === 'grace' && s.grace_ends_at ? [{ label: t('billing.graceEnds'), value: formatDate(s.grace_ends_at, lang) }] : []),
            ...(s.billing_period ? [{ label: t('billing.billingPeriod'), value: t(`site.pricing.${s.billing_period}`) }] : []),
          ]} /></div>
          <p className="mt-4 text-sm text-ink-muted">{t(`billing.stateHelp.${s.state}`)}</p>
          <ul className="mt-3 grid gap-1 text-sm sm:grid-cols-2">{planLimitLines({ ...biz.plan, price_monthly: 0, price_annual: 0, description_en: '', description_fr: '', highlight: false, sort: 0 } as Plan, t, lang).map((l) => <li key={l}>• {l}</li>)}</ul>
          {s.state === 'active' || s.state === 'renewal_due' || s.state === 'cancelled' ? (
            <div className="mt-4"><Button variant="outline" size="sm" loading={busy} onClick={async () => { await run(() => rpc('cancel_subscription', { p_business: id, p_cancel: !s.cancel_at_period_end }), t('common.saved')); refreshContext(); }}>
              {s.cancel_at_period_end ? t('billing.resumeRenewal') : t('billing.cancelRenewal')}</Button></div>
          ) : null}
        </Card>
        <Card>
          <CardHeader title={t('billing.howToPay')} />
          {configured.length === 0 ? <Alert tone="amber">{t('billing.notConfigured')}</Alert> : (
            <ul className="space-y-3 text-sm">
              {configured.map((m) => (
                <li key={m} className="rounded-xl border border-gray-200 p-3 dark:border-gray-800">
                  <p className="flex items-center gap-2 font-bold"><Smartphone className="h-4 w-4 text-brand-600" />{t(`methods.${m}`)}</p>
                  <p className="mt-1">{t('billing.sendTo')}: <b>{instr.data[m].number}</b></p>
                  {instr.data[m].account_name && <p>{t('billing.accountName')}: <b>{instr.data[m].account_name}</b></p>}
                </li>
              ))}
              {(lang === 'fr' ? instr.data?.notes_fr : instr.data?.notes_en) && <li className="text-ink-muted">{lang === 'fr' ? instr.data.notes_fr : instr.data.notes_en}</li>}
            </ul>
          )}
          <ol className="mt-4 list-decimal space-y-1 pl-5 text-sm text-ink-muted">
            <li>{t('billing.step1')}</li><li>{t('billing.step2')}</li><li>{t('billing.step3')}</li>
          </ol>
          <p className="mt-3 text-xs text-ink-muted">{t('billing.verificationNote')}</p>
        </Card>
      </div>
      <Card className="mt-4">
        <CardHeader title={t('billing.choosePlan')} />
        <PlanCards currentPlan={s.state === 'active' || s.state === 'renewal_due' ? s.plan_code : undefined} chooseLabel={t('billing.payForPlan')}
          onChoose={(plan, period) => plan.price_monthly > 0 && setChoice({ plan, period })} />
      </Card>
      <Card className="mt-4">
        <CardHeader title={t('billing.history')} />
        <DataTable rows={history.data ?? []} rowKey={(r) => r.id} empty={<p className="py-6 text-center text-sm text-ink-muted">{t('billing.noHistory')}</p>} columns={[
          { key: 'd', header: t('common.date'), render: (r) => formatDateTime(r.submitted_at, lang) },
          { key: 'p', header: t('billing.plan'), render: (r) => `${planLabel(r.plan_code)} · ${t(`site.pricing.${r.billing_period}`)}` },
          { key: 'm', header: t('common.method'), render: (r) => <div><p>{t(`methods.${r.method}`)}</p><p className="font-mono text-xs text-ink-muted">{r.transaction_ref}</p></div> },
          { key: 'a', header: t('common.amount'), align: 'right', render: (r) => formatMoney(r.amount, lang) },
          { key: 's', header: t('common.status'), render: (r) => <div><Badge tone={r.status === 'verified' ? 'green' : r.status === 'rejected' ? 'red' : 'amber'}>{t(`billing.paymentStatus.${r.status}`)}</Badge>{r.review_note && <p className="mt-1 text-xs text-ink-muted">{r.review_note}</p>}</div> },
          { key: 'e', header: t('billing.periodEnds'), hideOnMobile: true, render: (r) => r.period_end ? formatDate(r.period_end, lang) : '' },
        ]} />
      </Card>
      {choice && <SubmitPaymentModal plan={choice.plan} period={choice.period} methods={configured} onClose={() => setChoice(null)} />}
    </div>
  );
}

function SubmitPaymentModal({ plan, period, methods, onClose }: { plan: Plan; period: 'monthly' | 'annual'; methods: string[]; onClose: () => void }) {
  const { t, lang } = useI18n();
  const { id } = useBiz();
  const { refreshContext } = useAuth();
  const { run, busy } = useAction();
  const amount = period === 'annual' ? (plan.price_annual ?? plan.price_monthly * 12) : plan.price_monthly;
  const [f, setF] = useState({ method: methods[0] ?? 'mtn_momo', transaction_ref: '', payer_phone: '', payer_name: '', note: '' });
  const [file, setFile] = useState<File | null>(null);
  const submit = async () => {
    const ok = await run(async () => {
      const proof = file ? await uploadFile(id, 'billing', file) : null;
      return rpc('submit_billing_payment', { p_business: id, p: { plan_code: plan.code, billing_period: period, ...f, amount, proof_path: proof } });
    }, t('billing.submitted'));
    if (ok) { refreshContext(); onClose(); }
  };
  return (
    <Modal open onClose={onClose} title={t('billing.submitTitle', { plan: lang === 'fr' ? plan.name_fr : plan.name_en })}
      footer={<><Button variant="outline" onClick={onClose}>{t('common.cancel')}</Button><Button loading={busy} disabled={f.transaction_ref.trim().length < 4} onClick={submit}>{t('billing.submitPayment')}</Button></>}>
      <div className="space-y-3">
        <Alert tone="blue">{t('billing.amountToPay', { amount: formatMoney(amount, lang), period: t(`site.pricing.${period}`) })}</Alert>
        <Field label={t('common.method')}><Select value={f.method} onChange={(e) => setF({ ...f, method: e.target.value })}>{(methods.length ? methods : ['mtn_momo', 'orange_money']).map((m) => <option key={m} value={m}>{t(`methods.${m}`)}</option>)}<option value="bank_transfer">{t('methods.bank_transfer')}</option></Select></Field>
        <Field label={t('billing.transactionRef')} required hint={t('billing.transactionRefHint')}><Input value={f.transaction_ref} onChange={(e) => setF({ ...f, transaction_ref: e.target.value })} /></Field>
        <div className="grid grid-cols-2 gap-3">
          <Field label={t('billing.payerPhone')}><Input type="tel" value={f.payer_phone} onChange={(e) => setF({ ...f, payer_phone: e.target.value })} /></Field>
          <Field label={t('billing.payerName')}><Input value={f.payer_name} onChange={(e) => setF({ ...f, payer_name: e.target.value })} /></Field>
        </div>
        <Field label={t('billing.proof')} hint={t('billing.proofHint')}><Input type="file" accept="image/*,application/pdf" onChange={(e) => setFile(e.target.files?.[0] ?? null)} /></Field>
        <Field label={t('common.notes')}><Textarea rows={2} value={f.note} onChange={(e) => setF({ ...f, note: e.target.value })} /></Field>
      </div>
    </Modal>
  );
}
