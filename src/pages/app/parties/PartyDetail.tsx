import { ReactNode, useState } from 'react';
import { Link } from 'react-router-dom';
import { useQuery } from '@tanstack/react-query';
import { Archive, ArrowLeft, CreditCard, Edit, Printer, RotateCcw } from 'lucide-react';
import { useI18n } from '../../../i18n';
import { useBiz } from '../../../lib/business';
import { supabase } from '../../../lib/supabase';
import { rpc, unwrap, useRpc } from '../../../lib/api';
import { useAction } from '../../../lib/useAction';
import { newId } from '../../../lib/ids';
import { formatDate, formatDateTime, toNumber } from '../../../lib/format';
import { Alert, Badge, Button, Card, CardHeader, DataTable, ErrorState, Field, Input, KeyValue, Modal, PageHeader, PageLoader, Select, useMoney } from '../../../components/ui';
import { PartyFormModal } from './PartyForm';

const METHODS = ['cash', 'mtn_momo', 'orange_money', 'bank_transfer', 'card', 'other'];

export function PartyDetail({ kind, partyId, extra }: { kind: 'supplier' | 'customer'; partyId: string; extra?: (party: any) => ReactNode }) {
  const { t, lang } = useI18n();
  const { id, biz } = useBiz();
  const money = useMoney();
  const { run, busy } = useAction();
  const [edit, setEdit] = useState(false);
  const [pay, setPay] = useState<null | 'payment' | 'refund' | 'credit'>(null);
  const table = kind === 'supplier' ? 'suppliers' : 'customers';
  const party = useQuery({ queryKey: [table, partyId], queryFn: async () => unwrap(await supabase.from(table).select('*').eq('id', partyId).single()) as any });
  const statement = useRpc<any[]>('party_statement', { p_business: id, p_kind: kind, p_party: partyId });
  if (party.isLoading) return <PageLoader />;
  if (party.error) return <ErrorState error={party.error} />;
  const p = party.data;
  const rows = statement.data ?? [];
  const balance = rows.length ? Number(rows[rows.length - 1].running_balance) : 0;
  const toggle = () => run(async () => unwrap(await supabase.from(table).update({ status: p.status === 'active' ? 'archived' : 'active' }).eq('id', partyId)), t('common.saved'));
  return (
    <div>
      <PageHeader back={<Link to={`/app/${table}`} className="mb-2 inline-flex items-center gap-1 text-sm text-ink-muted hover:text-ink no-print"><ArrowLeft className="h-4 w-4" />{t(`nav.${table}`)}</Link>}
        title={<span className="flex items-center gap-3">{p.name}{p.status === 'archived' && <Badge>{t('common.archived')}</Badge>}</span>}
        subtitle={[p.phone, p.email, p.address].filter(Boolean).join(' · ')}
        actions={<div className="flex flex-wrap gap-2 no-print">
          <Button variant="outline" icon={<Printer className="h-4 w-4" />} onClick={() => window.print()}>{t('parties.printStatement')}</Button>
          <Button variant="outline" icon={p.status === 'active' ? <Archive className="h-4 w-4" /> : <RotateCcw className="h-4 w-4" />} loading={busy} onClick={toggle}>{p.status === 'active' ? t('common.archive') : t('common.restore')}</Button>
          <Button variant="outline" icon={<Edit className="h-4 w-4" />} onClick={() => setEdit(true)}>{t('common.edit')}</Button>
          {kind === 'supplier' && balance < 0 && <Button variant="outline" onClick={() => setPay('refund')}>{t('parties.recordRefund')}</Button>}
          {kind === 'supplier' && <Button variant="outline" onClick={() => setPay('credit')}>{t('parties.recordCredit')}</Button>}
          <Button icon={<CreditCard className="h-4 w-4" />} onClick={() => setPay('payment')}>{kind === 'supplier' ? t('parties.paySupplier') : t('parties.receivePayment')}</Button>
        </div>} />
      <div className="print-only mb-4"><p className="text-lg font-bold">{biz.name}</p><p>{t('parties.statementFor', { name: p.name })} — {formatDate(new Date(), lang)}</p></div>
      <div className="grid gap-4 lg:grid-cols-3">
        <Card>
          <p className="text-sm text-ink-muted">{kind === 'supplier' ? t('parties.weOwe') : t('parties.owesUs')}</p>
          <p className={`mt-1 text-3xl font-extrabold ${balance > 0 ? (kind === 'supplier' ? 'text-red-600' : 'text-amber-700') : 'text-brand-700'}`}>{money(Math.abs(balance))}</p>
          {balance < 0 && <p className="text-sm text-brand-700">{kind === 'supplier' ? t('parties.supplierOwesUs') : t('parties.customerHasCredit')}</p>}
          <div className="mt-4"><KeyValue items={kind === 'supplier' ? [
            { label: t('parties.contactPerson'), value: p.contact_person ?? '—' }, { label: t('parties.paymentTerms'), value: p.payment_terms_days != null ? `${p.payment_terms_days} ${t('common.days')}` : '—' },
            { label: t('parties.leadTime'), value: p.lead_time_days != null ? `${p.lead_time_days} ${t('common.days')}` : '—' }, { label: t('parties.reference'), value: p.reference ?? '—' },
          ] : [
            { label: t('parties.creditLimit'), value: p.credit_limit != null ? money(p.credit_limit) : t('parties.noLimit') }, { label: t('common.created'), value: formatDate(p.created_at, lang) },
          ]} /></div>
          {(p.notes || p.quality_notes) && <p className="mt-3 whitespace-pre-line text-sm text-ink-muted">{[p.quality_notes, p.notes].filter(Boolean).join('\n')}</p>}
        </Card>
        <Card className="lg:col-span-2">
          <CardHeader title={t('parties.statement')} subtitle={t('parties.statementSub')} />
          {statement.isLoading ? <PageLoader /> : (
            <DataTable rows={[...rows].reverse()} rowKey={(r) => r.id + r.type} dense empty={<p className="py-6 text-center text-sm text-ink-muted">{t('common.noData')}</p>} columns={[
              { key: 'd', header: t('common.date'), render: (r) => formatDateTime(r.at, lang) },
              { key: 't', header: t('common.type'), render: (r) => t(`parties.stmt.${r.type}`) },
              { key: 'r', header: t('common.reference'), render: (r) => r.type === 'sale' ? <Link to={`/app/sales/${r.id}`} className="hover:underline">{r.ref}</Link> : r.type === 'purchase' ? <Link to={`/app/purchases/${r.id}`} className="hover:underline">{r.ref}</Link> : <span className="text-xs">{t(`paymentKinds.${r.ref}`) === `paymentKinds.${r.ref}` ? r.ref : t(`paymentKinds.${r.ref}`)}</span> },
              { key: 'db', header: kind === 'supplier' ? t('parties.paidOrCredit') : t('parties.charged'), align: 'right', render: (r) => Number(r.debit) ? money(r.debit) : '' },
              { key: 'cr', header: kind === 'supplier' ? t('parties.billed') : t('parties.paidOrReturned'), align: 'right', render: (r) => Number(r.credit) ? money(r.credit) : '' },
              { key: 'b', header: t('common.balance'), align: 'right', render: (r) => <b>{money(r.running_balance)}</b> },
            ]} />
          )}
        </Card>
      </div>
      {extra?.(p)}
      <PartyFormModal kind={kind} open={edit} onClose={() => setEdit(false)} initial={p} />
      {pay && <PartyMoneyModal kind={kind} mode={pay} party={p} balance={balance} onClose={() => setPay(null)} />}
    </div>
  );
}

function PartyMoneyModal({ kind, mode, party, balance, onClose }: { kind: 'supplier' | 'customer'; mode: 'payment' | 'refund' | 'credit'; party: any; balance: number; onClose: () => void }) {
  const { t } = useI18n();
  const { id } = useBiz();
  const { run, busy } = useAction();
  const [ref] = useState(newId);
  const [f, setF] = useState({ amount: mode === 'payment' && balance > 0 ? String(balance) : mode === 'refund' ? String(-balance) : '', method: 'cash', reference: '', reason: '' });
  const submit = async () => {
    const amount = toNumber(f.amount);
    const call = kind === 'customer'
      ? rpc('record_customer_payment', { p_business: id, p_customer: party.id, p_amount: amount, p_method: f.method, p_reference: f.reference || null, p_client_ref: ref })
      : mode === 'payment' ? rpc('record_supplier_payment', { p_business: id, p_supplier: party.id, p_amount: amount, p_method: f.method, p_reference: f.reference || null, p_client_ref: ref })
      : mode === 'refund' ? rpc('record_supplier_refund', { p_business: id, p_supplier: party.id, p_amount: amount, p_method: f.method, p_reference: f.reference || null, p_client_ref: ref })
      : rpc('record_supplier_credit', { p_business: id, p_supplier: party.id, p_amount: amount, p_reason: f.reason });
    const ok = await run(() => call, t('common.saved'));
    if (ok !== undefined) onClose();
  };
  const title = mode === 'credit' ? t('parties.recordCredit') : mode === 'refund' ? t('parties.recordRefund') : kind === 'supplier' ? t('parties.paySupplier') : t('parties.receivePayment');
  return (
    <Modal open onClose={onClose} title={title} size="sm" footer={<><Button variant="outline" onClick={onClose}>{t('common.cancel')}</Button><Button loading={busy} disabled={!(toNumber(f.amount) > 0) || (mode === 'credit' && !f.reason.trim())} onClick={submit}>{t('common.save')}</Button></>}>
      <div className="space-y-3">
        <p className="text-sm text-ink-muted">{t(`parties.help_${kind}_${mode}`)}</p>
        <Field label={t('common.amount')}><Input type="number" min="0" step="any" value={f.amount} onChange={(e) => setF({ ...f, amount: e.target.value })} suffix="FCFA" /></Field>
        {mode !== 'credit' ? <>
          <Field label={t('common.method')}><Select value={f.method} onChange={(e) => setF({ ...f, method: e.target.value })}>{METHODS.map((m) => <option key={m} value={m}>{t(`methods.${m}`)}</option>)}</Select></Field>
          <Field label={t('common.reference')}><Input value={f.reference} onChange={(e) => setF({ ...f, reference: e.target.value })} /></Field>
        </> : <Field label={t('common.reason')} required><Input value={f.reason} onChange={(e) => setF({ ...f, reason: e.target.value })} /></Field>}
        {mode === 'payment' && balance <= 0 && <Alert tone="blue">{t('parties.advanceNote')}</Alert>}
      </div>
    </Modal>
  );
}
