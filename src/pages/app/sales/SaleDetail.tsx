import { useEffect, useState } from 'react';
import { Link, useParams, useSearchParams } from 'react-router-dom';
import { useQuery } from '@tanstack/react-query';
import { ArrowLeft, CreditCard, Printer, Undo2 } from 'lucide-react';
import { useI18n } from '../../../i18n';
import { useBiz } from '../../../lib/business';
import { supabase } from '../../../lib/supabase';
import { rpc, unwrap } from '../../../lib/api';
import { useAction } from '../../../lib/useAction';
import { useBusinessRow, useSettings } from '../../../lib/hooks';
import { newId } from '../../../lib/ids';
import { formatDateTime, formatNumber, toNumber } from '../../../lib/format';
import { Alert, Badge, Button, Card, CardHeader, Checkbox, ErrorState, Field, Input, KeyValue, Modal, PageHeader, PageLoader, Select, Textarea, useMoney } from '../../../components/ui';
import { Receipt } from './Receipt';
import { saleStatus } from './SalesPage';

const METHODS = ['cash', 'mtn_momo', 'orange_money', 'bank_transfer', 'card', 'other'];

export default function SaleDetail() {
  const { id: sid } = useParams();
  const [params] = useSearchParams();
  const { t, lang } = useI18n();
  const { id, can } = useBiz();
  const money = useMoney();
  const business = useBusinessRow(id);
  const settings = useSettings(id);
  const [dialog, setDialog] = useState<null | 'return' | 'pay'>(null);
  const q = useQuery({
    queryKey: ['sale', sid],
    queryFn: async () => {
      const s = unwrap(await supabase.from('sales').select('*, customers(id,name,phone), sale_lines(*, products(name,base_unit))').eq('id', sid!).single()) as any;
      s.sale_lines.sort((a: any, b: any) => a.sort - b.sort);
      const [payments, returns] = await Promise.all([
        supabase.from('payments').select('*').eq('sale_id', sid!).order('paid_at'),
        supabase.from('sale_returns').select('*, sale_return_lines(*, products(name))').eq('sale_id', sid!).order('returned_at'),
      ]);
      return { s, payments: unwrap(payments) as any[], returns: unwrap(returns) as any[] };
    },
  });
  useEffect(() => {
    if (params.get('print') && q.data && business.data) setTimeout(() => window.print(), 400);
  }, [params, q.data, business.data]);
  if (q.isLoading || business.isLoading) return <PageLoader />;
  if (q.error) return <ErrorState error={q.error} />;
  const { s, payments, returns } = q.data!;
  const st = saleStatus(s);
  const gp = Number(s.total) - Number(s.tax_total) - Number(s.cost_total);
  const returnable = s.sale_lines.some((l: any) => Number(l.returned_base_qty) < Number(l.base_quantity));
  return (
    <div>
      <div className="no-print">
        <PageHeader back={<Link to="/app/sales" className="mb-2 inline-flex items-center gap-1 text-sm text-ink-muted hover:text-ink"><ArrowLeft className="h-4 w-4" />{t('nav.sales')}</Link>}
          title={<span className="flex items-center gap-3">{s.number}<Badge tone={st.tone}>{t(`sales.status.${st.key}`)}</Badge>{s.offline && <Badge tone="gray">{t('offline.badge')}</Badge>}</span>}
          subtitle={formatDateTime(s.sold_at, lang)}
          actions={<>
            <Button variant="outline" icon={<Printer className="h-4 w-4" />} onClick={() => window.print()}>{t('pos.printReceipt')}</Button>
            {can('sales.refund') && returnable && <Button variant="outline" icon={<Undo2 className="h-4 w-4" />} onClick={() => setDialog('return')}>{t('sales.returnRefund')}</Button>}
            {st.owed > 0 && s.customer_id && <Button icon={<CreditCard className="h-4 w-4" />} onClick={() => setDialog('pay')}>{t('parties.receivePayment')}</Button>}
          </>} />
        <div className="grid gap-4 lg:grid-cols-3">
          <Card className="lg:col-span-2">
            <CardHeader title={t('nav.products')} />
            <div className="-mx-4 overflow-x-auto sm:mx-0">
              <table className="min-w-full text-sm">
                <thead><tr className="text-left text-xs uppercase text-ink-muted"><th className="px-3 py-2">{t('dashboard.product')}</th><th className="px-3 py-2 text-right">{t('common.qty')}</th><th className="px-3 py-2 text-right">{t('common.price')}</th><th className="px-3 py-2 text-right">{t('sales.discounts')}</th><th className="px-3 py-2 text-right">{t('common.amount')}</th>{can('reports.view') && <th className="px-3 py-2 text-right">{t('common.cost')}</th>}</tr></thead>
                <tbody className="divide-y divide-gray-100 dark:divide-gray-800">
                  {s.sale_lines.map((l: any) => (
                    <tr key={l.id}>
                      <td className="px-3 py-2"><Link to={`/app/products/${l.product_id}`} className="font-semibold hover:underline">{l.products?.name}</Link>{Number(l.returned_base_qty) > 0 && <p className="text-xs text-amber-700">{t('sales.returnedQty', { n: formatNumber(l.returned_base_qty, lang), unit: l.products?.base_unit })}</p>}</td>
                      <td className="px-3 py-2 text-right tabular-nums">{formatNumber(l.quantity, lang)} {l.unit_name}</td>
                      <td className="px-3 py-2 text-right tabular-nums">{money(l.unit_price)}</td>
                      <td className="px-3 py-2 text-right tabular-nums">{Number(l.line_discount) + Number(l.sale_discount_alloc) > 0 ? money(Number(l.line_discount) + Number(l.sale_discount_alloc)) : '—'}</td>
                      <td className="px-3 py-2 text-right font-semibold tabular-nums">{money(l.net_amount)}</td>
                      {can('reports.view') && <td className="px-3 py-2 text-right tabular-nums text-ink-muted">{money(l.cost_amount)}</td>}
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          </Card>
          <Card>
            <CardHeader title={t('purchases.summary')} />
            <KeyValue items={[
              { label: t('common.total'), value: money(s.total) }, { label: t('common.paid'), value: money(s.paid_total) },
              { label: t('sales.returned'), value: money(s.returned_total) }, { label: t('sales.refunded'), value: money(s.refunded_total) },
              { label: t('sales.outstanding'), value: <span className={st.owed > 0 ? 'text-amber-700' : ''}>{money(st.owed)}</span> },
              { label: t('pos.customer'), value: s.customers ? <Link className="hover:underline" to={`/app/customers/${s.customers.id}`}>{s.customers.name}</Link> : t('common.walkIn') },
              ...(can('reports.view') ? [{ label: t('dashboard.grossProfit'), value: money(gp) }] : []),
              ...(Number(s.tax_total) > 0 ? [{ label: t('sales.taxIncluded'), value: money(s.tax_total) }] : []),
            ]} />
            {s.due_date && st.owed > 0 && <p className="mt-3 text-sm">{t('common.dueDate')}: <b>{s.due_date}</b></p>}
            {s.notes && <p className="mt-3 text-sm text-ink-muted">{s.notes}</p>}
          </Card>
        </div>
        <div className="mt-4 grid gap-4 lg:grid-cols-2">
          <Card>
            <CardHeader title={t('sales.payments')} />
            {payments.length === 0 ? <p className="text-sm text-ink-muted">{t('sales.noPayments')}</p> : (
              <ul className="space-y-2 text-sm">{payments.map((p) => <li key={p.id} className="flex justify-between gap-2"><span>{formatDateTime(p.paid_at, lang)} · {t(`paymentKinds.${p.kind}`)} · {t(`methods.${p.method}`)}{p.reference ? ` · ${p.reference}` : ''}</span><span className={p.direction === 'out' ? 'text-red-600' : 'font-semibold'}>{p.direction === 'out' ? '− ' : ''}{money(p.amount)}</span></li>)}</ul>
            )}
          </Card>
          <Card>
            <CardHeader title={t('sales.returns')} />
            {returns.length === 0 ? <p className="text-sm text-ink-muted">{t('sales.noReturns')}</p> : (
              <ul className="space-y-3 text-sm">{returns.map((r) => (
                <li key={r.id}><p className="font-semibold">{r.number} · {formatDateTime(r.returned_at, lang)} · {money(r.total)}{!r.restock && <Badge tone="amber" className="ml-1">{t('sales.notRestocked')}</Badge>}</p>
                  <p className="text-xs text-ink-muted">{r.reason}{Number(r.refund_amount) > 0 ? ` · ${t('sales.refundedAmount', { amount: money(r.refund_amount) })}` : ''}</p>
                  <ul className="text-xs text-ink-muted">{r.sale_return_lines.map((l: any) => <li key={l.id}>{l.products?.name}: {formatNumber(l.base_quantity, lang)}</li>)}</ul></li>))}</ul>
            )}
          </Card>
        </div>
      </div>
      <div className="print-only">{business.data && <Receipt sale={s} business={business.data} settings={settings.data} payments={payments} />}</div>
      <div className="no-print mt-6 hidden lg:block"><CardHeader title={t('receipt.preview')} />{business.data && <div className="rounded-2xl border border-gray-200 bg-white p-2 shadow-card"><Receipt sale={s} business={business.data} settings={settings.data} payments={payments} /></div>}</div>
      {dialog === 'return' && <ReturnModal sale={s} onClose={() => setDialog(null)} />}
      {dialog === 'pay' && <SalePayModal sale={s} owed={st.owed} onClose={() => setDialog(null)} />}
    </div>
  );
}

function ReturnModal({ sale, onClose }: { sale: any; onClose: () => void }) {
  const { t, lang } = useI18n();
  const money = useMoney();
  const { run, busy } = useAction();
  const [ref] = useState(newId);
  const [qty, setQty] = useState<Record<string, string>>({});
  const [reason, setReason] = useState('');
  const [restock, setRestock] = useState(true);
  const [method, setMethod] = useState('cash');
  const [refund, setRefund] = useState('');
  const value = sale.sale_lines.reduce((a: number, l: any) => a + Math.round(Number(l.net_amount) * toNumber(qty[l.id]) / Number(l.base_quantity)), 0);
  const available = Number(sale.paid_total) - (Number(sale.total) - (Number(sale.returned_total) + value) + Number(sale.refunded_total));
  const maxRefund = Math.max(0, Math.min(value, available));
  const walkIn = !sale.customer_id;
  const submit = async () => {
    const ok = await run(() => rpc('create_sale_return', { p_sale: sale.id, p: { client_ref: ref, reason, restock,
      lines: sale.sale_lines.map((l: any) => ({ sale_line_id: l.id, base_quantity: toNumber(qty[l.id]) })).filter((x: any) => x.base_quantity > 0),
      refund: { method, amount: walkIn ? value : toNumber(refund) } } }), t('sales.returnRecorded'));
    if (ok !== undefined) onClose();
  };
  return (
    <Modal open onClose={onClose} title={t('sales.returnRefund')} size="lg" footer={<><Button variant="outline" onClick={onClose}>{t('common.cancel')}</Button><Button loading={busy} disabled={!reason.trim() || value <= 0} onClick={submit}>{t('common.confirm')}</Button></>}>
      <div className="space-y-3">
        {sale.sale_lines.map((l: any) => {
          const max = Number(l.base_quantity) - Number(l.returned_base_qty);
          return (
            <div key={l.id} className="grid grid-cols-2 items-end gap-3">
              <div><p className="font-semibold">{l.products?.name}</p><p className="text-xs text-ink-muted">{t('sales.maxReturn', { n: formatNumber(max, lang), unit: l.products?.base_unit })}</p></div>
              <Field label={`${t('common.qty')} (${l.products?.base_unit})`}><Input type="number" min="0" max={max} step="any" disabled={max <= 0} value={qty[l.id] ?? ''} onChange={(e) => setQty((x) => ({ ...x, [l.id]: e.target.value }))} /></Field>
            </div>
          );
        })}
        <Checkbox checked={restock} onChange={setRestock} label={t('sales.restock')} hint={t('sales.restockHint')} />
        <Field label={t('common.reason')} required><Textarea rows={2} value={reason} onChange={(e) => setReason(e.target.value)} /></Field>
        <div className="rounded-xl bg-gray-50 p-3 text-sm dark:bg-gray-800/60">
          <p>{t('sales.returnValue')}: <b>{money(value)}</b></p>
          {walkIn ? <p className="mt-1 text-ink-muted">{t('sales.walkInRefund')}</p> : <p className="mt-1 text-ink-muted">{t('sales.customerRefundHelp', { max: money(maxRefund) })}</p>}
        </div>
        <div className="grid grid-cols-2 gap-3">
          {!walkIn && <Field label={t('sales.refundAmount')}><Input type="number" min="0" max={maxRefund} step="any" value={refund} onChange={(e) => setRefund(e.target.value)} suffix="FCFA" /></Field>}
          <Field label={t('sales.refundMethod')}><Select value={method} onChange={(e) => setMethod(e.target.value)}>{METHODS.map((m) => <option key={m} value={m}>{t(`methods.${m}`)}</option>)}</Select></Field>
        </div>
        {!walkIn && toNumber(refund) > maxRefund && <Alert tone="red">{t('errors.invalid_refund_amount', { max: money(maxRefund) })}</Alert>}
      </div>
    </Modal>
  );
}

function SalePayModal({ sale, owed, onClose }: { sale: any; owed: number; onClose: () => void }) {
  const { t } = useI18n();
  const { id } = useBiz();
  const { run, busy } = useAction();
  const [ref] = useState(newId);
  const [f, setF] = useState({ amount: String(owed), method: 'cash', reference: '' });
  const submit = async () => {
    const ok = await run(() => rpc('record_customer_payment', { p_business: id, p_customer: sale.customer_id, p_amount: toNumber(f.amount), p_method: f.method,
      p_reference: f.reference || null, p_sale: sale.id, p_client_ref: ref }), t('common.saved'));
    if (ok !== undefined) onClose();
  };
  return (
    <Modal open onClose={onClose} title={t('parties.receivePayment')} size="sm" footer={<><Button variant="outline" onClick={onClose}>{t('common.cancel')}</Button><Button loading={busy} disabled={!(toNumber(f.amount) > 0)} onClick={submit}>{t('common.save')}</Button></>}>
      <div className="space-y-3">
        <Field label={t('common.amount')}><Input type="number" min="0" step="any" value={f.amount} onChange={(e) => setF({ ...f, amount: e.target.value })} suffix="FCFA" /></Field>
        <Field label={t('common.method')}><Select value={f.method} onChange={(e) => setF({ ...f, method: e.target.value })}>{METHODS.map((m) => <option key={m} value={m}>{t(`methods.${m}`)}</option>)}</Select></Field>
        <Field label={t('common.reference')}><Input value={f.reference} onChange={(e) => setF({ ...f, reference: e.target.value })} /></Field>
      </div>
    </Modal>
  );
}
