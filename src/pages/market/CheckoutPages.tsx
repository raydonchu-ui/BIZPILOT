import { FormEvent, useEffect, useMemo, useRef, useState } from 'react';
import { Link, Navigate, useNavigate } from 'react-router-dom';
import { useQuery } from '@tanstack/react-query';
import clsx from 'clsx';
import { Banknote, CreditCard, Info, Lock, ShoppingBag, Store, Trash2, Truck } from 'lucide-react';
import { useI18n } from '../../i18n';
import { rpc, unwrap } from '../../lib/api';
import { supabase } from '../../lib/supabase';
import { useAuth } from '../../lib/auth';
import { errorKey, errorMessage } from '../../lib/errors';
import { formatMoney } from '../../lib/format';
import { newId } from '../../lib/ids';
import { newAccessToken, rememberGuestOrder, detectMedium, requestOrderPayment, useCart, useMarketConfig } from '../../lib/market';
import { MarketImage, QtyStepper } from '../../components/market';
import { Alert, Button, Card, Checkbox, EmptyState, Field, Input, LinkButton, PageLoader, Select, Textarea } from '../../components/ui';
import { useStore } from './StorePages';

interface Quote {
  business_id?: string; lines: any[]; subtotal: number; discount: number; delivery_fee: number; total: number;
  errors: { code: string; product_id?: string; name?: string; available?: number; min_order?: number }[];
  zone_name?: string; delivery_eta?: string; promo_code?: string | null;
}

function useQuote(items: { product_id: string; quantity: number }[], extra: Record<string, unknown> = {}) {
  return useQuery({
    queryKey: ['market-quote', items, extra],
    enabled: items.length > 0,
    queryFn: () => rpc<Quote>('market_quote', { p: { items, ...extra } }),
    placeholderData: (prev) => prev,
  });
}

export function problemText(e: Quote['errors'][number], t: (k: string, p?: any) => string, lang: 'en' | 'fr') {
  const p = { name: e.name ?? '', available: e.available ?? 0, amount: e.min_order !== undefined ? formatMoney(e.min_order, lang) : '' };
  return t(`market.problems.${e.code}`, p);
}

export function CartPage() {
  const { t, lang } = useI18n();
  const { cart, setQty, remove, clear } = useCart();
  const nav = useNavigate();
  const items = cart.items.map((i) => ({ product_id: i.product_id, quantity: i.quantity }));
  const q = useQuote(items, { delivery_method: 'pickup' });
  const priceOf = (id: string) => q.data?.lines.find((l) => l.product_id === id);
  // Only stock and availability problems matter here; delivery is chosen at checkout.
  const problems = (q.data?.errors ?? []).filter((e) => !['pickup_not_available', 'zone_required', 'delivery_not_available'].includes(e.code));
  const changed = cart.items.some((i) => { const l = priceOf(i.product_id); return l && Number(l.unit_price) !== i.price; });
  if (!cart.items.length) {
    return <div className="mx-auto max-w-xl px-4 py-10"><h1 className="text-center text-2xl font-extrabold tracking-tight">{t('market.cart')}</h1><EmptyState icon={<ShoppingBag className="h-6 w-6" />} title={t('market.cartEmpty')} body={t('market.cartEmptyBody')}
      action={<LinkButton to="/market">{t('market.startShopping')}</LinkButton>} /></div>;
  }
  return (
    <div className="mx-auto max-w-5xl px-4 py-6 sm:px-6">
      <h1 className="text-2xl font-extrabold tracking-tight">{t('market.cart')}</h1>
      <p className="mt-1 flex items-center gap-1.5 text-sm text-ink-muted"><Store className="h-4 w-4" />{t('market.cartFrom')} <Link to={`/s/${cart.store_slug}`} className="font-semibold text-brand-700 hover:underline">{cart.store_name}</Link></p>
      <div className="mt-2"><Alert tone="blue">{t('market.oneSellerNote')}</Alert></div>
      <div className="mt-4 grid gap-6 lg:grid-cols-[minmax(0,1fr)_320px]">
        <Card padded={false}>
          <ul className="divide-y divide-gray-100 dark:divide-gray-800">
            {cart.items.map((i) => {
              const l = priceOf(i.product_id);
              const price = l ? Number(l.unit_price) : i.price;
              const max = l ? Math.max(1, Math.min(Number(l.available), 99)) : i.max || 99;
              return (
                <li key={i.product_id} className="flex gap-3 p-4">
                  <Link to={`/s/${cart.store_slug}/p/${i.listing_id}`}><MarketImage path={i.image} alt={i.name} className="h-20 w-20 shrink-0" /></Link>
                  <div className="min-w-0 flex-1">
                    <Link to={`/s/${cart.store_slug}/p/${i.listing_id}`} className="line-clamp-2 font-semibold hover:underline">{i.name}</Link>
                    {i.variant_label && <p className="text-xs text-ink-muted">{i.variant_label}</p>}
                    <p className="mt-1 text-sm font-bold">{formatMoney(price, lang)}</p>
                    <div className="mt-2 flex items-center gap-3">
                      <QtyStepper value={i.quantity} onChange={(v) => setQty(i.product_id, v)} max={max} label={t('market.quantityFor', { name: i.name })} />
                      <button onClick={() => remove(i.product_id)} className="inline-flex items-center gap-1 text-xs font-semibold text-red-600 hover:underline"><Trash2 className="h-3.5 w-3.5" />{t('market.remove')}</button>
                    </div>
                  </div>
                  <p className="hidden text-right font-bold sm:block">{formatMoney(price * i.quantity, lang)}</p>
                </li>
              );
            })}
          </ul>
        </Card>
        <div className="space-y-3">
          <Card>
            <div className="flex justify-between text-sm"><span>{t('market.subtotal')}</span><b>{formatMoney(q.data?.subtotal ?? cart.items.reduce((s, i) => s + i.price * i.quantity, 0), lang)}</b></div>
            <p className="mt-1 text-xs text-ink-muted">{t('market.deliveryAtCheckout')}</p>
            {changed && <div className="mt-3"><Alert tone="amber">{t('market.pricesUpdated')}</Alert></div>}
            {problems.length > 0 && <div className="mt-3"><Alert tone="red">{problems.map((e, i) => <p key={i}>{problemText(e, t, lang)}</p>)}</Alert></div>}
            <Button block size="lg" className="mt-4" disabled={problems.length > 0 || q.isFetching} onClick={() => nav('/checkout')}>{t('market.checkout')}</Button>
            <LinkButton to={`/s/${cart.store_slug}`} variant="ghost" block className="mt-2">{t('market.continueShopping')}</LinkButton>
          </Card>
          <button onClick={clear} className="text-xs font-semibold text-ink-muted hover:underline">{t('market.emptyCart')}</button>
        </div>
      </div>
    </div>
  );
}

export function CheckoutPage() {
  const { t, lang, has } = useI18n();
  const { session, context } = useAuth();
  const { cart, clear } = useCart();
  const nav = useNavigate();
  const cfg = useMarketConfig();
  const st = useStore(cart.store_slug ?? undefined);
  const clientRef = useRef(newId());
  const tokenRef = useRef(newAccessToken());
  const addresses = useQuery({
    queryKey: ['addresses', session?.user.id], enabled: Boolean(session),
    queryFn: async () => unwrap(await supabase.from('customer_addresses').select('*').order('is_default', { ascending: false }).order('created_at')) as any[],
  });
  const [f, setF] = useState({
    name: context?.profile?.full_name ?? '', phone: context?.profile?.phone ?? '', email: context?.email ?? '',
    method: 'delivery' as 'delivery' | 'pickup', zone_id: '', city: '', area: '', line: '', landmark: '', notes: '',
    payment: 'cod' as 'cod' | 'online', promo: '', save_address: true,
  });
  const [promoApplied, setPromoApplied] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const s = st.data;
  const onlineOk = Boolean(s?.online_payment_enabled && cfg.data?.online_payments_enabled);
  // Sensible defaults from the store's options and the saved address.
  useEffect(() => {
    if (!s) return;
    setF((x) => ({
      ...x,
      method: s.zones.length ? x.method : s.pickup_enabled ? 'pickup' : x.method,
      zone_id: x.zone_id || (s.zones.length === 1 ? s.zones[0].id : ''),
      payment: s.cod_enabled ? x.payment : 'online',
    }));
  }, [s]);
  useEffect(() => {
    const a = addresses.data?.[0];
    if (a) setF((x) => ({ ...x, city: x.city || a.city, area: x.area || (a.area ?? ''), line: x.line || (a.line ?? ''), landmark: x.landmark || (a.landmark ?? ''), phone: x.phone || a.phone, name: x.name || a.recipient_name }));
  }, [addresses.data]);
  const items = useMemo(() => cart.items.map((i) => ({ product_id: i.product_id, quantity: i.quantity })), [cart.items]);
  const q = useQuote(items, { delivery_method: f.method, zone_id: f.method === 'delivery' ? f.zone_id || null : null, promo_code: promoApplied || null });
  if (!cart.items.length) return <Navigate to="/cart" replace />;
  if (st.isLoading || cfg.isLoading) return <PageLoader />;
  if (!s || s.unavailable) {
    return <div className="mx-auto max-w-xl px-4 py-16"><Alert tone="red" title={t('market.storeUnavailable', { name: cart.store_name ?? '' })}>{t('market.storeUnavailableBody')}</Alert>
      <Button variant="outline" className="mt-4" onClick={clear}>{t('market.emptyCart')}</Button></div>;
  }
  const set = (k: keyof typeof f) => (e: { target: { value: string } }) => setF((x) => ({ ...x, [k]: e.target.value }));
  const errors = q.data?.errors ?? [];
  const promoError = errors.find((e) => e.code.startsWith('promo_'));
  const blocking = errors.filter((e) => !e.code.startsWith('promo_'));

  const submit = async (e: FormEvent) => {
    e.preventDefault();
    setError(null);
    if (blocking.length) return setError(problemText(blocking[0], t, lang));
    if (promoError) return setError(problemText(promoError, t, lang));
    setBusy(true);
    try {
      const res = await rpc<any>('market_place_order', { p: {
        client_ref: clientRef.current, access_token: tokenRef.current, items,
        delivery_method: f.method, zone_id: f.method === 'delivery' ? f.zone_id : null, promo_code: promoApplied || null,
        payment_method: f.payment, notes: f.notes,
        customer: { name: f.name, phone: f.phone, email: f.email },
        address: f.method === 'delivery' ? { city: f.city, area: f.area, line: f.line, landmark: f.landmark } : null,
        save_address: Boolean(session) && f.save_address,
      } });
      rememberGuestOrder({ id: res.order_id, token: tokenRef.current, number: res.number, store_name: s.name, created_at: new Date().toISOString() });
      clear();
      if (res.payment_method === 'online' && res.payment_status !== 'paid') {
        try {
          // Send the payment request straight to the phone given at checkout; the order page then
          // waits for the customer to approve it. Without direct pay, Fapshi's payment page opens.
          const medium = detectMedium(f.phone);
          const p = await requestOrderPayment(res.order_id, tokenRef.current, medium ? f.phone : undefined, medium ?? undefined);
          if (p.mode === 'direct') nav(`/order/${res.order_id}?placed=1&waiting=${p.payment_id}`, { replace: true });
          else window.location.assign(p.link);
          return;
        } catch {
          nav(`/order/${res.order_id}?placed=1&pay=failed`, { replace: true });
          return;
        }
      }
      nav(`/order/${res.order_id}?placed=1`, { replace: true });
    } catch (err) {
      const { raw, params } = errorKey(err);
      if (raw === 'checkout_invalid' && Array.isArray((params as any)?.errors)) setError(problemText((params as any).errors[0], t, lang));
      else setError(errorMessage(err, t, has));
      q.refetch();
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="mx-auto max-w-6xl px-4 py-6 sm:px-6">
      <h1 className="text-2xl font-extrabold tracking-tight">{t('market.checkout')}</h1>
      {!session && (
        <p className="mt-1 text-sm text-ink-muted">{t('market.guestCheckout')} <Link to="/login?next=/checkout" className="font-semibold text-brand-700 hover:underline">{t('market.signInForFaster')}</Link></p>
      )}
      <form onSubmit={submit} className="mt-5 grid gap-6 lg:grid-cols-[minmax(0,1fr)_360px]">
        <div className="space-y-5">
          <Card>
            <h2 className="mb-4 text-base font-bold">1. {t('market.yourDetails')}</h2>
            <div className="grid gap-4 sm:grid-cols-2">
              <Field label={t('market.fullName')} required><Input required minLength={2} maxLength={80} autoComplete="name" value={f.name} onChange={set('name')} /></Field>
              <Field label={t('market.phone')} required hint={t('market.phoneHint')}><Input required type="tel" inputMode="tel" autoComplete="tel" value={f.phone} onChange={set('phone')} placeholder="6XX XX XX XX" /></Field>
              <Field label={t('market.email')} optional className="sm:col-span-2" hint={t('market.emailHint')}><Input type="email" autoComplete="email" value={f.email} onChange={set('email')} /></Field>
            </div>
          </Card>

          <Card>
            <h2 className="mb-4 text-base font-bold">2. {t('market.delivery')}</h2>
            <div className="grid gap-3 sm:grid-cols-2" role="radiogroup" aria-label={t('market.delivery')}>
              <Choice active={f.method === 'delivery'} disabled={!s.zones.length} onClick={() => setF({ ...f, method: 'delivery' })} icon={<Truck className="h-5 w-5" />}
                title={t('market.homeDelivery')} sub={s.zones.length ? t('market.chooseZone') : t('market.deliveryNotOffered')} />
              <Choice active={f.method === 'pickup'} disabled={!s.pickup_enabled} onClick={() => setF({ ...f, method: 'pickup' })} icon={<Store className="h-5 w-5" />}
                title={t('market.pickupInStore')} sub={s.pickup_enabled ? (s.pickup_note || s.address || t('market.free')) : t('market.pickupNotOffered')} />
            </div>
            {f.method === 'delivery' && s.zones.length > 0 && (
              <div className="mt-4 grid gap-4 sm:grid-cols-2">
                <Field label={t('market.deliveryZone')} required className="sm:col-span-2">
                  <Select required value={f.zone_id} onChange={set('zone_id')}>
                    <option value="">{t('market.selectZone')}</option>
                    {s.zones.map((z: any) => <option key={z.id} value={z.id}>{z.name} — {Number(z.fee) ? formatMoney(z.fee, lang) : t('market.free')}{z.eta ? ` · ${z.eta}` : ''}</option>)}
                  </Select>
                </Field>
                {(addresses.data?.length ?? 0) > 1 && (
                  <Field label={t('market.savedAddress')} className="sm:col-span-2">
                    <Select onChange={(e) => { const a = addresses.data!.find((x) => x.id === e.target.value); if (a) setF({ ...f, city: a.city, area: a.area ?? '', line: a.line ?? '', landmark: a.landmark ?? '' }); }}>
                      <option value="">{t('market.chooseSaved')}</option>
                      {addresses.data!.map((a) => <option key={a.id} value={a.id}>{[a.label, a.line, a.area, a.city].filter(Boolean).join(', ')}</option>)}
                    </Select>
                  </Field>
                )}
                <Field label={t('market.city')} required><Input required value={f.city} onChange={set('city')} autoComplete="address-level2" /></Field>
                <Field label={t('market.area')} optional><Input value={f.area} onChange={set('area')} placeholder={t('market.areaPlaceholder')} /></Field>
                <Field label={t('market.streetLine')} required className="sm:col-span-2"><Input required value={f.line} onChange={set('line')} autoComplete="street-address" /></Field>
                <Field label={t('market.landmark')} optional className="sm:col-span-2"><Input value={f.landmark} onChange={set('landmark')} placeholder={t('market.landmarkPlaceholder')} /></Field>
                {session && <div className="sm:col-span-2"><Checkbox label={t('market.saveAddress')} checked={f.save_address} onChange={(v) => setF({ ...f, save_address: v })} /></div>}
              </div>
            )}
            {s.delivery_note && <p className="mt-3 flex gap-2 text-xs text-ink-muted"><Info className="h-4 w-4 shrink-0" />{s.delivery_note}</p>}
          </Card>

          <Card>
            <h2 className="mb-4 text-base font-bold">3. {t('market.payment')}</h2>
            <div className="grid gap-3 sm:grid-cols-2" role="radiogroup" aria-label={t('market.payment')}>
              <Choice active={f.payment === 'cod'} disabled={!s.cod_enabled} onClick={() => setF({ ...f, payment: 'cod' })} icon={<Banknote className="h-5 w-5" />}
                title={t('market.cod')} sub={t('market.codHelp')} />
              <Choice active={f.payment === 'online'} disabled={!onlineOk} onClick={() => setF({ ...f, payment: 'online' })} icon={<CreditCard className="h-5 w-5" />}
                title={t('market.payOnline')} sub={onlineOk ? t('market.payOnlineHelp') : t('market.payOnlineUnavailable')} />
            </div>
            {f.payment === 'online' && <p className="mt-3 flex gap-2 text-xs text-ink-muted"><Lock className="h-4 w-4 shrink-0" />{t('market.payOnlineSecure', { minutes: cfg.data?.unpaid_order_minutes ?? 30 })}</p>}
          </Card>

          <Card>
            <Field label={t('market.orderNotes')} optional><Textarea maxLength={500} value={f.notes} onChange={set('notes')} placeholder={t('market.orderNotesPlaceholder')} /></Field>
          </Card>
        </div>

        <div className="lg:sticky lg:top-20 lg:self-start">
          <Card>
            <h2 className="mb-3 text-base font-bold">{t('market.orderSummary')}</h2>
            <p className="mb-3 flex items-center gap-1.5 text-sm text-ink-muted"><Store className="h-4 w-4" />{s.name}</p>
            <ul className="space-y-2 text-sm">
              {(q.data?.lines ?? []).map((l) => (
                <li key={l.product_id} className="flex justify-between gap-3">
                  <span className="min-w-0"><span className="line-clamp-1">{l.quantity} × {l.name}</span>{l.variant_label && <span className="block text-xs text-ink-muted">{l.variant_label}</span>}</span>
                  <span className="shrink-0 font-semibold">{formatMoney(l.line_total, lang)}</span>
                </li>
              ))}
            </ul>
            <div className="mt-4 flex gap-2">
              <Input aria-label={t('market.promoCode')} placeholder={t('market.promoCode')} value={f.promo} onChange={(e) => setF({ ...f, promo: e.target.value.toUpperCase() })} />
              <Button variant="outline" onClick={() => setPromoApplied(f.promo.trim())} disabled={!f.promo.trim()}>{t('market.apply')}</Button>
            </div>
            {promoApplied && promoError && <p className="mt-1 text-xs text-red-600">{problemText(promoError, t, lang)}</p>}
            {promoApplied && !promoError && Number(q.data?.discount) > 0 && <p className="mt-1 text-xs text-brand-700">{t('market.promoApplied', { code: promoApplied })}</p>}
            <dl className="mt-4 space-y-1.5 border-t border-gray-100 pt-3 text-sm dark:border-gray-800">
              <Row label={t('market.subtotal')} value={formatMoney(q.data?.subtotal, lang)} />
              {Number(q.data?.discount) > 0 && <Row label={t('market.discount')} value={`− ${formatMoney(q.data?.discount, lang)}`} />}
              <Row label={f.method === 'pickup' ? t('market.pickupInStore') : t('market.deliveryFee')} value={f.method === 'delivery' && !f.zone_id ? t('market.selectZoneShort') : Number(q.data?.delivery_fee) ? formatMoney(q.data?.delivery_fee, lang) : t('market.free')} />
              <div className="flex justify-between border-t border-gray-100 pt-2 text-base dark:border-gray-800"><dt className="font-bold">{t('market.total')}</dt><dd className="font-extrabold">{formatMoney(q.data?.total, lang)}</dd></div>
              <Row label={t('market.paymentMethod')} value={f.payment === 'cod' ? t('market.cod') : t('market.payOnline')} />
            </dl>
            {blocking.length > 0 && <div className="mt-3"><Alert tone="red">{blocking.map((e, i) => <p key={i}>{problemText(e, t, lang)}</p>)}</Alert></div>}
            {error && <div className="mt-3"><Alert tone="red">{error}</Alert></div>}
            <Button type="submit" block size="lg" className="mt-4" loading={busy} disabled={q.isFetching && !q.data}>
              {f.payment === 'online' ? t('market.placeAndPay', { amount: formatMoney(q.data?.total, lang) }) : t('market.placeOrder')}
            </Button>
            <p className="mt-2 text-center text-xs text-ink-muted">{t('market.agreeTerms')} <Link to="/terms" className="underline">{t('site.footer.terms')}</Link></p>
          </Card>
        </div>
      </form>
    </div>
  );
}

function Row({ label, value }: { label: string; value: string }) {
  return <div className="flex justify-between gap-3"><dt className="text-ink-muted">{label}</dt><dd className="font-semibold">{value}</dd></div>;
}

function Choice({ active, disabled, onClick, icon, title, sub }: { active: boolean; disabled?: boolean; onClick: () => void; icon: React.ReactNode; title: string; sub: string }) {
  return (
    <button type="button" role="radio" aria-checked={active} disabled={disabled} onClick={onClick}
      className={clsx('flex items-start gap-3 rounded-xl p-3 text-left ring-1 transition disabled:cursor-not-allowed disabled:opacity-50',
        active ? 'bg-brand-50 ring-2 ring-brand-600 dark:bg-brand-900/30' : 'bg-white ring-gray-200 hover:bg-gray-50 dark:bg-gray-900 dark:ring-gray-700')}>
      <span className={clsx('mt-0.5', active ? 'text-brand-700' : 'text-ink-muted')}>{icon}</span>
      <span><span className="block text-sm font-bold">{title}</span><span className="block text-xs text-ink-muted">{sub}</span></span>
    </button>
  );
}
