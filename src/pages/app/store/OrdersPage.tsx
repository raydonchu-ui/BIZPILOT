import { useState } from 'react';
import { Link, useNavigate, useParams, useSearchParams } from 'react-router-dom';
import { useQuery } from '@tanstack/react-query';
import clsx from 'clsx';
import { AlertTriangle, ArrowLeft, Ban, CheckCircle2, MapPin, MessageCircle, PackageCheck, Phone, Send, Truck, Undo2 } from 'lucide-react';
import { useI18n } from '../../../i18n';
import { useBiz } from '../../../lib/business';
import { rpc, unwrap } from '../../../lib/api';
import { supabase } from '../../../lib/supabase';
import { uploadFile } from '../../../lib/hooks';
import { useAction } from '../../../lib/useAction';
import { formatDateTime, formatMoney, formatRelative } from '../../../lib/format';
import { storeUrl, useMarketConfig, waLink } from '../../../lib/market';
import { MarketImage, OrderStatusBadge, OrderTimeline, PaymentStatusBadge, ShareBar } from '../../../components/market';
import { Alert, Button, Card, CardHeader, Checkbox, DataTable, EmptyState, ErrorState, Field, Input, Modal, PageHeader, PageLoader, Pagination, Select, Tabs, Textarea } from '../../../components/ui';
import { useStoreRow } from './MyStorePage';

type Filter = 'to_confirm' | 'awaiting_payment' | 'active' | 'delivered' | 'closed' | 'all';
const PAGE = 25;

export default function OrdersPage() {
  const { t, lang } = useI18n();
  const { id } = useBiz();
  const nav = useNavigate();
  const cfg = useMarketConfig();
  const store = useStoreRow(id, Boolean(cfg.data));
  const [params, setParams] = useSearchParams();
  const filter = (params.get('f') as Filter) ?? 'to_confirm';
  const [q, setQ] = useState('');
  const [page, setPage] = useState(0);
  const list = useQuery({
    queryKey: ['seller-orders', id, filter, q, page], enabled: Boolean(cfg.data),
    refetchInterval: 60_000,
    queryFn: async () => {
      let query = supabase.from('market_orders').select('id,number,status,payment_method,payment_status,total,customer_name,customer_phone,created_at,delivery_method,zone_name,flagged', { count: 'exact' }).eq('business_id', id);
      if (filter === 'to_confirm') query = query.eq('status', 'pending').or('payment_method.in.(cod,momo_direct),payment_status.eq.paid');
      // Mobile Money paid to the seller directly: waiting for the seller to confirm the money arrived.
      if (filter === 'awaiting_payment') query = query.in('status', ['pending', 'confirmed', 'processing', 'dispatched']).eq('payment_method', 'momo_direct').eq('payment_status', 'cod_pending');
      if (filter === 'active') query = query.in('status', ['confirmed', 'processing', 'dispatched']);
      if (filter === 'delivered') query = query.eq('status', 'delivered');
      if (filter === 'closed') query = query.in('status', ['cancelled', 'refunded']);
      if (q.trim()) { const like = `%${q.trim().replace(/[%_,()]/g, ' ')}%`; query = query.or(`number.ilike.${like},customer_name.ilike.${like},customer_phone.ilike.${like}`); }
      const res = await query.order('created_at', { ascending: filter === 'to_confirm' || filter === 'active' }).range(page * PAGE, page * PAGE + PAGE - 1);
      return { rows: unwrap(res) as any[], count: res.count ?? 0 };
    },
  });
  if (cfg.isLoading) return <PageLoader />;
  if (!cfg.data) return <div className="mx-auto max-w-3xl"><PageHeader title={t('nav.orders')} /><Alert tone="blue" title={t('seller.store.upgradeTitle')}>{t('seller.store.upgradeBody')}</Alert></div>;
  const setFilter = (f: Filter) => { setPage(0); setParams({ f }, { replace: true }); };
  return (
    <div>
      <PageHeader title={t('nav.orders')} subtitle={t('orders.subtitle')} />
      {store.data === null && <div className="mb-4"><Alert tone="blue" title={t('orders.noStoreTitle')} action={<Link to="/app/store" className="font-semibold underline">{t('seller.store.create')}</Link>}>{t('orders.noStoreBody')}</Alert></div>}
      <Card>
        <div className="mb-3 flex flex-col gap-3 lg:flex-row lg:items-center">
          <Tabs className="flex-1" value={filter} onChange={setFilter} items={(['to_confirm', 'awaiting_payment', 'active', 'delivered', 'closed', 'all'] as Filter[]).map((f) => ({ value: f, label: t(`orders.filters.${f}`) }))} />
          <Input className="lg:w-64" placeholder={t('orders.search')} value={q} onChange={(e) => { setQ(e.target.value); setPage(0); }} aria-label={t('orders.search')} />
        </div>
        {list.isLoading ? <PageLoader /> : list.error ? <ErrorState error={list.error} onRetry={() => list.refetch()} /> : (
          <>
            <DataTable rows={list.data!.rows} rowKey={(r) => r.id} onRowClick={(r) => nav(`/app/orders/${r.id}`)}
              empty={<EmptyState icon={<PackageCheck className="h-6 w-6" />} title={t(`orders.empty.${filter}`)} body={store.data?.status === 'published' ? t('orders.emptyShare') : t('orders.emptyPublish')}
                action={store.data?.status === 'published' ? <ShareBar url={storeUrl(store.data.slug)} text={t('market.shareStoreText', { store: store.data.name })} compact /> : <Link to="/app/store" className="font-semibold text-brand-700 hover:underline">{t('nav.myStore')}</Link>} />}
              columns={[
                { key: 'n', header: t('orders.order'), render: (o) => <div><p className="flex items-center gap-1 font-semibold">{o.flagged && <AlertTriangle className="h-4 w-4 text-red-600" aria-label={t('orders.flagged')} />}{o.number}</p><p className="text-xs text-ink-muted">{formatRelative(o.created_at, lang)}</p></div> },
                { key: 'c', header: t('orders.customer'), render: (o) => <div><p className="font-medium">{o.customer_name}</p><p className="text-xs text-ink-muted">{o.customer_phone}</p></div> },
                { key: 'd', header: t('orders.delivery'), hideOnMobile: true, render: (o) => <span className="text-sm">{o.delivery_method === 'pickup' ? t('market.pickupInStore') : o.zone_name}</span> },
                { key: 'p', header: t('orders.paymentCol'), render: (o) => <PaymentStatusBadge status={o.payment_status} /> },
                { key: 's', header: t('common.status'), render: (o) => <OrderStatusBadge status={o.status} /> },
                { key: 't', header: t('market.total'), align: 'right', render: (o) => <b>{formatMoney(o.total, lang)}</b> },
              ]} />
            <Pagination page={page} pageSize={PAGE} total={list.data!.count} onPage={setPage} />
          </>
        )}
      </Card>
    </div>
  );
}

export function OrderDetailPage() {
  const { orderId } = useParams();
  const { t, lang } = useI18n();
  const { id, can } = useBiz();
  const { run, busy } = useAction();
  const q = useQuery({
    queryKey: ['seller-order', orderId], enabled: Boolean(orderId), refetchInterval: 60_000,
    queryFn: async () => {
      const [o, lines, events, pays] = await Promise.all([
        supabase.from('market_orders').select('*').eq('id', orderId!).single(),
        supabase.from('market_order_lines').select('*').eq('order_id', orderId!).order('sort'),
        supabase.from('market_order_events').select('*').eq('order_id', orderId!).order('created_at'),
        supabase.from('online_payments').select('id,status,amount,trans_id,medium,verified_at,created_at,mismatch,needs_refund').eq('order_id', orderId!).order('created_at'),
      ]);
      return { o: unwrap(o) as any, lines: unwrap(lines) as any[], events: unwrap(events) as any[], payments: (pays.data ?? []) as any[] };
    },
  });
  const [modal, setModal] = useState<null | 'reject' | 'cancel' | 'deliver' | 'refund' | 'dispatch' | 'paid' | 'refunded'>(null);
  const [form, setForm] = useState({ reason: '', message: '', cod_method: 'cash', received_by: '', proof_note: '', restock: true, proof_path: '', reference: '' });
  const [msg, setMsg] = useState({ text: '', note: false });
  if (q.isLoading) return <PageLoader />;
  if (q.error || !q.data) return <ErrorState error={q.error ?? { message: 'not_found' }} />;
  const { o, lines, events, payments } = q.data;
  const act = async (action: string, p: Record<string, unknown> = {}, ok = t(`orders.done.${action}`)) => {
    const r = await run(() => rpc('market_order_action', { p_order: o.id, p_action: action, p }), ok);
    if (r) { setModal(null); q.refetch(); }
    return r;
  };
  const unpaidOnline = o.payment_method === 'online' && o.payment_status !== 'paid';
  const direct = o.payment_method === 'cod' || o.payment_method === 'momo_direct';
  const open = ['pending', 'confirmed', 'processing', 'dispatched'].includes(o.status);
  const sellerConfirmed = o.payment_status === 'seller_confirmed';
  const openPaid = () => { setForm((f) => ({ ...f, cod_method: o.payment_method === 'momo_direct' ? 'mtn_momo' : 'cash', reference: o.buyer_payment_ref ?? '' })); setModal('paid'); };
  const waText = t('orders.waTemplate', { name: o.customer_name.split(' ')[0], number: o.number, status: t(`orders.status.${o.status}`) });
  const onProof = async (file?: File) => {
    if (!file) return;
    const path = await run(() => uploadFile(id, 'orders', file));
    if (path) setForm((f) => ({ ...f, proof_path: path }));
  };
  return (
    <div>
      <PageHeader title={o.number}
        back={<Link to="/app/orders" className="mb-2 inline-flex items-center gap-1 text-sm text-ink-muted hover:text-ink"><ArrowLeft className="h-4 w-4" />{t('nav.orders')}</Link>}
        subtitle={<span className="flex flex-wrap items-center gap-2"><OrderStatusBadge status={o.status} /><PaymentStatusBadge status={o.payment_status} />{formatDateTime(o.created_at, lang)}</span>} />
      {o.flagged && <div className="mb-4"><Alert tone="red" title={t('orders.flagged')}>{t(`orders.flags.${o.flag_reason}`, { reason: o.flag_reason })}</Alert></div>}

      <div className="grid gap-4 lg:grid-cols-[minmax(0,1fr)_360px]">
        <div className="space-y-4">
          <Card>
            <CardHeader title={t('orders.nextStep')} />
            {o.status === 'pending' && unpaidOnline && <Alert tone="amber">{t('orders.waitPayment')}</Alert>}
            {direct && open && o.payment_status === 'cod_pending' && (
              <div className="mb-3">
                <Alert tone={o.buyer_payment_reported_at ? 'amber' : 'blue'} title={o.buyer_payment_reported_at ? t('orders.buyerReported', { ref: o.buyer_payment_ref }) : undefined}
                  action={<Button size="sm" variant="outline" onClick={openPaid}>{t('orders.paymentReceived')}</Button>}>
                  {o.buyer_payment_reported_at ? t('orders.checkBeforeConfirm') : o.payment_method === 'momo_direct' ? t('orders.momoDirectWaiting') : t('orders.codWaiting')}
                </Alert>
              </div>
            )}
            {sellerConfirmed && open && <div className="mb-3"><Alert tone="green">{t('orders.youConfirmed', { method: t(`methods.${o.cod_method}`) })}</Alert></div>}
            {o.status === 'pending' && !unpaidOnline && (
              <div className="flex flex-wrap gap-2">
                <Button icon={<CheckCircle2 className="h-4 w-4" />} loading={busy} onClick={() => act('confirm')}>{t('orders.confirm')}</Button>
                <Button variant="outline" icon={<Ban className="h-4 w-4" />} onClick={() => setModal('reject')}>{t('orders.reject')}</Button>
              </div>
            )}
            {['confirmed', 'processing', 'dispatched'].includes(o.status) && (
              <div className="flex flex-wrap gap-2">
                {o.status === 'confirmed' && <Button variant="secondary" loading={busy} onClick={() => act('processing')}>{t('orders.markProcessing')}</Button>}
                {o.status !== 'dispatched' && <Button variant="secondary" icon={<Truck className="h-4 w-4" />} onClick={() => setModal('dispatch')}>{o.delivery_method === 'pickup' ? t('orders.markReady') : t('orders.markDispatched')}</Button>}
                <Button icon={<PackageCheck className="h-4 w-4" />} onClick={() => setModal('deliver')}>{o.delivery_method === 'pickup' ? t('orders.markCollected') : t('orders.markDelivered')}</Button>
                <Button variant="ghost" className="text-red-600" onClick={() => setModal('cancel')}>{t('orders.cancel')}</Button>
              </div>
            )}
            {o.status === 'delivered' && (
              <div className="flex flex-wrap items-center gap-2">
                <p className="text-sm">{t('orders.deliveredInfo', { date: formatDateTime(o.delivered_at, lang) })}</p>
                {o.sale_id && <Link to={`/app/sales/${o.sale_id}`} className="text-sm font-semibold text-brand-700 hover:underline">{t('orders.viewSale')}</Link>}
                {can('sales.refund') && <Button size="sm" variant="outline" icon={<Undo2 className="h-4 w-4" />} onClick={() => setModal('refund')}>{t('orders.refund')}</Button>}
              </div>
            )}
            {['cancelled', 'refunded'].includes(o.status) && <p className="text-sm text-ink-muted">{t('orders.closedInfo', { reason: o.cancel_reason ?? '' })}{o.payment_status === 'refund_pending' && ` ${o.payment_method === 'online' ? t('orders.refundByBizpilot') : t('orders.refundBySeller', { amount: formatMoney(o.total, lang) })}`}</p>}
            {o.status === 'cancelled' && o.payment_status === 'refund_pending' && direct && (
              <Button className="mt-2" size="sm" onClick={() => { setForm((f) => ({ ...f, reference: '' })); setModal('refunded'); }}>{t('orders.refundSent')}</Button>
            )}
            {o.status !== 'cancelled' && <div className="mt-5"><OrderTimeline status={o.status} events={events} /></div>}
          </Card>

          <Card padded={false}>
            <ul className="divide-y divide-gray-100 dark:divide-gray-800">
              {lines.map((l) => (
                <li key={l.id} className="flex items-center gap-3 p-4">
                  <MarketImage path={l.image_path} alt={l.name} className="h-12 w-12 shrink-0" />
                  <div className="min-w-0 flex-1"><Link to={`/app/products/${l.product_id}`} className="font-semibold hover:underline">{l.name}</Link>
                    <p className="text-xs text-ink-muted">{l.variant_label ? `${l.variant_label} · ` : ''}{l.sku}</p>
                    <p className="text-sm text-ink-muted">{Number(l.quantity)} × {formatMoney(l.unit_price, lang)}</p></div>
                  <p className="shrink-0 text-right font-bold">{formatMoney(l.line_total, lang)}</p>
                </li>
              ))}
            </ul>
            <dl className="space-y-1 border-t border-gray-100 p-4 text-sm dark:border-gray-800">
              <Line label={t('market.subtotal')} value={formatMoney(o.subtotal, lang)} />
              {Number(o.discount) > 0 && <Line label={`${t('market.discount')}${o.promo_code ? ` (${o.promo_code})` : ''}`} value={`− ${formatMoney(o.discount, lang)}`} />}
              <Line label={t('market.deliveryFee')} value={formatMoney(o.delivery_fee, lang)} />
              <div className="flex justify-between text-base font-extrabold"><dt>{t('market.total')}</dt><dd>{formatMoney(o.total, lang)}</dd></div>
              {Number(o.commission_amount) > 0 && <Line label={t('orders.commission', { pct: o.commission_pct })} value={`− ${formatMoney(o.commission_amount, lang)}`} />}
              {Number(o.online_fee_amount) > 0 && <Line label={t('orders.processingFee', { pct: o.online_fee_pct })} value={`− ${formatMoney(o.online_fee_amount, lang)}`} />}
            </dl>
          </Card>

          <Card>
            <CardHeader title={t('orders.messages')} subtitle={t('orders.messagesSub')} />
            <ul className="space-y-2">
              {events.filter((e) => e.message && (e.kind !== 'status' || !['reopened_for_payment'].includes(e.message))).map((e) => (
                <li key={e.id} className={clsx('rounded-xl px-3 py-2 text-sm', e.actor === 'seller' ? 'ml-auto max-w-[85%] bg-brand-50 dark:bg-brand-900/40' : e.actor === 'customer' ? 'max-w-[85%] bg-gray-100 dark:bg-gray-800' : 'bg-amber-50 text-xs dark:bg-amber-950/40')}>
                  <p className="text-[11px] font-semibold text-ink-muted">{t(`market.actor.${e.actor}`)}{!e.visible_to_customer && ` · ${t('orders.internal')}`} · {formatDateTime(e.created_at, lang)}</p>
                  <p>{e.kind === 'dispute' ? t('market.disputeOpened', { reason: t(`market.reasons.${e.message}`) }) : e.kind === 'payment' ? t(`orders.paymentEvents.${e.message}`, { m: e.message }) : e.message}</p>
                </li>
              ))}
            </ul>
            <form className="mt-3 space-y-2" onSubmit={async (e) => { e.preventDefault(); if (await act(msg.note ? 'note' : 'message', { message: msg.text }, t('common.saved'))) setMsg({ text: '', note: msg.note }); }}>
              <Textarea aria-label={t('orders.writeMessage')} maxLength={1000} value={msg.text} onChange={(e) => setMsg({ ...msg, text: e.target.value })} placeholder={msg.note ? t('orders.notePlaceholder') : t('orders.messagePlaceholder')} />
              <div className="flex items-center justify-between gap-2">
                <Checkbox label={t('orders.internalNote')} checked={msg.note} onChange={(v) => setMsg({ ...msg, note: v })} />
                <Button type="submit" size="sm" icon={<Send className="h-4 w-4" />} disabled={!msg.text.trim()} loading={busy}>{msg.note ? t('orders.saveNote') : t('orders.sendToCustomer')}</Button>
              </div>
            </form>
          </Card>
        </div>

        <div className="space-y-4">
          <Card>
            <CardHeader title={t('orders.customer')} />
            <p className="font-semibold">{o.customer_name}</p>
            <p className="text-sm text-ink-muted">{o.customer_phone}{o.customer_email ? ` · ${o.customer_email}` : ''}</p>
            <div className="mt-3 flex flex-wrap gap-2">
              <a href={waLink(o.customer_phone, waText)} target="_blank" rel="noopener noreferrer" className="inline-flex h-9 items-center gap-1.5 rounded-lg bg-[#25D366] px-3 text-sm font-semibold text-white"><MessageCircle className="h-4 w-4" />WhatsApp</a>
              <a href={`tel:${o.customer_phone}`} className="inline-flex h-9 items-center gap-1.5 rounded-lg border border-gray-300 px-3 text-sm font-semibold dark:border-gray-700"><Phone className="h-4 w-4" />{t('market.call')}</a>
              {o.customer_id && <Link to={`/app/customers/${o.customer_id}`} className="inline-flex h-9 items-center px-2 text-sm font-semibold text-brand-700 hover:underline">{t('orders.customerRecord')}</Link>}
            </div>
          </Card>
          <Card>
            <CardHeader title={o.delivery_method === 'pickup' ? t('market.pickupInStore') : t('orders.delivery')} />
            {o.delivery_method === 'delivery' ? (
              <p className="flex gap-2 text-sm"><MapPin className="mt-0.5 h-4 w-4 shrink-0 text-ink-muted" /><span>{[o.address?.line, o.address?.area, o.address?.city].filter(Boolean).join(', ')}
                {o.address?.landmark && <span className="block text-xs text-ink-muted">{o.address.landmark}</span>}
                <span className="block text-xs text-ink-muted">{o.zone_name}{o.delivery_eta ? ` · ${o.delivery_eta}` : ''}</span></span></p>
            ) : <p className="text-sm text-ink-muted">{t('orders.pickupInfo')}</p>}
            {o.notes && <p className="mt-3 rounded-lg bg-amber-50 p-2 text-sm dark:bg-amber-950/40"><b>{t('orders.customerNote')}:</b> {o.notes}</p>}
            {o.received_by && <p className="mt-2 text-xs text-ink-muted">{t('orders.receivedBy', { name: o.received_by })}</p>}
          </Card>
          <Card>
            <CardHeader title={t('orders.paymentCol')} />
            <p className="text-sm">{o.payment_method === 'cod' ? t('market.cod') : o.payment_method === 'momo_direct' ? t('market.momoDirect') : t('market.payOnline')} · <PaymentStatusBadge status={o.payment_status} /></p>
            {o.buyer_payment_ref && <p className="mt-1 text-xs text-ink-muted">{t('orders.buyerRef', { ref: o.buyer_payment_ref, date: formatDateTime(o.buyer_payment_reported_at, lang) })}</p>}
            {o.payment_confirmed_at && <p className="mt-1 text-xs text-ink-muted">{t('orders.confirmedBySeller', { method: t(`methods.${o.cod_method}`), date: formatDateTime(o.payment_confirmed_at, lang) })}{o.payment_reference ? ` · ${o.payment_reference}` : ''}</p>}
            {direct && <p className="mt-2 text-xs text-ink-muted">{t('orders.directNote')}</p>}
            {direct && o.cod_collected_at && <p className="mt-1 text-xs text-ink-muted">{t('orders.codCollected', { amount: formatMoney(o.cod_collected_amount, lang), method: t(`methods.${o.cod_method}`), date: formatDateTime(o.cod_collected_at, lang) })}</p>}
            {payments.map((p) => (
              <p key={p.id} className="mt-1 text-xs text-ink-muted">{t(`orders.onlineStatus.${p.status}`)} · {formatMoney(p.amount, lang)}{p.medium ? ` · ${p.medium}` : ''}{p.verified_at ? ` · ${t('orders.verifiedAt', { date: formatDateTime(p.verified_at, lang) })}` : ''}</p>
            ))}
            {o.payment_method === 'online' && <p className="mt-2 text-xs text-ink-muted">{t('orders.onlineSettlement')}</p>}
          </Card>
        </div>
      </div>

      <Modal open={modal === 'reject' || modal === 'cancel'} onClose={() => setModal(null)} title={modal === 'reject' ? t('orders.reject') : t('orders.cancel')} size="sm"
        footer={<><Button variant="outline" onClick={() => setModal(null)}>{t('common.back')}</Button><Button variant="danger" loading={busy} disabled={!form.reason.trim()} onClick={() => act(modal!, { reason: form.reason })}>{modal === 'reject' ? t('orders.reject') : t('orders.cancel')}</Button></>}>
        <Field label={t('orders.reasonForCustomer')} required hint={o.payment_status === 'paid' ? t('orders.refundNote') : t('orders.stockReleased')}>
          <Select value={form.reason} onChange={(e) => setForm({ ...form, reason: e.target.value })}>
            <option value="">{t('orders.chooseReason')}</option>
            {(['out_of_stock', 'cannot_deliver', 'customer_unreachable', 'customer_request', 'other'] as const).map((r) => <option key={r} value={t(`orders.reasons.${r}`)}>{t(`orders.reasons.${r}`)}</option>)}
          </Select>
        </Field>
      </Modal>
      <Modal open={modal === 'dispatch'} onClose={() => setModal(null)} title={o.delivery_method === 'pickup' ? t('orders.markReady') : t('orders.markDispatched')} size="sm"
        footer={<><Button variant="outline" onClick={() => setModal(null)}>{t('common.back')}</Button><Button loading={busy} onClick={() => act('dispatch', { message: form.message })}>{t('common.confirm')}</Button></>}>
        <Field label={t('orders.messageToCustomer')} optional><Textarea maxLength={500} value={form.message} onChange={(e) => setForm({ ...form, message: e.target.value })} placeholder={o.delivery_method === 'pickup' ? t('orders.readyPlaceholder') : t('orders.dispatchPlaceholder')} /></Field>
      </Modal>
      <Modal open={modal === 'deliver'} onClose={() => setModal(null)} title={o.delivery_method === 'pickup' ? t('orders.markCollected') : t('orders.markDelivered')}
        footer={<><Button variant="outline" onClick={() => setModal(null)}>{t('common.back')}</Button><Button loading={busy} onClick={() => act('deliver', { method: form.cod_method, reference: form.reference || null, received_by: form.received_by, proof_note: form.proof_note, proof_path: form.proof_path || null })}>{t('orders.confirmDelivered')}</Button></>}>
        <div className="space-y-4">
          {sellerConfirmed ? <Alert tone="green">{t('orders.youConfirmed', { method: t(`methods.${o.cod_method}`) })}</Alert> : direct ? (
            <>
              <Alert tone="blue">{t('orders.codConfirm', { amount: formatMoney(o.total, lang) })}</Alert>
              <Field label={t('orders.codMethod')} required>
                <Select value={form.cod_method} onChange={(e) => setForm({ ...form, cod_method: e.target.value })}>
                  {['cash', 'mtn_momo', 'orange_money'].map((m) => <option key={m} value={m}>{t(`methods.${m}`)}</option>)}
                </Select>
              </Field>
            </>
          ) : <Alert tone="green">{t('orders.onlinePaidConfirm')}</Alert>}
          <Field label={t('orders.receivedByLabel')} optional><Input maxLength={80} value={form.received_by} onChange={(e) => setForm({ ...form, received_by: e.target.value })} /></Field>
          <Field label={t('orders.proofNote')} optional><Input maxLength={300} value={form.proof_note} onChange={(e) => setForm({ ...form, proof_note: e.target.value })} /></Field>
          <Field label={t('orders.proofPhoto')} optional hint={form.proof_path ? t('orders.proofAttached') : t('orders.proofHint')}>
            <input type="file" accept="image/png,image/jpeg,image/webp,application/pdf" onChange={(e) => onProof(e.target.files?.[0])} className="text-sm" />
          </Field>
          <p className="text-xs text-ink-muted">{t('orders.deliverEffect')}</p>
        </div>
      </Modal>
      <Modal open={modal === 'paid'} onClose={() => setModal(null)} title={t('orders.paymentReceived')} size="sm"
        footer={<><Button variant="outline" onClick={() => setModal(null)}>{t('common.back')}</Button><Button loading={busy} onClick={() => act('payment_received', { method: form.cod_method, reference: form.reference || null })}>{t('orders.confirmReceived')}</Button></>}>
        <div className="space-y-4">
          <Alert tone="amber">{t('orders.confirmReceivedHelp', { amount: formatMoney(o.total, lang) })}</Alert>
          <Field label={t('orders.codMethod')} required>
            <Select value={form.cod_method} onChange={(e) => setForm({ ...form, cod_method: e.target.value })}>
              {['mtn_momo', 'orange_money', 'cash'].map((m) => <option key={m} value={m}>{t(`methods.${m}`)}</option>)}
            </Select>
          </Field>
          <Field label={t('orders.paymentReference')} optional><Input maxLength={120} value={form.reference} onChange={(e) => setForm({ ...form, reference: e.target.value })} /></Field>
        </div>
      </Modal>
      <Modal open={modal === 'refunded'} onClose={() => setModal(null)} title={t('orders.refundSent')} size="sm"
        footer={<><Button variant="outline" onClick={() => setModal(null)}>{t('common.back')}</Button><Button loading={busy} onClick={() => act('refunded', { reference: form.reference || null })}>{t('common.confirm')}</Button></>}>
        <div className="space-y-4">
          <p className="text-sm">{t('orders.refundSentHelp', { amount: formatMoney(o.total, lang) })}</p>
          <Field label={t('orders.paymentReference')} optional><Input maxLength={120} value={form.reference} onChange={(e) => setForm({ ...form, reference: e.target.value })} /></Field>
        </div>
      </Modal>
      <Modal open={modal === 'refund'} onClose={() => setModal(null)} title={t('orders.refund')} size="sm"
        footer={<><Button variant="outline" onClick={() => setModal(null)}>{t('common.back')}</Button><Button variant="danger" loading={busy} disabled={!form.reason.trim()} onClick={() => act('refund', { reason: form.reason, restock: form.restock })}>{t('orders.refund')}</Button></>}>
        <div className="space-y-4">
          <p className="text-sm">{o.payment_method === 'cod' ? t('orders.refundCod', { amount: formatMoney(Number(o.total) - Number(o.delivery_fee), lang) }) : t('orders.refundOnline')}</p>
          <Field label={t('orders.reason')} required><Input value={form.reason} onChange={(e) => setForm({ ...form, reason: e.target.value })} /></Field>
          <Checkbox label={t('orders.restock')} checked={form.restock} onChange={(v) => setForm({ ...form, restock: v })} />
        </div>
      </Modal>
    </div>
  );
}

function Line({ label, value }: { label: string; value: string }) {
  return <div className="flex justify-between"><dt className="text-ink-muted">{label}</dt><dd>{value}</dd></div>;
}
