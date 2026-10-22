import { useState } from 'react';
import { Link, useParams } from 'react-router-dom';
import { useQuery } from '@tanstack/react-query';
import { ArrowLeft, Ban, CreditCard, Edit, PackageCheck, Paperclip, Printer, Scissors, Send, Undo2 } from 'lucide-react';
import { useI18n } from '../../../i18n';
import { useBiz } from '../../../lib/business';
import { useAuth } from '../../../lib/auth';
import { supabase } from '../../../lib/supabase';
import { rpc, unwrap } from '../../../lib/api';
import { useAction } from '../../../lib/useAction';
import { attachFile, openFile, useAttachments } from '../../../lib/hooks';
import { newId } from '../../../lib/ids';
import { formatDate, formatDateTime, formatNumber, toNumber } from '../../../lib/format';
import { Alert, Badge, Button, Card, CardHeader, ErrorState, Field, Input, KeyValue, LinkButton, Modal, PageHeader, PageLoader, Select, Textarea, useMoney } from '../../../components/ui';
import { outstanding, purchaseTone } from './PurchasesPage';

const METHODS = ['cash', 'mtn_momo', 'orange_money', 'bank_transfer', 'other'];
type Dialog = null | 'receive' | 'pay' | 'short' | 'return' | 'cancel';

export default function PurchaseDetail() {
  const { id: pid } = useParams();
  const { t, lang } = useI18n();
  const { id } = useBiz();
  const { session } = useAuth();
  const money = useMoney();
  const { run, busy } = useAction();
  const [dialog, setDialog] = useState<Dialog>(null);
  const q = useQuery({
    queryKey: ['purchase', pid],
    queryFn: async () => {
      const p = unwrap(await supabase.from('purchases').select('*, suppliers(id,name,phone), purchase_lines(*, products(id,name,base_unit,track_expiry))').eq('id', pid!).single()) as any;
      p.purchase_lines.sort((a: any, b: any) => a.sort - b.sort);
      const [receipts, credits, allocs, returns] = await Promise.all([
        supabase.from('purchase_receipts').select('*, purchase_receipt_lines(*, products(name))').eq('purchase_id', pid!).order('received_at'),
        supabase.from('supplier_credits').select('*').eq('purchase_id', pid!).order('created_at'),
        supabase.from('payment_allocations').select('amount, payments(id,paid_at,method,reference,kind,amount)').eq('purchase_id', pid!),
        supabase.from('supplier_returns').select('*').eq('purchase_id', pid!).order('created_at'),
      ]);
      return { p, receipts: unwrap(receipts) as any[], credits: unwrap(credits) as any[], allocs: unwrap(allocs) as any[], returns: unwrap(returns) as any[] };
    },
  });
  const files = useAttachments('purchase', pid);
  if (q.isLoading) return <PageLoader />;
  if (q.error) return <ErrorState error={q.error} onRetry={() => q.refetch()} />;
  const { p, receipts, credits, allocs } = q.data!;
  const owed = outstanding(p);
  const anyReceived = p.purchase_lines.some((l: any) => Number(l.qty_received) > 0);
  const canReceive = ['draft', 'ordered', 'partially_received'].includes(p.status);
  const isObligation = ['ordered', 'partially_received', 'received'].includes(p.status);
  const onFile = async (f?: File) => { if (f) await run(() => attachFile(id, 'purchase', p.id, 'purchases', f, session!.user.id), t('common.saved')); };

  return (
    <div>
      <PageHeader back={<Link to="/app/purchases" className="mb-2 inline-flex items-center gap-1 text-sm text-ink-muted hover:text-ink no-print"><ArrowLeft className="h-4 w-4" />{t('nav.purchases')}</Link>}
        title={<span className="flex flex-wrap items-center gap-3">{p.number}<Badge tone={purchaseTone[p.status]}>{t(`purchaseStatus.${p.status}`)}</Badge>{p.closed_short && <Badge tone="amber">{t('purchases.closedShort')}</Badge>}</span>}
        subtitle={`${p.suppliers?.name} · ${formatDate(p.purchase_date, lang)}${p.invoice_number ? ` · ${t('purchases.invoiceNumber')} ${p.invoice_number}` : ''}`}
        actions={<div className="flex flex-wrap gap-2 no-print">
          <Button variant="outline" icon={<Printer className="h-4 w-4" />} onClick={() => window.print()}>{t('common.print')}</Button>
          {['draft', 'ordered'].includes(p.status) && !anyReceived && <LinkButton variant="outline" to={`/app/purchases/${p.id}/edit`} icon={<Edit className="h-4 w-4" />}>{t('common.edit')}</LinkButton>}
          {p.status === 'draft' && <Button variant="outline" icon={<Send className="h-4 w-4" />} loading={busy} onClick={() => run(() => rpc('mark_purchase_ordered', { p_purchase: p.id }), t('common.saved'))}>{t('purchases.markOrdered')}</Button>}
          {['draft', 'ordered'].includes(p.status) && !anyReceived && <Button variant="outline" icon={<Ban className="h-4 w-4" />} onClick={() => setDialog('cancel')}>{t('purchases.cancelPurchase')}</Button>}
          {p.status === 'partially_received' && <Button variant="outline" icon={<Scissors className="h-4 w-4" />} onClick={() => setDialog('short')}>{t('purchases.closeShort')}</Button>}
          {anyReceived && <Button variant="outline" icon={<Undo2 className="h-4 w-4" />} onClick={() => setDialog('return')}>{t('purchases.returnToSupplier')}</Button>}
          {isObligation && owed > 0 && <Button variant="outline" icon={<CreditCard className="h-4 w-4" />} onClick={() => setDialog('pay')}>{t('purchases.recordPayment')}</Button>}
          {canReceive && <Button icon={<PackageCheck className="h-4 w-4" />} onClick={() => setDialog('receive')}>{t('purchases.receiveGoods')}</Button>}
        </div>} />

      {p.status === 'draft' && <div className="mb-4"><Alert tone="blue">{t('purchases.draftNote')}</Alert></div>}
      {p.status === 'cancelled' && <div className="mb-4"><Alert tone="amber" title={t('purchaseStatus.cancelled')}>{p.cancel_reason}</Alert></div>}

      <div className="grid gap-4 lg:grid-cols-3">
        <Card className="lg:col-span-2">
          <CardHeader title={t('nav.products')} />
          <div className="-mx-4 overflow-x-auto sm:mx-0">
            <table className="min-w-full text-sm">
              <thead><tr className="text-left text-xs uppercase text-ink-muted"><th className="px-3 py-2">{t('dashboard.product')}</th><th className="px-3 py-2 text-right">{t('purchases.ordered')}</th>
                <th className="px-3 py-2 text-right">{t('purchases.received')}</th><th className="px-3 py-2 text-right">{t('purchases.unitCost')}</th><th className="px-3 py-2 text-right">{t('purchases.landedCost')}</th><th className="px-3 py-2 text-right">{t('common.total')}</th></tr></thead>
              <tbody className="divide-y divide-gray-100 dark:divide-gray-800">
                {p.purchase_lines.map((l: any) => (
                  <tr key={l.id}>
                    <td className="px-3 py-2"><Link to={`/app/products/${l.product_id}`} className="font-semibold hover:underline">{l.products?.name}</Link>{Number(l.qty_returned) > 0 && <p className="text-xs text-amber-700">{t('purchases.returnedQty', { n: formatNumber(l.qty_returned, lang), unit: l.products?.base_unit })}</p>}</td>
                    <td className="px-3 py-2 text-right tabular-nums">{formatNumber(l.qty_ordered, lang)} {l.unit_name}</td>
                    <td className="px-3 py-2 text-right tabular-nums">{formatNumber(l.qty_received, lang)}</td>
                    <td className="px-3 py-2 text-right tabular-nums">{money(l.unit_cost)}</td>
                    <td className="px-3 py-2 text-right tabular-nums text-ink-muted">{l.landed_unit_cost_base ? `${money(l.landed_unit_cost_base)}/${l.products?.base_unit}` : '—'}</td>
                    <td className="px-3 py-2 text-right font-semibold tabular-nums">{money(l.line_total)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
          <p className="mt-3 text-xs text-ink-muted">{t('purchases.landedExplain')}</p>
        </Card>
        <Card>
          <CardHeader title={t('purchases.summary')} />
          <dl className="space-y-2 text-sm">
            <Row label={t('common.subtotal')} value={money(p.subtotal)} />
            {Number(p.transport_cost) > 0 && <Row label={t('purchases.transport')} value={money(p.transport_cost)} />}
            {Number(p.other_costs) > 0 && <Row label={t('purchases.otherCosts')} value={money(p.other_costs)} />}
            {Number(p.discount_amount) > 0 && <Row label={t('purchases.invoiceDiscount')} value={`- ${money(p.discount_amount)}`} />}
            <Row label={t('common.total')} value={money(p.total)} bold />
            {Number(p.credited_total) > 0 && <Row label={t('purchases.credits')} value={`- ${money(p.credited_total)}`} />}
            <Row label={t('common.paid')} value={money(p.paid_total)} />
            <Row label={t('purchases.outstanding')} value={<span className={owed > 0 ? 'text-red-600' : 'text-brand-700'}>{money(owed)}</span>} bold />
          </dl>
          <div className="mt-4 border-t border-gray-100 pt-3 dark:border-gray-800">
            <KeyValue items={[
              { label: t('common.dueDate'), value: p.due_date ? formatDate(p.due_date, lang) : '—' },
              { label: t('purchases.expectedDate'), value: p.expected_date ? formatDate(p.expected_date, lang) : '—' },
              { label: t('purchases.supplier'), value: <Link to={`/app/suppliers/${p.supplier_id}`} className="hover:underline">{p.suppliers?.name}</Link> },
              { label: t('purchases.firstReceived'), value: p.first_received_at ? formatDate(p.first_received_at, lang) : '—' },
            ]} />
          </div>
          {p.notes && <p className="mt-3 whitespace-pre-line text-sm text-ink-muted">{p.notes}</p>}
        </Card>
      </div>

      <div className="mt-4 grid gap-4 lg:grid-cols-3">
        <Card>
          <CardHeader title={t('purchases.receipts')} />
          {receipts.length === 0 ? <p className="text-sm text-ink-muted">{t('purchases.noReceipts')}</p> : (
            <ul className="space-y-3 text-sm">{receipts.map((r) => (
              <li key={r.id}><p className="font-semibold">{r.number} · {formatDateTime(r.received_at, lang)}</p>
                <ul className="text-xs text-ink-muted">{r.purchase_receipt_lines.map((l: any) => <li key={l.id}>{l.products?.name}: +{formatNumber(l.base_quantity, lang)}</li>)}</ul></li>))}</ul>
          )}
        </Card>
        <Card>
          <CardHeader title={t('purchases.paymentsCredits')} />
          {allocs.length === 0 && credits.length === 0 ? <p className="text-sm text-ink-muted">{t('purchases.noPayments')}</p> : (
            <ul className="space-y-2 text-sm">
              {allocs.map((a, i) => <li key={i} className="flex justify-between gap-2"><span>{formatDate(a.payments?.paid_at, lang)} · {t(`methods.${a.payments?.method}`)}{a.payments?.reference ? ` · ${a.payments.reference}` : ''}</span><span className="font-semibold">{money(a.amount)}</span></li>)}
              {credits.map((c) => <li key={c.id} className="flex justify-between gap-2 text-amber-800"><span>{t(`purchases.creditKind.${c.kind}`)} · {c.reason}</span><span className="font-semibold">- {money(c.amount)}</span></li>)}
            </ul>
          )}
        </Card>
        <Card>
          <CardHeader title={t('purchases.attachments')} action={<label className="inline-flex cursor-pointer items-center gap-1 text-sm font-semibold text-brand-700 no-print"><Paperclip className="h-4 w-4" />{t('common.upload')}<input type="file" accept="image/*,application/pdf" className="sr-only" onChange={(e) => onFile(e.target.files?.[0])} /></label>} />
          {(files.data ?? []).length === 0 ? <p className="text-sm text-ink-muted">{t('purchases.noAttachments')}</p> : (
            <ul className="space-y-1 text-sm">{(files.data ?? []).map((f) => <li key={f.id}><button className="text-brand-700 hover:underline" onClick={() => openFile(f.path)}>{f.file_name}</button></li>)}</ul>
          )}
        </Card>
      </div>

      {dialog === 'receive' && <ReceiveModal p={p} onClose={() => setDialog(null)} />}
      {dialog === 'pay' && <PayModal p={p} owed={owed} onClose={() => setDialog(null)} />}
      {dialog === 'return' && <ReturnModal p={p} onClose={() => setDialog(null)} />}
      {(dialog === 'short' || dialog === 'cancel') && <ReasonModal kind={dialog} p={p} onClose={() => setDialog(null)} />}
    </div>
  );
}

function Row({ label, value, bold }: { label: string; value: React.ReactNode; bold?: boolean }) {
  return <div className={`flex justify-between gap-3 ${bold ? 'font-bold' : ''}`}><dt>{label}</dt><dd className="tabular-nums">{value}</dd></div>;
}

function ReceiveModal({ p, onClose }: { p: any; onClose: () => void }) {
  const { t, lang } = useI18n();
  const { run, busy } = useAction();
  const [ref] = useState(newId);
  const [q, setQ] = useState<Record<string, { qty: string; batch: string; expiry: string }>>(() => Object.fromEntries(p.purchase_lines.map((l: any) => [l.id, { qty: String(Number(l.qty_ordered) - Number(l.qty_received)), batch: '', expiry: '' }])));
  const submit = async () => {
    const ok = await run(() => rpc('receive_purchase', { p_purchase: p.id, p_client_ref: ref, p_lines: p.purchase_lines.map((l: any) => ({ line_id: l.id, quantity: toNumber(q[l.id].qty), batch_code: q[l.id].batch || null, expiry_date: q[l.id].expiry || null })).filter((x: any) => x.quantity > 0) }), t('purchases.received_ok'));
    if (ok !== undefined) onClose();
  };
  return (
    <Modal open onClose={onClose} title={t('purchases.receiveGoods')} size="lg" footer={<><Button variant="outline" onClick={onClose}>{t('common.cancel')}</Button><Button loading={busy} onClick={submit}>{t('purchases.confirmReceipt')}</Button></>}>
      <p className="mb-3 text-sm text-ink-muted">{t('purchases.receiveHelp')}</p>
      <div className="space-y-3">
        {p.purchase_lines.map((l: any) => {
          const remaining = Number(l.qty_ordered) - Number(l.qty_received);
          return (
            <div key={l.id} className="rounded-xl border border-gray-200 p-3 dark:border-gray-800">
              <div className="flex flex-wrap items-center justify-between gap-2">
                <p className="font-semibold">{l.products?.name}</p>
                <p className="text-xs text-ink-muted">{t('purchases.remainingToReceive', { n: formatNumber(remaining, lang), unit: l.unit_name })}</p>
              </div>
              <div className="mt-2 grid grid-cols-3 gap-3">
                <Field label={`${t('purchases.receivedNow')} (${l.unit_name})`}><Input type="number" min="0" max={remaining} step="any" disabled={remaining <= 0} value={q[l.id].qty} onChange={(e) => setQ((x) => ({ ...x, [l.id]: { ...x[l.id], qty: e.target.value } }))} /></Field>
                {l.products?.track_expiry && <>
                  <Field label={t('inventory.batchCode')}><Input value={q[l.id].batch} onChange={(e) => setQ((x) => ({ ...x, [l.id]: { ...x[l.id], batch: e.target.value } }))} /></Field>
                  <Field label={t('inventory.expiryDate')}><Input type="date" value={q[l.id].expiry} onChange={(e) => setQ((x) => ({ ...x, [l.id]: { ...x[l.id], expiry: e.target.value } }))} /></Field>
                </>}
              </div>
            </div>
          );
        })}
      </div>
    </Modal>
  );
}

function PayModal({ p, owed, onClose }: { p: any; owed: number; onClose: () => void }) {
  const { t } = useI18n();
  const { id } = useBiz();
  const { run, busy } = useAction();
  const [ref] = useState(newId);
  const [f, setF] = useState({ amount: String(owed), method: 'cash', reference: '', notes: '' });
  const submit = async () => {
    const ok = await run(() => rpc('record_supplier_payment', { p_business: id, p_supplier: p.supplier_id, p_amount: toNumber(f.amount), p_method: f.method,
      p_reference: f.reference || null, p_purchase: p.id, p_notes: f.notes || null, p_client_ref: ref }), t('purchases.paymentRecorded'));
    if (ok !== undefined) onClose();
  };
  return (
    <Modal open onClose={onClose} title={t('purchases.recordPayment')} size="sm" footer={<><Button variant="outline" onClick={onClose}>{t('common.cancel')}</Button><Button loading={busy} disabled={!(toNumber(f.amount) > 0)} onClick={submit}>{t('common.save')}</Button></>}>
      <div className="space-y-3">
        <Field label={t('common.amount')}><Input type="number" min="0" step="any" value={f.amount} onChange={(e) => setF({ ...f, amount: e.target.value })} suffix="FCFA" /></Field>
        <Field label={t('common.method')}><Select value={f.method} onChange={(e) => setF({ ...f, method: e.target.value })}>{METHODS.map((m) => <option key={m} value={m}>{t(`methods.${m}`)}</option>)}</Select></Field>
        <Field label={t('common.reference')}><Input value={f.reference} onChange={(e) => setF({ ...f, reference: e.target.value })} /></Field>
        <Field label={t('common.notes')}><Input value={f.notes} onChange={(e) => setF({ ...f, notes: e.target.value })} /></Field>
        {toNumber(f.amount) > owed && <Alert tone="blue">{t('purchases.extraAllocated')}</Alert>}
      </div>
    </Modal>
  );
}

function ReturnModal({ p, onClose }: { p: any; onClose: () => void }) {
  const { t, lang } = useI18n();
  const { run, busy } = useAction();
  const [ref] = useState(newId);
  const [reason, setReason] = useState('');
  const [q, setQ] = useState<Record<string, string>>({});
  const lines = p.purchase_lines.filter((l: any) => Number(l.qty_received) > 0);
  const submit = async () => {
    const ok = await run(() => rpc('return_to_supplier', { p_purchase: p.id, p_reason: reason, p_client_ref: ref,
      p_lines: lines.map((l: any) => ({ line_id: l.id, base_quantity: toNumber(q[l.id]) })).filter((x: any) => x.base_quantity > 0) }), t('purchases.returnRecorded'));
    if (ok !== undefined) onClose();
  };
  return (
    <Modal open onClose={onClose} title={t('purchases.returnToSupplier')} size="lg" footer={<><Button variant="outline" onClick={onClose}>{t('common.cancel')}</Button><Button loading={busy} disabled={!reason.trim() || !Object.values(q).some((v) => toNumber(v) > 0)} onClick={submit}>{t('common.confirm')}</Button></>}>
      <p className="mb-3 text-sm text-ink-muted">{t('purchases.returnHelp')}</p>
      <div className="space-y-3">
        {lines.map((l: any) => {
          const max = Number(l.qty_received) * Number(l.unit_factor) - Number(l.qty_returned);
          return (
            <div key={l.id} className="grid grid-cols-2 items-end gap-3">
              <div><p className="font-semibold">{l.products?.name}</p><p className="text-xs text-ink-muted">{t('purchases.maxReturn', { n: formatNumber(max, lang), unit: l.products?.base_unit })}</p></div>
              <Field label={`${t('common.qty')} (${l.products?.base_unit})`}><Input type="number" min="0" max={max} step="any" value={q[l.id] ?? ''} onChange={(e) => setQ((x) => ({ ...x, [l.id]: e.target.value }))} /></Field>
            </div>
          );
        })}
        <Field label={t('common.reason')} required><Textarea rows={2} value={reason} onChange={(e) => setReason(e.target.value)} /></Field>
      </div>
    </Modal>
  );
}

function ReasonModal({ kind, p, onClose }: { kind: 'short' | 'cancel'; p: any; onClose: () => void }) {
  const { t } = useI18n();
  const { run, busy } = useAction();
  const [reason, setReason] = useState('');
  const submit = async () => {
    const ok = await run(() => rpc(kind === 'short' ? 'close_purchase_short' : 'cancel_purchase', { p_purchase: p.id, p_reason: reason }), t('common.saved'));
    if (ok !== undefined) onClose();
  };
  return (
    <Modal open onClose={onClose} title={kind === 'short' ? t('purchases.closeShort') : t('purchases.cancelPurchase')} size="sm"
      footer={<><Button variant="outline" onClick={onClose}>{t('common.back')}</Button><Button variant={kind === 'cancel' ? 'danger' : 'primary'} loading={busy} disabled={!reason.trim()} onClick={submit}>{t('common.confirm')}</Button></>}>
      <p className="mb-3 text-sm text-ink-muted">{kind === 'short' ? t('purchases.closeShortHelp') : t('purchases.cancelHelp')}</p>
      <Field label={t('common.reason')} required><Textarea rows={2} value={reason} onChange={(e) => setReason(e.target.value)} /></Field>
    </Modal>
  );
}
