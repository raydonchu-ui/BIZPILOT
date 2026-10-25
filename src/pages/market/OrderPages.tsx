import { FormEvent, useEffect, useState } from 'react';
import { Link, useNavigate, useParams, useSearchParams } from 'react-router-dom';
import { useQuery } from '@tanstack/react-query';
import clsx from 'clsx';
import { CheckCircle2, Copy, Loader2, MapPin, MessageCircle, Phone, Send, ShieldCheck, Smartphone, Star, Store, XCircle } from 'lucide-react';
import { useI18n } from '../../i18n';
import { rpc } from '../../lib/api';
import { useAuth } from '../../lib/auth';
import { formatDateTime, formatMoney } from '../../lib/format';
import { guestOrders, guestToken, rememberGuestOrder, siteOrigin, verifyPayment, waLink } from '../../lib/market';
import { useAction } from '../../lib/useAction';
import { useToast } from '../../lib/toast';
import { MarketImage, OrderStatusBadge, OrderTimeline, PaymentStatusBadge, ReportButton } from '../../components/market';
import { Alert, Button, Card, ConfirmDialog, EmptyState, Field, Input, LinkButton, PageLoader, Textarea } from '../../components/ui';

export function OrderPage() {
  const { id } = useParams();
  const { t, lang } = useI18n();
  const { session } = useAuth();
  const [params] = useSearchParams();
  const toast = useToast();
  const urlToken = params.get('t');
  const token = urlToken ?? (id ? guestToken(id) : null);
  const q = useQuery({
    queryKey: ['market-order', id, token, session?.user.id], enabled: Boolean(id),
    queryFn: () => rpc<any>('market_order_view', { p_order: id, p_token: token }),
    refetchInterval: (query) => (query.state.data && !['delivered', 'cancelled', 'refunded'].includes(query.state.data.status) ? 30_000 : false),
    retry: false,
  });
  useEffect(() => {
    if (urlToken && q.data) rememberGuestOrder({ id: q.data.id, token: urlToken, number: q.data.number, store_name: q.data.store.name, created_at: q.data.created_at });
  }, [urlToken, q.data]);
  const { run, busy } = useAction();
  const [cancelOpen, setCancelOpen] = useState(false);
  const [msg, setMsg] = useState('');
  if (q.isLoading) return <PageLoader />;
  if (q.error || !q.data) {
    return <div className="mx-auto max-w-xl px-4 py-16"><h1 className="sr-only">{t('market.orderNotFound')}</h1><EmptyState icon={<Store className="h-6 w-6" />} title={t('market.orderNotFound')} body={session ? t('market.orderNotFoundBody') : t('market.orderNotFoundGuest')}
      action={<div className="flex gap-2">{!session && <LinkButton to={`/login?next=/order/${id}`}>{t('market.signIn')}</LinkButton>}<LinkButton to="/market" variant="outline">{t('market.backToMarket')}</LinkButton></div>} /></div>;
  }
  const o = q.data;
  const link = `${siteOrigin()}/order/${o.id}${token ? `?t=${token}` : ''}`;
  const send = async (e: FormEvent) => {
    e.preventDefault();
    if (!msg.trim()) return;
    const ok = await run(() => rpc('market_order_customer_action', { p_order: o.id, p_token: token, p_action: 'message', p_text: msg }), t('market.messageSent'));
    if (ok !== undefined) setMsg('');
  };
  const copy = async () => { try { await navigator.clipboard.writeText(link); toast(t('market.linkCopied'), 'success'); } catch { window.prompt(t('market.copyLink'), link); } };
  const waText = t('market.waOrder', { number: o.number, store: o.store.name });
  return (
    <div className="mx-auto max-w-5xl px-4 py-6 sm:px-6">
      {params.get('placed') && (
        <div className="mb-4"><Alert tone="green" title={t('market.orderPlacedTitle', { number: o.number })}>{o.payment_method === 'momo_direct' ? t('market.orderPlacedMomo') : t('market.orderPlacedCod')}</Alert></div>
      )}
      <div className="flex flex-col gap-2 sm:flex-row sm:items-end sm:justify-between">
        <div>
          <p className="text-sm text-ink-muted">{t('market.orderAt', { store: o.store.name })}</p>
          <h1 className="text-2xl font-extrabold tracking-tight">{o.number}</h1>
          <div className="mt-1 flex flex-wrap items-center gap-2"><OrderStatusBadge status={o.status} /><PaymentStatusBadge status={o.payment_status} />
            <span className="text-xs text-ink-muted">{formatDateTime(o.created_at, lang)}</span></div>
        </div>
        {!o.signed_in_owner && <Button variant="outline" size="sm" icon={<Copy className="h-4 w-4" />} onClick={copy}>{t('market.copyOrderLink')}</Button>}
      </div>

      {o.payment_method === 'momo_direct' && o.store.momo && !['cancelled', 'refunded'].includes(o.status) && (
        <DirectMomoCard order={o} token={token} onDone={() => q.refetch()} />
      )}
      {o.payment_method === 'cod' && o.payment_status === 'seller_confirmed' && (
        <div className="mt-4"><Alert tone="green">{t('market.sellerConfirmed')}</Alert></div>
      )}
      {o.status === 'cancelled' && (
        <div className="mt-4"><Alert tone="amber" title={t('market.orderCancelled')}>
          {t(`market.cancelReasons.${['payment_not_completed', 'not_confirmed_in_time', 'cancelled_by_customer'].includes(o.cancel_reason) ? o.cancel_reason : 'other'}`, { reason: o.cancel_reason })}
          {o.payment_status === 'refund_pending' && <p className="mt-1 font-semibold">{t('market.refundPending')}</p>}
          {o.payment_status === 'refunded' && <p className="mt-1 font-semibold">{t('market.refunded', { amount: formatMoney(o.refund_amount ?? o.total, lang) })}</p>}
        </Alert></div>
      )}
      {o.status === 'refunded' && <div className="mt-4"><Alert tone="blue">{o.payment_status === 'refund_pending' ? t('market.refundPending') : t('market.refunded', { amount: formatMoney(o.refund_amount ?? o.total, lang) })}</Alert></div>}

      {!['cancelled'].includes(o.status) && <Card className="mt-4"><OrderTimeline status={o.status} events={o.events} /></Card>}

      <div className="mt-4 grid gap-4 lg:grid-cols-[minmax(0,1fr)_340px]">
        <div className="space-y-4">
          <Card padded={false}>
            <ul className="divide-y divide-gray-100 dark:divide-gray-800">
              {o.lines.map((l: any) => (
                <li key={l.product_id} className="p-4">
                  <div className="flex gap-3">
                    <MarketImage path={l.image_path} alt={l.name} className="h-16 w-16 shrink-0" />
                    <div className="min-w-0 flex-1">
                      <Link to={`/s/${o.store.slug}/p/${l.listing_id ?? l.product_id}`} className="font-semibold hover:underline">{l.name}</Link>
                      {l.variant_label && <p className="text-xs text-ink-muted">{l.variant_label}</p>}
                      <p className="text-sm text-ink-muted">{Number(l.quantity)} × {formatMoney(l.unit_price, lang)}</p>
                    </div>
                    <p className="font-bold">{formatMoney(l.line_total, lang)}</p>
                  </div>
                  {o.can_review && !l.reviewed && <ReviewForm orderId={o.id} token={token} productId={l.product_id} onDone={() => q.refetch()} />}
                  {l.reviewed && <p className="mt-2 flex items-center gap-1 text-xs text-brand-700"><CheckCircle2 className="h-3.5 w-3.5" />{t('market.reviewThanks')}</p>}
                </li>
              ))}
            </ul>
            <dl className="space-y-1 border-t border-gray-100 p-4 text-sm dark:border-gray-800">
              <div className="flex justify-between"><dt className="text-ink-muted">{t('market.subtotal')}</dt><dd>{formatMoney(o.subtotal, lang)}</dd></div>
              {Number(o.discount) > 0 && <div className="flex justify-between"><dt className="text-ink-muted">{t('market.discount')}{o.promo_code ? ` (${o.promo_code})` : ''}</dt><dd>− {formatMoney(o.discount, lang)}</dd></div>}
              <div className="flex justify-between"><dt className="text-ink-muted">{o.delivery_method === 'pickup' ? t('market.pickupInStore') : t('market.deliveryFee')}</dt><dd>{Number(o.delivery_fee) ? formatMoney(o.delivery_fee, lang) : t('market.free')}</dd></div>
              <div className="flex justify-between text-base font-extrabold"><dt>{t('market.total')}</dt><dd>{formatMoney(o.total, lang)}</dd></div>
              <div className="flex justify-between"><dt className="text-ink-muted">{t('market.paymentMethod')}</dt><dd>{o.payment_method === 'cod' ? t('market.cod') : t('market.payOnline')}</dd></div>
            </dl>
          </Card>

          <Card>
            <h2 className="mb-3 font-bold">{t('market.messages')}</h2>
            <ul className="space-y-2">
              {o.events.filter((e: any) => e.kind === 'message' || e.kind === 'dispute' || (e.kind === 'status' && e.message && !['reopened_for_payment'].includes(e.message))).map((e: any, i: number) => (
                <li key={i} className={clsx('max-w-[85%] rounded-xl px-3 py-2 text-sm', e.actor === 'customer' ? 'ml-auto bg-brand-50 dark:bg-brand-900/40' : 'bg-gray-100 dark:bg-gray-800')}>
                  <p className="text-[11px] font-semibold text-ink-muted">{t(`market.actor.${e.actor}`)} · {formatDateTime(e.created_at, lang)}</p>
                  <p>{e.kind === 'dispute' ? t('market.disputeOpened', { reason: t(`market.reasons.${e.message}`) }) : e.message === 'cancelled_by_customer' ? t('market.cancelReasons.cancelled_by_customer') : e.message}</p>
                </li>
              ))}
            </ul>
            {!['cancelled', 'refunded'].includes(o.status) && (
              <form onSubmit={send} className="mt-3 flex gap-2">
                <label htmlFor="order-msg" className="sr-only">{t('market.messageSeller')}</label>
                <Textarea id="order-msg" className="min-h-[44px]" maxLength={1000} value={msg} onChange={(e) => setMsg(e.target.value)} placeholder={t('market.messagePlaceholder')} />
                <Button type="submit" loading={busy} icon={<Send className="h-4 w-4" />} aria-label={t('market.send')} />
              </form>
            )}
          </Card>
        </div>

        <div className="space-y-4">
          <Card>
            <h2 className="mb-2 font-bold">{o.delivery_method === 'pickup' ? t('market.pickupInStore') : t('market.deliveryTo')}</h2>
            {o.delivery_method === 'delivery' ? (
              <p className="flex gap-2 text-sm"><MapPin className="mt-0.5 h-4 w-4 shrink-0 text-ink-muted" /><span>{[o.address?.line, o.address?.area, o.address?.city].filter(Boolean).join(', ')}{o.address?.landmark ? <span className="block text-xs text-ink-muted">{o.address.landmark}</span> : null}
                <span className="block text-xs text-ink-muted">{o.zone_name}{o.delivery_eta ? ` · ${o.delivery_eta}` : ''}</span></span></p>
            ) : <p className="text-sm">{o.store.address ?? o.store.city}{o.store.pickup_note && <span className="block text-xs text-ink-muted">{o.store.pickup_note}</span>}</p>}
            <p className="mt-2 text-sm text-ink-muted">{o.customer_name} · {o.customer_phone}</p>
          </Card>
          <Card>
            <h2 className="mb-2 font-bold">{t('market.contactSeller')}</h2>
            <Link to={`/s/${o.store.slug}`} className="flex items-center gap-2 text-sm font-semibold hover:underline"><MarketImage path={o.store.logo_path} alt={o.store.name} className="h-8 w-8" />{o.store.name}</Link>
            <div className="mt-3 flex flex-wrap gap-2">
              {o.store.whatsapp && <a href={waLink(o.store.whatsapp, waText)} target="_blank" rel="noopener noreferrer" className="inline-flex h-9 items-center gap-1.5 rounded-lg bg-[#25D366] px-3 text-sm font-semibold text-white"><MessageCircle className="h-4 w-4" />WhatsApp</a>}
              {o.store.phone && <a href={`tel:${o.store.phone}`} className="inline-flex h-9 items-center gap-1.5 rounded-lg border border-gray-300 px-3 text-sm font-semibold dark:border-gray-700"><Phone className="h-4 w-4" />{t('market.call')}</a>}
            </div>
          </Card>
          <Card>
            <p className="flex gap-2 text-xs text-ink-muted"><ShieldCheck className="h-4 w-4 shrink-0 text-brand-600" />{o.payment_method === 'online' ? t('market.protectionOnline') : o.payment_method === 'momo_direct' ? t('market.directPayDisclaimer') : t('market.protectionCod')}</p>
            <div className="mt-3 flex flex-wrap items-center justify-between gap-2">
              {o.can_cancel && <Button size="sm" variant="outline" icon={<XCircle className="h-4 w-4" />} onClick={() => setCancelOpen(true)}>{t('market.cancelOrder')}</Button>}
              <ReportButton targetType="order" targetId={o.id} token={token} signedIn={Boolean(session)} label={t('market.reportProblem')} />
            </div>
          </Card>
        </div>
      </div>
      <ConfirmDialog open={cancelOpen} onClose={() => setCancelOpen(false)} danger loading={busy} title={t('market.cancelOrder')} body={t('market.cancelConfirm')}
        onConfirm={async () => { await run(() => rpc('market_order_customer_action', { p_order: o.id, p_token: token, p_action: 'cancel', p_text: null }), t('market.orderCancelled')); setCancelOpen(false); q.refetch(); }} />
    </div>
  );
}

function ReviewForm({ orderId, token, productId, onDone }: { orderId: string; token: string | null; productId: string; onDone: () => void }) {
  const { t } = useI18n();
  const [rating, setRating] = useState(0);
  const [comment, setComment] = useState('');
  const { run, busy } = useAction();
  const submit = async () => {
    const r = await run(() => rpc('market_submit_review', { p_order: orderId, p_token: token, p_product: productId, p_rating: rating, p_comment: comment }), t('market.reviewThanks'));
    if (r) onDone();
  };
  return (
    <div className="mt-3 rounded-xl bg-gray-50 p-3 dark:bg-gray-800/60">
      <p className="text-sm font-semibold">{t('market.rateProduct')}</p>
      <div className="mt-1 flex gap-1" role="radiogroup" aria-label={t('market.rating')}>
        {[1, 2, 3, 4, 5].map((i) => (
          <button key={i} type="button" role="radio" aria-checked={rating === i} aria-label={t('market.starsN', { n: i })} onClick={() => setRating(i)}>
            <Star className={clsx('h-7 w-7', i <= rating ? 'fill-amber-400 text-amber-400' : 'text-gray-300')} />
          </button>
        ))}
      </div>
      {rating > 0 && (
        <>
          <Field label={t('market.reviewComment')} optional className="mt-2"><Textarea maxLength={1000} value={comment} onChange={(e) => setComment(e.target.value)} /></Field>
          <Button size="sm" className="mt-2" loading={busy} onClick={submit}>{t('market.submitReview')}</Button>
        </>
      )}
    </div>
  );
}

// The buyer comes back here from Fapshi's checkout. The page asks the server to check the
// payment with Fapshi; nothing is marked paid because of this redirect.
export function PayReturnPage() {
  const { t } = useI18n();
  const [params] = useSearchParams();
  const nav = useNavigate();
  const pid = params.get('p');
  const [state, setState] = useState<'checking' | 'pending' | 'error'>('checking');
  useEffect(() => {
    if (!pid) { setState('error'); return; }
    let stop = false; let tries = 0;
    const tick = async () => {
      tries += 1;
      try {
        const r = await verifyPayment(pid);
        if (stop) return;
        const done = ['successful', 'failed', 'expired'].includes(r.status);
        if (done || tries >= 15) {
          if (r.kind === 'subscription') nav(`/app/billing?payment=${r.status}`, { replace: true });
          else if (r.order_id) {
            const tk = guestOrders().find((g) => g.id === r.order_id)?.token;
            nav(`/order/${r.order_id}${tk ? `?t=${tk}` : ''}`, { replace: true });
          } else setState('error');
          return;
        }
        setState('pending');
      } catch {
        if (tries >= 3) { setState('error'); return; }
      }
      if (!stop) setTimeout(tick, 4000);
    };
    tick();
    return () => { stop = true; };
  }, [pid, nav]);
  return (
    <div className="mx-auto max-w-md px-4 py-20 text-center">
      {state === 'error' ? (
        <EmptyState title={t('market.payCheckError')} body={t('market.payCheckErrorBody')} action={<LinkButton to="/account">{t('market.myOrders')}</LinkButton>} />
      ) : (
        <>
          <Loader2 className="mx-auto h-10 w-10 animate-spin text-brand-700" />
          <h1 className="mt-4 text-xl font-bold">{t('market.confirmingPayment')}</h1>
          <p className="mt-2 text-sm text-ink-muted">{state === 'pending' ? t('market.paymentStillPending') : t('market.confirmingPaymentBody')}</p>
        </>
      )}
    </div>
  );
}

/** Pay the seller directly with Mobile Money. The buyer's report is evidence only: the seller confirms. */
function DirectMomoCard({ order: o, token, onDone }: { order: any; token: string | null; onDone: () => void }) {
  const { t, lang } = useI18n();
  const toast = useToast();
  const { run, busy } = useAction();
  const [ref, setRef] = useState('');
  const m = o.store.momo;
  const confirmed = ['seller_confirmed', 'cod_collected'].includes(o.payment_status);
  const copy = async (v: string) => { try { await navigator.clipboard.writeText(v); toast(t('market.copied'), 'success'); } catch { window.prompt('', v); } };
  const report = async (e: FormEvent) => {
    e.preventDefault();
    const ok = await run(() => rpc('market_order_report_payment', { p_order: o.id, p_token: token, p_reference: ref }), t('market.paymentReported'));
    if (ok !== undefined) { setRef(''); onDone(); }
  };
  if (confirmed) {
    return <div className="mt-4"><Alert tone="green" title={t('market.sellerConfirmedTitle')}>{t('market.sellerConfirmedMomo', { method: t(`methods.${o.paid_with ?? 'mtn_momo'}`) })}</Alert></div>;
  }
  const accounts = [
    m.mtn_number && { key: 'mtn', label: 'MTN Mobile Money', number: m.mtn_number, name: m.mtn_name, tone: 'bg-yellow-400 text-gray-900' },
    m.orange_number && { key: 'orange', label: 'Orange Money', number: m.orange_number, name: m.orange_name, tone: 'bg-orange-500 text-white' },
  ].filter(Boolean) as { key: string; label: string; number: string; name?: string; tone: string }[];
  return (
    <Card className="mt-4 border-amber-200 bg-amber-50 dark:border-amber-900 dark:bg-amber-950/40">
      <div className="flex items-start gap-3">
        <Smartphone className="h-6 w-6 shrink-0 text-amber-700" />
        <div className="flex-1">
          <p className="font-bold">{t('market.payTheSeller', { amount: formatMoney(o.total, lang), store: o.store.name })}</p>
          <p className="text-sm">{t('market.payTheSellerBody')}</p>
        </div>
      </div>
      <div className="mt-3 grid gap-2 sm:grid-cols-2">
        {accounts.map((a) => (
          <div key={a.key} className="rounded-xl bg-white p-3 dark:bg-gray-900">
            <span className={clsx('rounded-full px-2 py-0.5 text-xs font-bold', a.tone)}>{a.label}</span>
            <p className="mt-2 flex items-center gap-2 text-lg font-extrabold tracking-wide">{a.number}
              <button type="button" onClick={() => copy(a.number)} aria-label={t('market.copyNumber')} className="text-ink-muted hover:text-ink"><Copy className="h-4 w-4" /></button></p>
            {a.name && <p className="text-sm text-ink-muted">{t('market.accountName', { name: a.name })}</p>}
            <p className="mt-1 text-xs text-ink-muted">{a.key === 'mtn' ? t('market.ussdMtn') : t('market.ussdOrange')}</p>
          </div>
        ))}
      </div>
      {m.note && <p className="mt-2 text-sm">{m.note}</p>}
      <p className="mt-3 flex gap-2 text-xs text-ink-muted"><ShieldCheck className="h-4 w-4 shrink-0" />{t('market.directPayDisclaimer')}</p>
      {o.buyer_payment_reported_at ? (
        <div className="mt-3"><Alert tone="blue" title={t('market.reportedTitle')}>{t('market.reportedBody', { ref: o.buyer_payment_ref })}</Alert></div>
      ) : o.can_report_payment && (
        <form onSubmit={report} className="mt-3 flex flex-col gap-2 sm:flex-row sm:items-end">
          <Field className="flex-1" label={t('market.paymentRef')} hint={t('market.paymentRefHint')}>
            <Input value={ref} onChange={(e) => setRef(e.target.value)} minLength={4} maxLength={120} required />
          </Field>
          <Button type="submit" loading={busy} disabled={ref.trim().length < 4}>{t('market.iHavePaid')}</Button>
        </form>
      )}
    </Card>
  );
}
