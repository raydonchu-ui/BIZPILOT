import { useEffect, useMemo, useState, type ComponentType } from 'react';
import { Link, useNavigate } from 'react-router-dom';
import { useQuery } from '@tanstack/react-query';
import clsx from 'clsx';
import { ArrowLeft, Banknote, CheckCircle2, CloudOff, Landmark, MessageCircle, Minus, MoreHorizontal, Phone, Plus, Printer, Smartphone, Store, Trash2, Truck, UserPlus, X } from 'lucide-react';
import { Facebook, Instagram } from '../../../components/BrandIcons';
import { useI18n } from '../../../i18n';
import { useBiz } from '../../../lib/business';
import { supabase } from '../../../lib/supabase';
import { recordSale, unwrap, queryClient } from '../../../lib/api';
import { Product, useCustomers, useSettings } from '../../../lib/hooks';
import { cacheCatalog, cachedCatalog, enqueueSale, isNetworkError } from '../../../lib/offline';
import { errorMessage } from '../../../lib/errors';
import { newId } from '../../../lib/ids';
import { formatMoney, formatNumber, toNumber } from '../../../lib/format';
import { Alert, Button, Card, Field, Input, LinkButton, Select, Textarea, useMoney } from '../../../components/ui';
import { ProductPicker } from '../../../components/ProductPicker';
import { PartyFormModal } from '../parties/PartyForm';

interface Line { key: string; product: Product; unit_id: string; qty: string; price: string; discount: string }
interface Pay { key: string; method: string; amount: string; reference: string }

const METHODS: { key: string; icon: typeof Banknote; tone: string }[] = [
  { key: 'cash', icon: Banknote, tone: 'text-brand-700' }, { key: 'mtn_momo', icon: Smartphone, tone: 'text-amber-500' },
  { key: 'orange_money', icon: Smartphone, tone: 'text-orange-500' }, { key: 'bank_transfer', icon: Landmark, tone: 'text-blue-600' },
  { key: 'card', icon: Landmark, tone: 'text-violet-600' }, { key: 'other', icon: MoreHorizontal, tone: 'text-gray-500' },
];

/** Where the sale was made. Marketplace sales come from delivered orders, never typed in. */
export const CHANNELS: { key: string; icon: ComponentType<{ className?: string }> }[] = [
  { key: 'in_person', icon: Store }, { key: 'whatsapp', icon: MessageCircle }, { key: 'facebook', icon: Facebook },
  { key: 'phone', icon: Phone }, { key: 'instagram', icon: Instagram }, { key: 'other', icon: MoreHorizontal },
];
const CHANNEL_KEY = 'bizpilot.lastChannel';
const nowLocal = () => { const d = new Date(); d.setMinutes(d.getMinutes() - d.getTimezoneOffset()); return d.toISOString().slice(0, 16); };

function unitOf(l: Line) {
  return (l.product.product_units ?? []).find((u) => u.id === l.unit_id) ?? null;
}
function listPrice(p: Product, unitId: string) {
  const u = (p.product_units ?? []).find((x) => x.id === unitId);
  return u ? Number(u.selling_price ?? Number(p.selling_price) * Number(u.factor)) : Number(p.selling_price);
}

export default function NewSale() {
  const { t, lang, has: hasKey } = useI18n();
  const { id, can, has } = useBiz();
  const money = useMoney();
  const nav = useNavigate();
  const settings = useSettings(id);
  const customers = useCustomers(id, can('customers.manage'));
  const [lines, setLines] = useState<Line[]>([]);
  const [customer, setCustomer] = useState('');
  const [saleDisc, setSaleDisc] = useState('');
  const [method, setMethod] = useState('cash');
  const [split, setSplit] = useState(false);
  const [pays, setPays] = useState<Pay[]>([]);
  const [tendered, setTendered] = useState('');
  const [partial, setPartial] = useState(false);
  const [paidNow, setPaidNow] = useState('');
  const [reference, setReference] = useState('');
  const [dueDate, setDueDate] = useState('');
  const [notes, setNotes] = useState('');
  const [channel, setChannel] = useState(() => { try { return localStorage.getItem(CHANNEL_KEY) || 'in_person'; } catch { return 'in_person'; } });
  const [earlier, setEarlier] = useState(false);
  const [soldAt, setSoldAt] = useState(nowLocal);
  const [delivery, setDelivery] = useState(false);
  const [deliveryCost, setDeliveryCost] = useState('');
  const [deliveryMethod, setDeliveryMethod] = useState('cash');
  const [clientRef, setClientRef] = useState(newId);
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [done, setDone] = useState<null | { id?: string; number?: string; total: number; queued?: boolean; change?: number }>(null);
  const [newCustomer, setNewCustomer] = useState(false);

  // Keep a copy of the catalogue on this device so products can still be picked offline.
  const catalog = useQuery({
    queryKey: ['catalog', id],
    queryFn: async () => {
      const rows = unwrap(await supabase.from('products').select('id,name,sku,barcode,base_unit,allow_fraction,selling_price,purchase_cost,avg_cost,qty_on_hand,min_stock,track_expiry,status,image_path,product_units(id,name,factor,selling_price,barcode,is_default_purchase,is_default_sale,active)')
        .eq('business_id', id).eq('status', 'active').order('name').limit(1500)) as unknown as Product[];
      cacheCatalog(id, rows);
      return rows;
    },
  });
  const offlineProducts = catalog.data ?? cachedCatalog<Product>(id);

  const totals = useMemo(() => {
    let list = 0; let net = 0;
    for (const l of lines) {
      const q = toNumber(l.qty);
      list += Math.round(q * listPrice(l.product, l.unit_id));
      net += Math.round(q * toNumber(l.price) - toNumber(l.discount));
    }
    const total = Math.max(0, net - toNumber(saleDisc));
    const discPct = list > 0 ? Math.max(0, ((list - total) / list) * 100) : 0;
    return { list, net, total, discPct };
  }, [lines, saleDisc]);

  const maxDisc = Number(settings.data?.cashier_max_discount_pct ?? 100);
  const needsApproval = totals.discPct > maxDisc + 0.0001 && !can('sales.discount_large');
  const paid = split ? pays.reduce((a, p) => a + toNumber(p.amount), 0) : partial ? toNumber(paidNow) : totals.total;
  const credit = Math.max(0, totals.total - paid);
  const change = !split && !partial && method === 'cash' && toNumber(tendered) > totals.total ? toNumber(tendered) - totals.total : 0;
  const canCredit = has('customers_credit') && can('customers.credit') && settings.data?.allow_credit_sales !== false;

  useEffect(() => { if (split && pays.length === 0) setPays([{ key: newId(), method: 'cash', amount: String(totals.total), reference: '' }]); }, [split, pays.length, totals.total]);

  const addProduct = (p: Product, unitId?: string | null) => {
    const def = unitId ?? (p.product_units ?? []).find((u) => u.is_default_sale && u.active)?.id ?? '';
    setLines((ls) => {
      const same = ls.find((l) => l.product.id === p.id && l.unit_id === def);
      if (same) return ls.map((l) => (l === same ? { ...l, qty: String(toNumber(l.qty) + 1) } : l));
      return [...ls, { key: newId(), product: p, unit_id: def, qty: '1', price: String(listPrice(p, def)), discount: '' }];
    });
    setError(null);
  };
  const setLine = (key: string, patch: Partial<Line>) => setLines((ls) => ls.map((l) => (l.key === key ? { ...l, ...patch } : l)));
  const bump = (l: Line, d: number) => setLine(l.key, { qty: String(Math.max(l.product.allow_fraction ? 0.1 : 1, toNumber(l.qty) + d)) });

  const reset = () => {
    setLines([]); setCustomer(''); setSaleDisc(''); setMethod('cash'); setSplit(false); setPays([]); setTendered('');
    setPartial(false); setPaidNow(''); setReference(''); setDueDate(''); setNotes(''); setError(null); setDone(null); setClientRef(newId());
    setEarlier(false); setSoldAt(nowLocal()); setDelivery(false); setDeliveryCost(''); setDeliveryMethod('cash');
  };

  const submit = async () => {
    setError(null);
    const payments = split ? pays.filter((p) => toNumber(p.amount) > 0).map((p) => ({ method: p.method, amount: toNumber(p.amount), reference: p.reference || null }))
      : paid > 0 ? [{ method, amount: paid, reference: reference || null }] : [];
    const payload = {
      client_ref: clientRef, customer_id: customer || null, discount_amount: toNumber(saleDisc), notes: notes || null, due_date: credit > 0 ? dueDate || null : null,
      sold_at: earlier && soldAt ? new Date(soldAt).toISOString() : new Date().toISOString(),
      channel, delivery_cost: delivery ? toNumber(deliveryCost) : 0, delivery_cost_method: deliveryMethod,
      lines: lines.map((l) => ({ product_id: l.product.id, unit_id: l.unit_id || null, quantity: toNumber(l.qty), unit_price: toNumber(l.price), discount_amount: toNumber(l.discount) })),
      payments,
    };
    setSubmitting(true);
    try {
      try { localStorage.setItem(CHANNEL_KEY, channel); } catch { /* private mode */ }
      const r = await recordSale<any>(id, payload);
      setDone({ id: r.id, number: r.number, total: Number(r.total), change });
      queryClient.invalidateQueries();
    } catch (e) {
      if (isNetworkError(e)) {
        enqueueSale({ client_ref: clientRef, business_id: id, payload, summary: { total: totals.total, items: lines.length } });
        setDone({ total: totals.total, queued: true, change });
      } else {
        setError(errorMessage(e, t, hasKey));
      }
    } finally {
      setSubmitting(false);
    }
  };

  if (done) {
    return (
      <div className="mx-auto max-w-md py-10 text-center">
        {done.queued ? <CloudOff className="mx-auto h-14 w-14 text-amber-500" /> : <CheckCircle2 className="mx-auto h-14 w-14 text-brand-600" />}
        <h1 className="mt-4 text-2xl font-extrabold">{done.queued ? t('pos.queuedTitle') : t('pos.completeTitle')}</h1>
        <p className="mt-2 text-ink-muted">{done.queued ? t('pos.queuedBody') : t('pos.completeBody', { number: done.number ?? '', total: formatMoney(done.total, lang) })}</p>
        {done.change ? <p className="mt-4 rounded-xl bg-brand-50 px-4 py-3 text-lg font-bold text-brand-800">{t('pos.giveChange', { amount: formatMoney(done.change, lang) })}</p> : null}
        <div className="mt-6 flex flex-col gap-2">
          <Button size="lg" onClick={reset} icon={<Plus className="h-5 w-5" />}>{t('pos.newSale')}</Button>
          {done.id && <LinkButton to={`/app/sales/${done.id}?print=1`} variant="outline" icon={<Printer className="h-4 w-4" />}>{t('pos.printReceipt')}</LinkButton>}
          {done.queued && <LinkButton to="/app/sales?offline=1" variant="ghost">{t('offline.viewQueue')}</LinkButton>}
        </div>
      </div>
    );
  }

  const valid = lines.length > 0 && lines.every((l) => toNumber(l.qty) > 0) && !needsApproval && (credit === 0 || (customer && canCredit));
  return (
    <div className="mx-auto max-w-6xl">
      <div className="mb-4 flex items-center gap-3">
        <button onClick={() => nav(-1)} className="rounded-lg p-1.5 hover:bg-gray-100 dark:hover:bg-gray-800" aria-label={t('common.back')}><ArrowLeft className="h-5 w-5" /></button>
        <div><h1 className="text-2xl font-extrabold tracking-tight">{t('nav.newSale')}</h1><p className="text-sm text-ink-muted">{t('pos.subtitle')}</p></div>
      </div>
      <div className="grid gap-4 lg:grid-cols-5">
        <div className="space-y-3 lg:col-span-3">
          <ProductPicker businessId={id} onPick={addProduct} offlineProducts={offlineProducts} autoFocus />
          {lines.length === 0 ? (
            <Card className="py-10 text-center text-sm text-ink-muted">{t('pos.empty')}</Card>
          ) : lines.map((l) => {
            const u = unitOf(l);
            const units = (l.product.product_units ?? []).filter((x) => x.active);
            const base = toNumber(l.qty) * (u ? Number(u.factor) : 1);
            const short = base > Number(l.product.qty_on_hand) && !settings.data?.allow_negative_stock;
            return (
              <Card key={l.key} className="!p-3">
                <div className="flex items-start gap-3">
                  <div className="min-w-0 flex-1">
                    <p className="truncate font-semibold">{l.product.name}</p>
                    <p className="text-xs text-ink-muted">{money(listPrice(l.product, l.unit_id))} / {u?.name ?? l.product.base_unit} · {t('pos.inStock', { n: formatNumber(l.product.qty_on_hand, lang), unit: l.product.base_unit })}</p>
                  </div>
                  <button onClick={() => setLines((ls) => ls.filter((x) => x.key !== l.key))} className="p-1 text-gray-400 hover:text-red-600" aria-label={t('common.delete')}><X className="h-4 w-4" /></button>
                </div>
                <div className="mt-2 flex flex-wrap items-center gap-2">
                  <div className="flex items-center rounded-lg border border-gray-300 dark:border-gray-700">
                    <button className="px-2.5 py-2" onClick={() => bump(l, -1)} aria-label="-"><Minus className="h-4 w-4" /></button>
                    <input className="w-14 border-x border-gray-300 bg-transparent py-1.5 text-center text-sm font-semibold dark:border-gray-700" inputMode="decimal" value={l.qty} onChange={(e) => setLine(l.key, { qty: e.target.value })} aria-label={t('common.qty')} />
                    <button className="px-2.5 py-2" onClick={() => bump(l, 1)} aria-label="+"><Plus className="h-4 w-4" /></button>
                  </div>
                  {units.length > 0 && (
                    <Select className="!h-9 w-32" value={l.unit_id} onChange={(e) => setLine(l.key, { unit_id: e.target.value, price: String(listPrice(l.product, e.target.value)) })} aria-label={t('purchases.unit')}>
                      <option value="">{l.product.base_unit}</option>
                      {units.map((x) => <option key={x.id} value={x.id}>{x.name}</option>)}
                    </Select>
                  )}
                  <Input className="!h-9 w-28" type="number" min="0" step="any" value={l.price} onChange={(e) => setLine(l.key, { price: e.target.value })} aria-label={t('common.price')} disabled={!can('products.manage') && !can('sales.discount_large')} />
                  <Input className="!h-9 w-24" type="number" min="0" step="any" placeholder={t('pos.discount')} value={l.discount} onChange={(e) => setLine(l.key, { discount: e.target.value })} aria-label={t('pos.discount')} />
                  <span className="ml-auto text-right font-bold tabular-nums">{money(Math.round(toNumber(l.qty) * toNumber(l.price) - toNumber(l.discount)))}</span>
                </div>
                {short && <p className="mt-1.5 text-xs font-semibold text-red-600">{t('pos.notEnoughStock')}</p>}
              </Card>
            );
          })}
        </div>

        <div className="space-y-3 lg:col-span-2">
          <Card>
            <p className="mb-2 font-bold">{t('pos.channelTitle')}</p>
            <div className="grid grid-cols-3 gap-2" role="radiogroup" aria-label={t('pos.channelTitle')}>
              {CHANNELS.map((c) => (
                <button key={c.key} type="button" role="radio" aria-checked={channel === c.key} onClick={() => setChannel(c.key)}
                  className={clsx('flex flex-col items-center gap-1 rounded-xl border px-2 py-2 text-xs font-semibold transition',
                    channel === c.key ? 'border-brand-700 bg-brand-700 text-white' : 'border-gray-200 hover:bg-gray-50 dark:border-gray-700 dark:hover:bg-gray-800')}>
                  <c.icon className="h-4 w-4" />{t(`channels.${c.key}`)}
                </button>
              ))}
            </div>
            <label className="mt-3 flex items-center gap-2 text-sm"><input type="checkbox" checked={earlier} onChange={(e) => setEarlier(e.target.checked)} />{t('pos.soldEarlier')}</label>
            {earlier && <Field className="mt-2" label={t('pos.soldAt')} hint={t('pos.soldAtHint')}><Input type="datetime-local" value={soldAt} max={nowLocal()} onChange={(e) => setSoldAt(e.target.value)} /></Field>}
          </Card>
          <Card>
            <Field label={t('pos.customer')} htmlFor="sale-customer">
              <div className="flex gap-2">
                <Select id="sale-customer" value={customer} onChange={(e) => setCustomer(e.target.value)} className="flex-1" disabled={!can('customers.manage')}>
                  <option value="">{t('common.walkIn')}</option>
                  {(customers.data ?? []).map((c) => <option key={c.id} value={c.id}>{c.name}{c.phone ? ` · ${c.phone}` : ''}</option>)}
                </Select>
                {can('customers.manage') && <Button variant="outline" onClick={() => setNewCustomer(true)} aria-label={t('parties.new_customer')}><UserPlus className="h-4 w-4" /></Button>}
              </div>
            </Field>
            <dl className="mt-4 space-y-2 text-sm">
              <div className="flex justify-between"><dt>{t('common.subtotal')}</dt><dd className="tabular-nums">{money(totals.net)}</dd></div>
              <div className="flex items-center justify-between gap-3"><dt>{t('pos.saleDiscount')}</dt><dd><Input className="!h-8 w-28 text-right" type="number" min="0" step="any" value={saleDisc} onChange={(e) => setSaleDisc(e.target.value)} /></dd></div>
              <div className="flex items-end justify-between border-t border-gray-100 pt-3 dark:border-gray-800"><dt className="text-base font-bold">{t('common.total')}</dt><dd className="text-2xl font-extrabold tabular-nums text-brand-700 dark:text-brand-400">{money(totals.total)}</dd></div>
            </dl>
            {needsApproval && <div className="mt-3"><Alert tone="red">{t('errors.discount_requires_approval', { max_pct: maxDisc, pct: totals.discPct.toFixed(1) })}</Alert></div>}
          </Card>

          <Card>
            <div className="mb-3 flex items-center justify-between"><p className="font-bold">{t('pos.paymentMethod')}</p>
              <button className="text-xs font-semibold text-brand-700" onClick={() => { setSplit((s) => !s); setPays([]); setPartial(false); }}>{split ? t('pos.singlePayment') : t('pos.splitPayment')}</button></div>
            {!split ? (
              <>
                <div className="grid grid-cols-3 gap-2">
                  {METHODS.map((m) => (
                    <button key={m.key} onClick={() => setMethod(m.key)} aria-pressed={method === m.key}
                      className={clsx('flex flex-col items-center gap-1 rounded-xl border px-2 py-2.5 text-xs font-semibold transition',
                        method === m.key ? 'border-brand-700 bg-brand-700 text-white' : 'border-gray-200 hover:bg-gray-50 dark:border-gray-700 dark:hover:bg-gray-800')}>
                      <m.icon className={clsx('h-5 w-5', method === m.key ? 'text-white' : m.tone)} />{t(`methods.${m.key}`)}
                    </button>
                  ))}
                </div>
                {method === 'cash' && !partial && <Field className="mt-3" label={t('pos.tendered')} hint={change > 0 ? t('pos.change', { amount: money(change) }) : undefined}><Input type="number" min="0" step="any" value={tendered} onChange={(e) => setTendered(e.target.value)} suffix="FCFA" /></Field>}
                {method !== 'cash' && <Field className="mt-3" label={t('pos.paymentReference')} hint={t('pos.paymentReferenceHint')}><Input value={reference} onChange={(e) => setReference(e.target.value)} /></Field>}
                {canCredit && (
                  <label className="mt-3 flex items-center gap-2 text-sm"><input type="checkbox" checked={partial} onChange={(e) => { setPartial(e.target.checked); setPaidNow(''); }} />{t('pos.partialOrCredit')}</label>
                )}
                {partial && <Field className="mt-2" label={t('pos.amountPaidNow')}><Input type="number" min="0" step="any" value={paidNow} onChange={(e) => setPaidNow(e.target.value)} suffix="FCFA" /></Field>}
              </>
            ) : (
              <div className="space-y-2">
                {pays.map((p) => (
                  <div key={p.key} className="flex gap-2">
                    <Select className="!h-9 flex-1" value={p.method} onChange={(e) => setPays((x) => x.map((y) => (y.key === p.key ? { ...y, method: e.target.value } : y)))}>{METHODS.map((m) => <option key={m.key} value={m.key}>{t(`methods.${m.key}`)}</option>)}</Select>
                    <Input className="!h-9 w-28" type="number" min="0" step="any" value={p.amount} onChange={(e) => setPays((x) => x.map((y) => (y.key === p.key ? { ...y, amount: e.target.value } : y)))} />
                    <button onClick={() => setPays((x) => x.filter((y) => y.key !== p.key))} className="text-gray-400" aria-label={t('common.delete')}><Trash2 className="h-4 w-4" /></button>
                  </div>
                ))}
                <Button size="sm" variant="ghost" icon={<Plus className="h-4 w-4" />} onClick={() => setPays((x) => [...x, { key: newId(), method: 'mtn_momo', amount: String(Math.max(0, totals.total - x.reduce((a, y) => a + toNumber(y.amount), 0))), reference: '' }])}>{t('pos.addPayment')}</Button>
              </div>
            )}
            {credit > 0 && (
              <div className="mt-3 space-y-2">
                <Alert tone={customer ? 'amber' : 'red'}>{customer ? t('pos.creditNote', { amount: money(credit) }) : t('errors.customer_required_for_credit')}</Alert>
                {customer && <Field label={t('common.dueDate')}><Input type="date" value={dueDate} onChange={(e) => setDueDate(e.target.value)} /></Field>}
              </div>
            )}
            {paid > totals.total && <div className="mt-3"><Alert tone="red">{t('errors.overpayment')}</Alert></div>}
          </Card>

          <Card className="!p-3">
            <label className="flex items-center gap-2 text-sm font-semibold"><input type="checkbox" checked={delivery} onChange={(e) => setDelivery(e.target.checked)} /><Truck className="h-4 w-4 text-ink-muted" />{t('pos.deliveryCost')}</label>
            {delivery && (
              <div className="mt-2 grid grid-cols-2 gap-2">
                <Field label={t('pos.deliveryAmount')} hint={t('pos.deliveryHint')}><Input type="number" min="0" step="any" value={deliveryCost} onChange={(e) => setDeliveryCost(e.target.value)} suffix="FCFA" /></Field>
                <Field label={t('pos.deliveryPaidWith')}><Select value={deliveryMethod} onChange={(e) => setDeliveryMethod(e.target.value)}>{['cash', 'mtn_momo', 'orange_money', 'other'].map((m) => <option key={m} value={m}>{t(`methods.${m}`)}</option>)}</Select></Field>
              </div>
            )}
            <Textarea className="mt-3" rows={2} placeholder={t('common.notes')} value={notes} onChange={(e) => setNotes(e.target.value)} />
          </Card>
          {error && <Alert tone="red">{error}</Alert>}
          <Button size="lg" block loading={submitting} disabled={!valid || paid > totals.total} onClick={submit}>{t('pos.completeSale')} · {money(totals.total)}</Button>
          <p className="text-center text-xs text-ink-muted">{t('pos.serverNote')} <Link to="/app/sales" className="underline">{t('nav.sales')}</Link></p>
        </div>
      </div>
      <PartyFormModal kind="customer" open={newCustomer} onClose={() => setNewCustomer(false)} onSaved={(cid) => setCustomer(cid)} />
    </div>
  );
}
