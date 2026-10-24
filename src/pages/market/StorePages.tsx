import { Fragment, useMemo, useState } from 'react';
import { Link, useNavigate, useParams, useSearchParams } from 'react-router-dom';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import clsx from 'clsx';
import {
  BadgeCheck, Banknote, Clock, CreditCard, Facebook, Heart, Instagram, Mail, MapPin, MessageCircle, Phone, ShoppingBag, Store, Truck,
} from 'lucide-react';
import { useI18n } from '../../i18n';
import { rpc, unwrap } from '../../lib/api';
import { supabase } from '../../lib/supabase';
import { useAuth } from '../../lib/auth';
import { formatDate, formatMoney } from '../../lib/format';
import { ProductCard, productUrl, publicUrl, storeUrl, useCart, waLink } from '../../lib/market';
import { useAction } from '../../lib/useAction';
import { useToast } from '../../lib/toast';
import { MarketImage, Price, ProductGrid, QtyStepper, ReportButton, ShareBar, StockBadge, Stars } from '../../components/market';
import { Button, Card, EmptyState, ErrorState, LinkButton, Modal, PageLoader, Tabs } from '../../components/ui';

const DAYS = ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'] as const;

export function useStore(slug: string | undefined) {
  return useQuery({ queryKey: ['market-store', slug], enabled: Boolean(slug), queryFn: () => rpc<any>('market_store', { p_slug: slug }) });
}

function NotAvailable({ title, body }: { title: string; body: string }) {
  const { t } = useI18n();
  return <div className="mx-auto max-w-xl px-4 py-16"><h1 className="sr-only">{title}</h1><EmptyState icon={<Store className="h-6 w-6" />} title={title} body={body}
    action={<LinkButton to="/market" variant="outline">{t('market.backToMarket')}</LinkButton>} /></div>;
}

function useFollow(businessId: string | undefined) {
  const { session } = useAuth();
  const qc = useQueryClient();
  const q = useQuery({
    queryKey: ['follow', businessId, session?.user.id], enabled: Boolean(businessId && session),
    queryFn: async () => (unwrap(await supabase.from('market_store_follows').select('business_id').eq('business_id', businessId!)) as any[]).length > 0,
  });
  const toggle = async () => {
    if (q.data) await supabase.from('market_store_follows').delete().eq('business_id', businessId!);
    else await supabase.from('market_store_follows').insert({ business_id: businessId });
    qc.invalidateQueries({ queryKey: ['follow', businessId] });
  };
  return { following: Boolean(q.data), toggle, enabled: Boolean(session) };
}

export function StorePage() {
  const { slug } = useParams();
  const { t, lang } = useI18n();
  const { session } = useAuth();
  const nav = useNavigate();
  const [params, setParams] = useSearchParams();
  const tab = (params.get('tab') as 'products' | 'about' | 'reviews') ?? 'products';
  const cat = params.get('category') ?? '';
  const st = useStore(slug);
  const follow = useFollow(st.data?.business_id);
  const products = useQuery({
    queryKey: ['market-store-products', slug, cat], enabled: Boolean(st.data && !st.data.unavailable),
    queryFn: () => rpc<{ total: number; items: ProductCard[] }>('market_search', { p: { store: slug, category: cat || null, sort: 'newest', page_size: 60 } }),
  });
  if (st.isLoading) return <PageLoader />;
  if (st.error) return <ErrorState error={st.error} onRetry={() => st.refetch()} />;
  if (!st.data) return <NotAvailable title={t('market.storeNotFound')} body={t('market.storeNotFoundBody')} />;
  const s = st.data;
  if (s.unavailable) return <NotAvailable title={t('market.storeUnavailable', { name: s.name })} body={t('market.storeUnavailableBody')} />;
  const setTab = (v: string) => { const n = new URLSearchParams(params); n.set('tab', v); setParams(n, { replace: true }); };
  const color = s.brand_color ?? '#156834';
  const cover = publicUrl(s.cover_path);
  return (
    <div>
      <div className="h-32 w-full sm:h-48" style={cover ? { backgroundImage: `url(${cover})`, backgroundSize: 'cover', backgroundPosition: 'center' } : { background: `linear-gradient(135deg, ${color}, #08261a)` }} />
      <div className="mx-auto max-w-7xl px-4 sm:px-6">
        <div className="-mt-10 flex flex-col gap-4 sm:-mt-12 sm:flex-row sm:items-end">
          <MarketImage path={s.logo_path} alt={s.name} className="h-20 w-20 border-4 border-white bg-white shadow-md dark:border-gray-950 sm:h-24 sm:w-24" rounded="rounded-2xl" />
          <div className="min-w-0 flex-1">
            <h1 className="flex items-center gap-2 text-2xl font-extrabold tracking-tight sm:text-3xl">{s.name}
              {s.verified && <span className="inline-flex items-center gap-1 rounded-full bg-brand-50 px-2 py-0.5 text-xs font-semibold text-brand-800 ring-1 ring-brand-200"><BadgeCheck className="h-3.5 w-3.5" />{t('market.verified')}</span>}
            </h1>
            <p className="mt-1 flex flex-wrap items-center gap-x-3 gap-y-1 text-sm text-ink-muted">
              <span>{t(`businessCategories.${s.business_type}`)}</span>
              {s.city && <span className="inline-flex items-center gap-1"><MapPin className="h-3.5 w-3.5" />{s.city}</span>}
              {s.rating_count > 0 && <Stars value={s.rating_avg} count={s.rating_count} />}
            </p>
            {s.tagline && <p className="mt-1 text-sm text-ink-soft dark:text-gray-300">{s.tagline}</p>}
          </div>
          <div className="flex flex-wrap gap-2">
            {s.whatsapp && <a href={waLink(s.whatsapp, t('market.waHello', { store: s.name }))} target="_blank" rel="noopener noreferrer" className="inline-flex h-10 items-center gap-2 rounded-lg bg-[#25D366] px-3 text-sm font-semibold text-white"><MessageCircle className="h-4 w-4" />WhatsApp</a>}
            {s.phone && <a href={`tel:${s.phone}`} className="inline-flex h-10 items-center gap-2 rounded-lg border border-gray-300 px-3 text-sm font-semibold dark:border-gray-700"><Phone className="h-4 w-4" />{t('market.call')}</a>}
            {follow.enabled ? (
              <Button variant={follow.following ? 'secondary' : 'outline'} icon={<Heart className={clsx('h-4 w-4', follow.following && 'fill-current')} />} onClick={follow.toggle}>
                {follow.following ? t('market.following') : t('market.follow')}
              </Button>
            ) : <Button variant="outline" icon={<Heart className="h-4 w-4" />} onClick={() => nav(`/login?next=/s/${s.slug}`)}>{t('market.follow')}</Button>}
          </div>
        </div>

        <Tabs className="mt-6" value={tab} onChange={setTab} items={[
          { value: 'products', label: t('market.tabProducts') }, { value: 'about', label: t('market.tabAbout') },
          { value: 'reviews', label: `${t('market.tabReviews')} (${s.rating_count})` },
        ]} />

        <div className="py-6">
          {tab === 'products' && (
            <>
              {s.categories.length > 0 && (
                <div className="-mx-4 mb-4 flex gap-2 overflow-x-auto px-4 pb-1 sm:mx-0 sm:flex-wrap sm:px-0">
                  {[{ name: '', products: null }, ...s.categories].map((c: any) => (
                    <button key={c.name || 'all'} aria-pressed={cat === c.name} onClick={() => { const n = new URLSearchParams(params); if (c.name) n.set('category', c.name); else n.delete('category'); setParams(n, { replace: true }); }}
                      className={clsx('whitespace-nowrap rounded-full px-3 py-1.5 text-sm font-semibold ring-1', cat === c.name ? 'bg-brand-700 text-white ring-brand-700' : 'bg-white text-ink-soft ring-gray-200 dark:bg-gray-900 dark:text-gray-300 dark:ring-gray-800')}>
                      {c.name || t('market.allProducts')}{c.products ? ` · ${c.products}` : ''}
                    </button>
                  ))}
                </div>
              )}
              {products.isLoading ? <PageLoader /> : <ProductGrid items={products.data?.items ?? []} empty={<EmptyState title={t('market.storeEmpty')} />} />}
            </>
          )}
          {tab === 'about' && <StoreAbout s={s} />}
          {tab === 'reviews' && (
            <Card>
              {s.reviews.length === 0 ? <EmptyState title={t('market.noReviews')} body={t('market.noReviewsBody')} /> : (
                <ul className="divide-y divide-gray-100 dark:divide-gray-800">
                  {s.reviews.map((r: any, i: number) => (
                    <li key={i} className="py-3">
                      <div className="flex items-center justify-between gap-2"><Stars value={r.rating} /><span className="text-xs text-ink-muted">{formatDate(r.created_at, lang)}</span></div>
                      <p className="mt-1 text-sm">{r.comment}</p>
                      <p className="mt-1 text-xs text-ink-muted">{r.author} · {r.product} · {t('market.verifiedPurchase')}</p>
                      {r.reply && <p className="mt-2 rounded-lg bg-gray-50 p-2 text-xs dark:bg-gray-800"><b>{t('market.sellerReply')}:</b> {r.reply}</p>}
                    </li>
                  ))}
                </ul>
              )}
            </Card>
          )}
        </div>

        <div className="flex flex-col gap-3 border-t border-gray-200 py-6 dark:border-gray-800 sm:flex-row sm:items-center sm:justify-between">
          <div><p className="mb-2 text-sm font-semibold">{t('market.shareStore')}</p><ShareBar url={storeUrl(s.slug)} text={t('market.shareStoreText', { store: s.name })} /></div>
          <ReportButton targetType="store" targetId={s.business_id} signedIn={Boolean(session)} label={t('market.reportStore')} />
        </div>
      </div>
    </div>
  );
}

function StoreAbout({ s }: { s: any }) {
  const { t, lang } = useI18n();
  const hours = s.opening_hours ?? {};
  const hasHours = DAYS.some((d) => hours[d]);
  return (
    <div className="grid gap-4 lg:grid-cols-2">
      <Card>
        <h2 className="mb-2 font-bold">{t('market.aboutStore')}</h2>
        <p className="whitespace-pre-line text-sm text-ink-soft dark:text-gray-300">{s.description || t('market.noDescription')}</p>
        <ul className="mt-4 space-y-2 text-sm">
          {s.address && <li className="flex gap-2"><MapPin className="mt-0.5 h-4 w-4 shrink-0 text-ink-muted" />{s.address}{s.city ? `, ${s.city}` : ''}</li>}
          {s.phone && <li className="flex gap-2"><Phone className="mt-0.5 h-4 w-4 shrink-0 text-ink-muted" /><a href={`tel:${s.phone}`} className="hover:underline">{s.phone}</a></li>}
          {s.whatsapp && <li className="flex gap-2"><MessageCircle className="mt-0.5 h-4 w-4 shrink-0 text-ink-muted" /><a href={waLink(s.whatsapp)} target="_blank" rel="noopener noreferrer" className="hover:underline">{s.whatsapp}</a></li>}
          {s.email && <li className="flex gap-2"><Mail className="mt-0.5 h-4 w-4 shrink-0 text-ink-muted" /><a href={`mailto:${s.email}`} className="hover:underline">{s.email}</a></li>}
        </ul>
        <div className="mt-3 flex gap-3">
          {s.facebook_url && <a href={s.facebook_url} target="_blank" rel="noopener noreferrer nofollow" aria-label="Facebook" className="text-ink-muted hover:text-[#1877F2]"><Facebook className="h-5 w-5" /></a>}
          {s.instagram_url && <a href={s.instagram_url} target="_blank" rel="noopener noreferrer nofollow" aria-label="Instagram" className="text-ink-muted hover:text-pink-600"><Instagram className="h-5 w-5" /></a>}
          {s.tiktok_url && <a href={s.tiktok_url} target="_blank" rel="noopener noreferrer nofollow" className="text-sm font-semibold text-ink-muted hover:text-ink">TikTok</a>}
        </div>
        {s.joined && <p className="mt-3 text-xs text-ink-muted">{t('market.sellingSince', { date: formatDate(s.joined, lang) })}</p>}
      </Card>
      <Card>
        <h2 className="mb-2 flex items-center gap-2 font-bold"><Clock className="h-4 w-4" />{t('market.openingHours')}</h2>
        {hasHours ? (
          <dl className="grid grid-cols-[auto_1fr] gap-x-4 gap-y-1 text-sm">
            {DAYS.map((d) => <Fragment key={d}><dt className="text-ink-muted">{t(`market.days.${d}`)}</dt>
              <dd>{hours[d]?.closed || !hours[d] ? t('market.closed') : `${hours[d].open ?? ''} – ${hours[d].close ?? ''}`}</dd></Fragment>)}
          </dl>
        ) : <p className="text-sm text-ink-muted">{t('market.hoursNotSet')}</p>}
        {s.hours_note && <p className="mt-2 text-xs text-ink-muted">{s.hours_note}</p>}
        <h2 className="mb-2 mt-5 flex items-center gap-2 font-bold"><Truck className="h-4 w-4" />{t('market.delivery')}</h2>
        <DeliverySummary s={s} />
        <h2 className="mb-2 mt-5 flex items-center gap-2 font-bold"><CreditCard className="h-4 w-4" />{t('market.paymentMethods')}</h2>
        <PaymentSummary s={s} />
        {s.min_order_amount > 0 && <p className="mt-3 text-xs text-ink-muted">{t('market.minOrder', { amount: formatMoney(s.min_order_amount, lang) })}</p>}
      </Card>
    </div>
  );
}

function DeliverySummary({ s }: { s: any }) {
  const { t, lang } = useI18n();
  return (
    <div className="space-y-1 text-sm">
      {s.zones.length === 0 && !s.pickup_enabled && <p className="text-ink-muted">{t('market.noDeliveryInfo')}</p>}
      {s.zones.map((z: any) => <p key={z.id} className="flex justify-between gap-3"><span>{z.name}{z.eta ? <span className="text-ink-muted"> · {z.eta}</span> : null}</span><b>{Number(z.fee) ? formatMoney(z.fee, lang) : t('market.free')}</b></p>)}
      {s.pickup_enabled && <p className="flex justify-between gap-3"><span>{t('market.pickupInStore')}{s.pickup_note ? <span className="text-ink-muted"> · {s.pickup_note}</span> : null}</span><b>{t('market.free')}</b></p>}
      {s.delivery_note && <p className="pt-1 text-xs text-ink-muted">{s.delivery_note}</p>}
    </div>
  );
}

function PaymentSummary({ s }: { s: any }) {
  const { t } = useI18n();
  return (
    <ul className="space-y-1 text-sm">
      {s.cod_enabled && <li className="flex items-center gap-2"><Banknote className="h-4 w-4 text-brand-600" />{t('market.cod')}</li>}
      {s.online_payment_enabled && <li className="flex items-center gap-2"><CreditCard className="h-4 w-4 text-brand-600" />{t('market.payOnline')}</li>}
    </ul>
  );
}

// ---------------------------------------------------------------------------
// Product page
// ---------------------------------------------------------------------------
interface Option { id: string; label: string | null; price: number; compare_at_price: number | null; available: number; attributes: Record<string, string>; allow_fraction: boolean }

function useOptionPicker(options: Option[]) {
  // Group by attribute (e.g. size × colour) when every option has the same attribute keys.
  const keys = useMemo(() => {
    if (options.length < 2) return [];
    const first = Object.keys(options[0].attributes ?? {}).sort().join('|');
    const same = first && options.every((o) => Object.keys(o.attributes ?? {}).sort().join('|') === first);
    return same ? first.split('|').filter((k) => new Set(options.map((o) => o.attributes[k])).size > 1) : [];
  }, [options]);
  const firstAvailable = options.find((o) => Number(o.available) > 0) ?? options[0];
  const [chosen, setChosen] = useState<Record<string, string>>(() => (keys.length ? Object.fromEntries(keys.map((k) => [k, firstAvailable?.attributes[k]])) : {}));
  const [optionId, setOptionId] = useState<string | undefined>(firstAvailable?.id);
  const selected = keys.length ? options.find((o) => keys.every((k) => o.attributes[k] === chosen[k])) : options.find((o) => o.id === optionId);
  return { keys, chosen, setChosen, setOptionId, selected, values: (k: string) => [...new Set(options.map((o) => o.attributes[k]))] };
}

export function ProductPage() {
  const { slug, id } = useParams();
  const { t } = useI18n();
  const q = useQuery({ queryKey: ['market-product', id], enabled: Boolean(id), queryFn: () => rpc<any>('market_product', { p_id: id }) });
  const st = useStore(slug);
  if (q.isLoading || st.isLoading) return <PageLoader />;
  if (q.error) return <ErrorState error={q.error} onRetry={() => q.refetch()} />;
  if (!q.data || q.data.store.slug !== slug) return <NotAvailable title={t('market.productNotFound')} body={t('market.productNotFoundBody')} />;
  return <ProductView p={q.data} store={st.data} key={q.data.id} />;
}

function ProductView({ p, store }: { p: any; store: any }) {
  const { t, lang, tv } = useI18n();
  const session = Boolean(useAuth().session);
  const nav = useNavigate();
  const cart = useCart();
  const toast = useToast();
  const options: Option[] = p.options.map((o: any) => ({ ...o, price: Number(o.price), available: Number(o.available) }));
  const pick = useOptionPicker(options);
  const [qty, setQty] = useState(1);
  const [img, setImg] = useState(0);
  const [conflict, setConflict] = useState<null | (() => void)>(null);
  const qc = useQueryClient();
  const { run } = useAction();
  const fav = useQuery({
    queryKey: ['fav', p.id], enabled: session,
    queryFn: async () => (unwrap(await supabase.from('market_favorites').select('product_id').eq('product_id', p.id)) as any[]).length > 0,
  });
  const sel: Option | undefined = pick.selected;
  const available = sel ? sel.available : 0;
  const images: string[] = p.images?.length ? p.images : [null];
  const labels = tv('catalog.attr') as Record<string, string>;
  const attrs = Object.entries(p.attributes ?? {}).filter(([, v]) => v !== null && v !== '');
  const storeRef = { business_id: p.store_id, slug: p.store.slug, name: p.store.name };
  const item = sel && { product_id: sel.id, listing_id: p.id, name: p.name, variant_label: sel.label, image: p.images?.[0] ?? null, price: sel.price, quantity: qty, max: Math.min(available, 99) };
  const add = (thenCheckout = false) => {
    if (!item) return;
    const r = cart.add(storeRef, item);
    if (r === 'other_store') { setConflict(() => () => { cart.replace(storeRef, item); setConflict(null); toast(t('market.addedToCart'), 'success'); if (thenCheckout) nav('/checkout'); }); return; }
    toast(t('market.addedToCart'), 'success');
    if (thenCheckout) nav('/checkout');
  };
  const toggleFav = async () => {
    if (!session) { nav(`/login?next=/s/${p.store.slug}/p/${p.id}`); return; }
    await run(async () => {
      if (fav.data) unwrap(await supabase.from('market_favorites').delete().eq('product_id', p.id));
      else unwrap(await supabase.from('market_favorites').insert({ product_id: p.id }));
    });
    qc.invalidateQueries({ queryKey: ['fav'] });
  };
  return (
    <div className="mx-auto max-w-7xl px-4 py-6 sm:px-6">
      <nav className="mb-4 flex flex-wrap items-center gap-1 text-xs text-ink-muted" aria-label={t('market.breadcrumb')}>
        <Link to="/market" className="hover:underline">{t('market.title')}</Link><span>/</span>
        <Link to={`/market/search?type=${p.business_type}`} className="hover:underline">{t(`businessCategories.${p.business_type}`)}</Link><span>/</span>
        <Link to={`/s/${p.store.slug}`} className="hover:underline">{p.store.name}</Link>
      </nav>
      <div className="grid gap-6 lg:grid-cols-2 lg:gap-10">
        <div>
          <div className="aspect-square overflow-hidden rounded-2xl border border-gray-200 bg-white dark:border-gray-800 dark:bg-gray-900">
            <MarketImage path={images[img]} alt={p.name} rounded="" className="h-full w-full" />
          </div>
          {images.length > 1 && (
            <div className="mt-3 flex gap-2 overflow-x-auto">
              {images.map((im, i) => (
                <button key={im ?? i} onClick={() => setImg(i)} aria-label={t('market.photoN', { n: i + 1 })} aria-pressed={img === i}
                  className={clsx('h-16 w-16 shrink-0 overflow-hidden rounded-xl ring-2', img === i ? 'ring-brand-600' : 'ring-transparent')}>
                  <MarketImage path={im} alt="" rounded="" className="h-full w-full" />
                </button>
              ))}
            </div>
          )}
        </div>
        <div>
          {p.brand && <p className="text-sm font-semibold uppercase tracking-wide text-ink-muted">{p.brand}</p>}
          <h1 className="text-2xl font-extrabold tracking-tight sm:text-3xl">{p.name}</h1>
          <div className="mt-2 flex flex-wrap items-center gap-3">
            {p.rating_count > 0 ? <Stars value={p.rating_avg} count={p.rating_count} size="md" /> : <span className="text-xs text-ink-muted">{t('market.noReviewsYet')}</span>}
          </div>
          <div className="mt-4 text-2xl">{sel ? <Price value={sel.price} compareAt={sel.compare_at_price} /> : <Price value={Number(p.price)} from />}</div>
          <div className="mt-1">{sel && <StockBadge available={available} />}</div>

          {options.length > 1 && (
            <div className="mt-5 space-y-4">
              {pick.keys.length ? pick.keys.map((k: string) => (
                <fieldset key={k}>
                  <legend className="mb-2 text-sm font-semibold">{labels[k] ?? k}: <span className="font-normal text-ink-muted">{pick.chosen[k]}</span></legend>
                  <div className="flex flex-wrap gap-2">
                    {pick.values(k).map((v: string) => {
                      const any = options.some((o) => o.attributes[k] === v && o.available > 0 && pick.keys.every((k2: string) => k2 === k || o.attributes[k2] === pick.chosen[k2]));
                      return <button key={v} onClick={() => pick.setChosen({ ...pick.chosen, [k]: v })} aria-pressed={pick.chosen[k] === v}
                        className={clsx('min-w-11 rounded-xl px-3 py-2 text-sm font-semibold ring-1', pick.chosen[k] === v ? 'bg-brand-700 text-white ring-brand-700' : 'bg-white ring-gray-300 dark:bg-gray-900 dark:ring-gray-700', !any && 'opacity-50 line-through')}>{v}</button>;
                    })}
                  </div>
                </fieldset>
              )) : (
                <fieldset>
                  <legend className="mb-2 text-sm font-semibold">{t('market.chooseOption')}</legend>
                  <div className="flex flex-wrap gap-2">
                    {options.map((o) => <button key={o.id} onClick={() => pick.setOptionId(o.id)} aria-pressed={sel?.id === o.id}
                      className={clsx('rounded-xl px-3 py-2 text-sm font-semibold ring-1', sel?.id === o.id ? 'bg-brand-700 text-white ring-brand-700' : 'bg-white ring-gray-300 dark:bg-gray-900 dark:ring-gray-700', o.available <= 0 && 'opacity-50 line-through')}>{o.label}</button>)}
                  </div>
                </fieldset>
              )}
              {!sel && <p className="text-sm text-amber-700">{t('market.optionUnavailable')}</p>}
            </div>
          )}

          <div className="mt-6 space-y-3">
            <div className="flex items-center justify-between gap-3 sm:justify-start">
              <QtyStepper value={qty} onChange={setQty} max={Math.max(1, Math.min(available, 99))} label={t('market.quantity')} />
              <Button size="lg" variant="ghost" onClick={toggleFav} aria-pressed={Boolean(fav.data)} aria-label={fav.data ? t('market.removeFromWishlist') : t('market.addToWishlist')}
                icon={<Heart className={clsx('h-5 w-5', fav.data && 'fill-red-500 text-red-500')} />} />
            </div>
            <div className="grid grid-cols-2 gap-3 sm:flex">
              <Button size="lg" icon={<ShoppingBag className="h-5 w-5" />} disabled={!sel || available <= 0} onClick={() => add(false)}>{t('market.addToCart')}</Button>
              <Button size="lg" variant="secondary" disabled={!sel || available <= 0} onClick={() => add(true)}>{t('market.buyNow')}</Button>
            </div>
          </div>

          <Card className="mt-6">
            <Link to={`/s/${p.store.slug}`} className="flex items-center gap-3">
              <MarketImage path={p.store.logo_path} alt={p.store.name} className="h-12 w-12" />
              <div className="min-w-0 flex-1">
                <p className="flex items-center gap-1 font-bold">{p.store.name}{p.store.verified && <BadgeCheck className="h-4 w-4 text-brand-600" />}</p>
                <p className="text-xs text-ink-muted">{p.store.city} · {t('market.visitStore')}</p>
              </div>
            </Link>
            {store && !store.unavailable && (
              <div className="mt-4 grid gap-4 border-t border-gray-100 pt-4 text-sm dark:border-gray-800 sm:grid-cols-2">
                <div><p className="mb-1 flex items-center gap-1.5 font-semibold"><Truck className="h-4 w-4" />{t('market.delivery')}</p><DeliverySummary s={store} /></div>
                <div><p className="mb-1 flex items-center gap-1.5 font-semibold"><CreditCard className="h-4 w-4" />{t('market.paymentMethods')}</p><PaymentSummary s={store} /></div>
              </div>
            )}
            {store?.whatsapp && <a href={waLink(store.whatsapp, t('market.waProduct', { product: p.name, url: productUrl(p.store.slug, p.id) }))} target="_blank" rel="noopener noreferrer"
              className="mt-4 inline-flex items-center gap-2 text-sm font-semibold text-[#128C7E] hover:underline"><MessageCircle className="h-4 w-4" />{t('market.askSeller')}</a>}
          </Card>

          {(p.description || attrs.length > 0) && (
            <div className="mt-6">
              <h2 className="mb-2 font-bold">{t('market.details')}</h2>
              {p.description && <p className="whitespace-pre-line text-sm text-ink-soft dark:text-gray-300">{p.description}</p>}
              {attrs.length > 0 && (
                <dl className="mt-3 grid grid-cols-2 gap-x-4 gap-y-2 text-sm">
                  {attrs.map(([k, v]) => <div key={k}><dt className="text-xs text-ink-muted">{labels[k] ?? k}</dt><dd className="font-semibold">{String(v)}</dd></div>)}
                </dl>
              )}
            </div>
          )}
          <div className="mt-6 flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
            <ShareBar url={productUrl(p.store.slug, p.id)} text={p.name} compact />
            <ReportButton targetType="product" targetId={p.id} signedIn={session} label={t('market.reportListing')} />
          </div>
        </div>
      </div>

      <section className="mt-10" aria-labelledby="reviews">
        <h2 id="reviews" className="mb-3 text-lg font-bold">{t('market.reviewsTitle')}</h2>
        {p.reviews.length === 0 ? <p className="text-sm text-ink-muted">{t('market.noReviewsBody')}</p> : (
          <ul className="grid gap-3 md:grid-cols-2">
            {p.reviews.map((r: any, i: number) => (
              <li key={i}><Card>
                <div className="flex items-center justify-between"><Stars value={r.rating} /><span className="text-xs text-ink-muted">{formatDate(r.created_at, lang)}</span></div>
                {r.comment && <p className="mt-2 text-sm">{r.comment}</p>}
                <p className="mt-1 text-xs text-ink-muted">{r.author} · {t('market.verifiedPurchase')}</p>
                {r.reply && <p className="mt-2 rounded-lg bg-gray-50 p-2 text-xs dark:bg-gray-800"><b>{t('market.sellerReply')}:</b> {r.reply}</p>}
              </Card></li>
            ))}
          </ul>
        )}
      </section>

      {p.related.length > 0 && (
        <section className="mt-10" aria-labelledby="related">
          <h2 id="related" className="mb-3 text-lg font-bold">{t('market.moreFromStore')}</h2>
          <ProductGrid items={p.related} />
        </section>
      )}

      <Modal open={Boolean(conflict)} onClose={() => setConflict(null)} title={t('market.oneSellerTitle')} size="sm"
        footer={<><Button variant="outline" onClick={() => setConflict(null)}>{t('market.keepCart')}</Button><Button onClick={() => conflict?.()}>{t('market.startNewCart')}</Button></>}>
        <p className="text-sm text-ink-soft dark:text-gray-300">{t('market.oneSellerBody', { store: cart.cart.store_name ?? '' })}</p>
      </Modal>
    </div>
  );
}
