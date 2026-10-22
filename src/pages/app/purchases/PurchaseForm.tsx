import { useEffect, useMemo, useState } from 'react';
import { Link, useNavigate, useParams } from 'react-router-dom';
import { useQuery } from '@tanstack/react-query';
import { ArrowLeft, Plus, Trash2 } from 'lucide-react';
import { useI18n } from '../../../i18n';
import { useBiz } from '../../../lib/business';
import { supabase } from '../../../lib/supabase';
import { rpc, unwrap } from '../../../lib/api';
import { Product, useSuppliers } from '../../../lib/hooks';
import { useAction } from '../../../lib/useAction';
import { newId } from '../../../lib/ids';
import { localToday } from '../../../lib/dates';
import { formatMoney, toNumber } from '../../../lib/format';
import { Alert, Button, Card, CardHeader, ErrorState, Field, Input, Modal, PageHeader, PageLoader, Select, Textarea, UpgradeNotice, useMoney } from '../../../components/ui';
import { ProductPicker } from '../../../components/ProductPicker';

interface Line { key: string; product: Pick<Product, 'id' | 'name' | 'base_unit' | 'track_expiry'> & { product_units?: any[] }; unit_id: string; quantity: string; unit_cost: string; discount: string; tax: string; batch: string; expiry: string }

const METHODS = ['cash', 'mtn_momo', 'orange_money', 'bank_transfer', 'other'];

export default function PurchaseForm() {
  const { id: purchaseId } = useParams();
  const editing = Boolean(purchaseId);
  const { t, lang } = useI18n();
  const { id, has, biz } = useBiz();
  const money = useMoney();
  const nav = useNavigate();
  const { run, busy } = useAction();
  const sups = useSuppliers(id, has('suppliers'));
  const [h, setH] = useState({ supplier_id: '', invoice_number: '', purchase_date: localToday(biz.timezone), expected_date: '', due_date: '', transport_cost: '', other_costs: '', discount_amount: '', notes: '' });
  const [lines, setLines] = useState<Line[]>([]);
  const [pay, setPay] = useState({ amount: '', method: 'cash', reference: '' });
  const [clientRef] = useState(newId);
  const [payRef] = useState(newId);
  const [newSup, setNewSup] = useState<{ name: string; phone: string } | null>(null);

  const existing = useQuery({
    queryKey: ['purchase-edit', purchaseId], enabled: editing,
    queryFn: async () => unwrap(await supabase.from('purchases').select('*, purchase_lines(*, products(id,name,base_unit,track_expiry,product_units(*)))').eq('id', purchaseId!).single()) as any,
  });
  useEffect(() => {
    const p = existing.data;
    if (!p) return;
    setH({ supplier_id: p.supplier_id, invoice_number: p.invoice_number ?? '', purchase_date: p.purchase_date, expected_date: p.expected_date ?? '', due_date: p.due_date ?? '',
      transport_cost: String(p.transport_cost || ''), other_costs: String(p.other_costs || ''), discount_amount: String(p.discount_amount || ''), notes: p.notes ?? '' });
    setLines((p.purchase_lines ?? []).sort((a: any, b: any) => a.sort - b.sort).map((l: any) => ({ key: l.id, product: l.products, unit_id: l.unit_id ?? '', quantity: String(l.qty_ordered),
      unit_cost: String(l.unit_cost), discount: String(l.discount_amount || ''), tax: String(l.tax_amount || ''), batch: '', expiry: '' })));
  }, [existing.data]);

  const totals = useMemo(() => {
    const sub = lines.reduce((a, l) => a + Math.round(toNumber(l.quantity) * toNumber(l.unit_cost) - toNumber(l.discount) + toNumber(l.tax)), 0);
    return { sub, total: sub + toNumber(h.transport_cost) + toNumber(h.other_costs) - toNumber(h.discount_amount) };
  }, [lines, h]);

  if (!has('purchases')) return <UpgradeNotice feature="purchases" />;
  if (editing && existing.isLoading) return <PageLoader />;
  if (editing && existing.error) return <ErrorState error={existing.error} />;

  const addProduct = (p: Product) => {
    const def = (p.product_units ?? []).find((u) => u.is_default_purchase && u.active);
    setLines((ls) => [...ls, { key: newId(), product: p, unit_id: def?.id ?? '', quantity: '1',
      unit_cost: String(Math.round(Number(p.purchase_cost || p.avg_cost || 0) * (def ? Number(def.factor) : 1))), discount: '', tax: '', batch: '', expiry: '' }]);
  };
  const setLine = (key: string, patch: Partial<Line>) => setLines((ls) => ls.map((l) => (l.key === key ? { ...l, ...patch } : l)));
  const save = async (status: 'draft' | 'ordered', receiveNow: boolean) => {
    const pid = await run(() => rpc<string>('save_purchase', { p_business: id, p: {
      id: purchaseId ?? null, client_ref: editing ? null : clientRef, status, receive_now: receiveNow, ...h,
      transport_cost: toNumber(h.transport_cost), other_costs: toNumber(h.other_costs), discount_amount: toNumber(h.discount_amount),
      lines: lines.map((l) => ({ product_id: l.product.id, unit_id: l.unit_id || null, quantity: toNumber(l.quantity), unit_cost: toNumber(l.unit_cost),
        discount_amount: toNumber(l.discount), tax_amount: toNumber(l.tax), batch_code: l.batch || null, expiry_date: l.expiry || null })),
      payment: status === 'ordered' && toNumber(pay.amount) > 0 ? { ...pay, amount: toNumber(pay.amount), client_ref: payRef } : null,
    } }), receiveNow ? t('purchases.savedReceived') : t('common.saved'));
    if (pid) nav(`/app/purchases/${pid}`, { replace: true });
  };
  const createSupplier = async () => {
    if (!newSup?.name.trim()) return;
    const s = await run(async () => unwrap(await supabase.from('suppliers').insert({ business_id: id, name: newSup.name.trim(), phone: newSup.phone || null }).select('id').single()) as { id: string });
    if (s) { setH((x) => ({ ...x, supplier_id: s.id })); setNewSup(null); }
  };
  const valid = h.supplier_id && lines.length > 0 && lines.every((l) => toNumber(l.quantity) > 0 && toNumber(l.unit_cost) >= 0) && totals.total >= 0;
  const set = (k: keyof typeof h) => (e: { target: { value: string } }) => setH((x) => ({ ...x, [k]: e.target.value }));

  return (
    <div>
      <PageHeader title={editing ? t('purchases.editTitle') : t('nav.newPurchase')} subtitle={t('purchases.formSubtitle')}
        back={<Link to={editing ? `/app/purchases/${purchaseId}` : '/app/purchases'} className="mb-2 inline-flex items-center gap-1 text-sm text-ink-muted hover:text-ink"><ArrowLeft className="h-4 w-4" />{t('common.back')}</Link>} />
      <div className="grid gap-4 lg:grid-cols-3">
        <div className="space-y-4 lg:col-span-2">
          <Card>
            <div className="grid gap-4 sm:grid-cols-2">
              <Field label={t('purchases.supplier')} required>
                <div className="flex gap-2">
                  <Select value={h.supplier_id} onChange={set('supplier_id')} className="flex-1"><option value="">{t('purchases.selectSupplier')}</option>{(sups.data ?? []).filter((s) => s.status === 'active' || s.id === h.supplier_id).map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}</Select>
                  <Button variant="outline" onClick={() => setNewSup({ name: '', phone: '' })} aria-label={t('nav.addSupplier')}><Plus className="h-4 w-4" /></Button>
                </div>
              </Field>
              <Field label={t('purchases.invoiceNumber')}><Input value={h.invoice_number} onChange={set('invoice_number')} placeholder={t('purchases.invoicePlaceholder')} /></Field>
              <Field label={t('purchases.purchaseDate')}><Input type="date" value={h.purchase_date} onChange={set('purchase_date')} /></Field>
              <Field label={t('purchases.expectedDate')}><Input type="date" value={h.expected_date} onChange={set('expected_date')} /></Field>
              <Field label={t('common.dueDate')} hint={t('purchases.dueHint')}><Input type="date" value={h.due_date} onChange={set('due_date')} /></Field>
            </div>
          </Card>
          <Card>
            <CardHeader title={t('nav.products')} subtitle={t('purchases.linesHint')} />
            <ProductPicker businessId={id} showCost onPick={addProduct} placeholder={t('purchases.addProduct')} />
            <div className="mt-4 space-y-3">
              {lines.length === 0 && <p className="py-6 text-center text-sm text-ink-muted">{t('purchases.noLines')}</p>}
              {lines.map((l) => {
                const units = (l.product.product_units ?? []).filter((u: any) => u.active);
                const unit = units.find((u: any) => u.id === l.unit_id);
                const lineTotal = Math.round(toNumber(l.quantity) * toNumber(l.unit_cost) - toNumber(l.discount) + toNumber(l.tax));
                return (
                  <div key={l.key} className="rounded-xl border border-gray-200 p-3 dark:border-gray-800">
                    <div className="mb-2 flex items-start justify-between gap-2">
                      <p className="font-semibold">{l.product.name}</p>
                      <button onClick={() => setLines((ls) => ls.filter((x) => x.key !== l.key))} className="text-gray-400 hover:text-red-600" aria-label={t('common.delete')}><Trash2 className="h-4 w-4" /></button>
                    </div>
                    <div className="grid grid-cols-2 gap-3 sm:grid-cols-5">
                      <Field label={t('purchases.unit')}>
                        <Select value={l.unit_id} onChange={(e) => setLine(l.key, { unit_id: e.target.value })}>
                          <option value="">{l.product.base_unit}</option>
                          {units.map((u: any) => <option key={u.id} value={u.id}>{u.name} (×{Number(u.factor)})</option>)}
                        </Select>
                      </Field>
                      <Field label={t('common.qty')}><Input type="number" min="0" step="any" value={l.quantity} onChange={(e) => setLine(l.key, { quantity: e.target.value })} /></Field>
                      <Field label={t('purchases.costPerUnit', { unit: unit?.name ?? l.product.base_unit })}><Input type="number" min="0" step="any" value={l.unit_cost} onChange={(e) => setLine(l.key, { unit_cost: e.target.value })} /></Field>
                      <Field label={t('purchases.discount')}><Input type="number" min="0" step="any" value={l.discount} onChange={(e) => setLine(l.key, { discount: e.target.value })} /></Field>
                      <Field label={t('purchases.tax')}><Input type="number" min="0" step="any" value={l.tax} onChange={(e) => setLine(l.key, { tax: e.target.value })} /></Field>
                    </div>
                    {l.product.track_expiry && (
                      <div className="mt-3 grid grid-cols-2 gap-3">
                        <Field label={t('inventory.batchCode')}><Input value={l.batch} onChange={(e) => setLine(l.key, { batch: e.target.value })} /></Field>
                        <Field label={t('inventory.expiryDate')}><Input type="date" value={l.expiry} onChange={(e) => setLine(l.key, { expiry: e.target.value })} /></Field>
                      </div>
                    )}
                    <p className="mt-2 text-right text-sm">{unit && <span className="mr-3 text-xs text-ink-muted">= {toNumber(l.quantity) * Number(unit.factor)} {l.product.base_unit}</span>}<b>{money(lineTotal)}</b></p>
                  </div>
                );
              })}
            </div>
          </Card>
          <Card><Field label={t('common.notes')}><Textarea rows={2} value={h.notes} onChange={set('notes')} /></Field></Card>
        </div>
        <div className="space-y-4">
          <Card>
            <CardHeader title={t('purchases.costs')} subtitle={t('purchases.costsHint')} />
            <div className="space-y-3">
              <Field label={t('purchases.transport')}><Input type="number" min="0" step="any" value={h.transport_cost} onChange={set('transport_cost')} suffix="FCFA" /></Field>
              <Field label={t('purchases.otherCosts')}><Input type="number" min="0" step="any" value={h.other_costs} onChange={set('other_costs')} suffix="FCFA" /></Field>
              <Field label={t('purchases.invoiceDiscount')}><Input type="number" min="0" step="any" value={h.discount_amount} onChange={set('discount_amount')} suffix="FCFA" /></Field>
            </div>
            <dl className="mt-4 space-y-1.5 border-t border-gray-100 pt-3 text-sm dark:border-gray-800">
              <div className="flex justify-between"><dt>{t('common.subtotal')}</dt><dd className="tabular-nums">{money(totals.sub)}</dd></div>
              <div className="flex justify-between text-lg font-extrabold"><dt>{t('purchases.totalAmount')}</dt><dd className="tabular-nums text-brand-700 dark:text-brand-400">{formatMoney(totals.total, lang)}</dd></div>
            </dl>
          </Card>
          {!editing || existing.data?.status === 'draft' ? (
            <Card>
              <CardHeader title={t('purchases.payNow')} subtitle={t('purchases.payNowHint')} />
              <div className="space-y-3">
                <Field label={t('common.amount')}><Input type="number" min="0" step="any" value={pay.amount} onChange={(e) => setPay((p) => ({ ...p, amount: e.target.value }))} suffix="FCFA" /></Field>
                <Field label={t('common.method')}><Select value={pay.method} onChange={(e) => setPay((p) => ({ ...p, method: e.target.value }))}>{METHODS.map((m) => <option key={m} value={m}>{t(`methods.${m}`)}</option>)}</Select></Field>
                <Field label={t('common.reference')}><Input value={pay.reference} onChange={(e) => setPay((p) => ({ ...p, reference: e.target.value }))} /></Field>
              </div>
            </Card>
          ) : null}
          <Card className="space-y-2">
            <Button block size="lg" loading={busy} disabled={!valid} onClick={() => save('ordered', true)}>{t('purchases.saveReceived')}</Button>
            <Button block variant="outline" loading={busy} disabled={!valid} onClick={() => save('ordered', false)}>{t('purchases.saveOrdered')}</Button>
            <Button block variant="ghost" loading={busy} disabled={!valid} onClick={() => save('draft', false)}>{t('purchases.saveDraft')}</Button>
            <p className="pt-1 text-xs text-ink-muted">{t('purchases.saveHelp')}</p>
            {toNumber(pay.amount) > totals.total && <Alert tone="amber">{t('purchases.overpayWarning')}</Alert>}
          </Card>
        </div>
      </div>
      <Modal open={Boolean(newSup)} onClose={() => setNewSup(null)} title={t('nav.addSupplier')} size="sm"
        footer={<><Button variant="outline" onClick={() => setNewSup(null)}>{t('common.cancel')}</Button><Button loading={busy} onClick={createSupplier}>{t('common.save')}</Button></>}>
        <div className="space-y-3">
          <Field label={t('common.name')} required><Input value={newSup?.name ?? ''} onChange={(e) => setNewSup((s) => ({ ...s!, name: e.target.value }))} /></Field>
          <Field label={t('common.phone')}><Input value={newSup?.phone ?? ''} onChange={(e) => setNewSup((s) => ({ ...s!, phone: e.target.value }))} /></Field>
        </div>
      </Modal>
    </div>
  );
}
