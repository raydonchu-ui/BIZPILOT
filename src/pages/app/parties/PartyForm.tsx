import { useEffect, useState } from 'react';
import { useI18n } from '../../../i18n';
import { useBiz } from '../../../lib/business';
import { supabase } from '../../../lib/supabase';
import { unwrap } from '../../../lib/api';
import { useAction } from '../../../lib/useAction';
import { toNumber } from '../../../lib/format';
import { Button, Field, Input, Modal, Textarea } from '../../../components/ui';

export function PartyFormModal({ kind, open, onClose, initial, onSaved }:
  { kind: 'supplier' | 'customer'; open: boolean; onClose: () => void; initial?: any; onSaved?: (id: string) => void }) {
  const { t } = useI18n();
  const { id } = useBiz();
  const { run, busy } = useAction();
  const empty = { name: '', contact_person: '', phone: '', email: '', address: '', reference: '', payment_terms_days: '', lead_time_days: '', quality_notes: '', credit_limit: '', notes: '' };
  const [f, setF] = useState(empty);
  useEffect(() => {
    if (!open) return;
    setF(initial ? Object.fromEntries(Object.keys(empty).map((k) => [k, initial[k] == null ? '' : String(initial[k])])) as typeof empty : empty);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [open, initial]);
  const set = (k: keyof typeof empty) => (e: { target: { value: string } }) => setF((x) => ({ ...x, [k]: e.target.value }));
  const submit = async () => {
    const row: Record<string, unknown> = kind === 'supplier'
      ? { name: f.name.trim(), contact_person: f.contact_person || null, phone: f.phone || null, email: f.email || null, address: f.address || null, reference: f.reference || null,
          payment_terms_days: f.payment_terms_days === '' ? null : Math.round(toNumber(f.payment_terms_days)), lead_time_days: f.lead_time_days === '' ? null : Math.round(toNumber(f.lead_time_days)),
          quality_notes: f.quality_notes || null, notes: f.notes || null }
      : { name: f.name.trim(), phone: f.phone || null, email: f.email || null, address: f.address || null, credit_limit: f.credit_limit === '' ? null : toNumber(f.credit_limit), notes: f.notes || null };
    const table = kind === 'supplier' ? 'suppliers' : 'customers';
    const res = await run(async () => initial?.id
      ? unwrap(await supabase.from(table).update(row).eq('id', initial.id).select('id').single()) as { id: string }
      : unwrap(await supabase.from(table).insert({ ...row, business_id: id }).select('id').single()) as { id: string }, t('common.saved'));
    if (res) { onSaved?.(res.id); onClose(); }
  };
  return (
    <Modal open={open} onClose={onClose} title={initial?.id ? t(`parties.edit_${kind}`) : t(`parties.new_${kind}`)}
      footer={<><Button variant="outline" onClick={onClose}>{t('common.cancel')}</Button><Button loading={busy} disabled={!f.name.trim()} onClick={submit}>{t('common.save')}</Button></>}>
      <div className="grid gap-3 sm:grid-cols-2">
        <Field label={t('common.name')} required className="sm:col-span-2"><Input value={f.name} onChange={set('name')} /></Field>
        {kind === 'supplier' && <Field label={t('parties.contactPerson')}><Input value={f.contact_person} onChange={set('contact_person')} /></Field>}
        <Field label={t('common.phone')}><Input type="tel" value={f.phone} onChange={set('phone')} placeholder="+237" /></Field>
        <Field label={t('common.email')}><Input type="email" value={f.email} onChange={set('email')} /></Field>
        <Field label={t('common.address')}><Input value={f.address} onChange={set('address')} /></Field>
        {kind === 'supplier' ? <>
          <Field label={t('parties.reference')}><Input value={f.reference} onChange={set('reference')} /></Field>
          <Field label={t('parties.paymentTerms')} hint={t('parties.paymentTermsHint')}><Input type="number" min="0" max="365" value={f.payment_terms_days} onChange={set('payment_terms_days')} suffix={t('common.days')} /></Field>
          <Field label={t('parties.leadTime')} hint={t('parties.leadTimeHint')}><Input type="number" min="0" max="365" value={f.lead_time_days} onChange={set('lead_time_days')} suffix={t('common.days')} /></Field>
          <Field label={t('parties.qualityNotes')} className="sm:col-span-2"><Textarea rows={2} value={f.quality_notes} onChange={set('quality_notes')} /></Field>
        </> : (
          <Field label={t('parties.creditLimit')} hint={t('parties.creditLimitHint')}><Input type="number" min="0" step="any" value={f.credit_limit} onChange={set('credit_limit')} suffix="FCFA" /></Field>
        )}
        <Field label={t('common.notes')} className="sm:col-span-2"><Textarea rows={2} value={f.notes} onChange={set('notes')} /></Field>
      </div>
    </Modal>
  );
}
