import { ReactNode, useState } from 'react';
import { Link, useLocation, useNavigate } from 'react-router-dom';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import clsx from 'clsx';
import { BadgeCheck, ChevronDown, Copy, Facebook, Flag, Heart, Home, LayoutGrid, MapPin, MessageCircle, Minus, Package, Plus, Search, Share2, Star, Store, UserRound } from 'lucide-react';
import { NavLink } from 'react-router-dom';
import { useAuth } from '../lib/auth';
import { CAMEROON_CITIES, cityKey } from '../lib/cities';
import { supabase } from '../lib/supabase';
import { unwrap } from '../lib/api';
import { useI18n } from '../i18n';
import { formatXaf } from '../lib/format';
import { ProductCard, publicUrl, shareLinks, StoreCard, useCity } from '../lib/market';
import { rpc } from '../lib/api';
import { useAction } from '../lib/useAction';
import { useToast } from '../lib/toast';
import { useMessagesUnread } from '../lib/messages';
import { Button, Field, Input, Modal, Select, Textarea } from './ui';
import { thumbPath } from '../lib/imageProcess';

/** A picture from the storefront bucket. `size="thumb"` shows the small copy in lists; if it is missing, the full picture is used. */
export function MarketImage({ path, alt, className, iconClassName, rounded = 'rounded-xl', size }:
  { path: string | null | undefined; alt: string; className?: string; iconClassName?: string; rounded?: string; size?: 'thumb' }) {
  const [broken, setBroken] = useState(false);
  const [fullInstead, setFullInstead] = useState(false);
  const useThumb = size === 'thumb' && !fullInstead && !!path;
  const src = publicUrl(useThumb ? thumbPath(path!) : path);
  if (!src || broken) {
    return (
      <div className={clsx('flex items-center justify-center bg-gradient-to-br from-brand-50 to-gray-100 text-brand-700/60 dark:from-gray-800 dark:to-gray-900', rounded, className)} aria-label={alt} role="img">
        <Package className={clsx('h-1/3 w-1/3', iconClassName)} />
      </div>
    );
  }
  return <img src={src} alt={alt} loading="lazy" onError={() => (useThumb ? setFullInstead(true) : setBroken(true))} className={clsx('object-cover', rounded, className)} />;
}

export function Price({ value, compareAt, from, className }: { value: number; compareAt?: number | null; from?: boolean; className?: string }) {
  const { t, lang } = useI18n();
  return (
    <span className={clsx('inline-flex flex-wrap items-baseline gap-x-2', className)}>
      <span className="font-extrabold text-ink dark:text-white">{from && <span className="mr-1 text-xs font-semibold text-ink-muted">{t('market.from')}</span>}{formatXaf(value, lang)}</span>
      {compareAt ? <span className="text-xs text-ink-muted line-through">{formatXaf(compareAt, lang)}</span> : null}
    </span>
  );
}

export function Stars({ value, count, size = 'sm' }: { value: number | null | undefined; count?: number; size?: 'sm' | 'md' }) {
  const { t } = useI18n();
  const v = Number(value ?? 0);
  const cls = size === 'md' ? 'h-4 w-4' : 'h-3.5 w-3.5';
  return (
    <span className="inline-flex items-center gap-1 text-xs text-ink-muted" aria-label={t('market.ratingAria', { value: v.toFixed(1), count: count ?? 0 })}>
      <span className="inline-flex">{[1, 2, 3, 4, 5].map((i) => <Star key={i} className={clsx(cls, i <= Math.round(v) ? 'fill-amber-400 text-amber-400' : 'text-gray-300 dark:text-gray-600')} />)}</span>
      {count !== undefined && <span>({count})</span>}
    </span>
  );
}

export function StockBadge({ available }: { available: number }) {
  const { t } = useI18n();
  if (available <= 0) return <span className="text-xs font-semibold text-red-600">{t('market.outOfStock')}</span>;
  if (available <= 3) return <span className="text-xs font-semibold text-amber-700 dark:text-amber-400">{t('market.onlyLeft', { n: available })}</span>;
  return <span className="text-xs font-semibold text-brand-700 dark:text-brand-400">{t('market.inStock')}</span>;
}

/** Stock status pill from recorded stock: In Stock / Low Stock / Out of Stock. */
export function StockPill({ stock, sold }: { stock?: string | null; sold?: boolean }) {
  const { t } = useI18n();
  if (sold) return <span className="inline-flex w-fit rounded-full bg-gray-100 px-2 py-0.5 text-[11px] font-semibold text-gray-600 dark:bg-gray-800 dark:text-gray-300">{t('market.sold')}</span>;
  const map: Record<string, string> = {
    in: 'bg-brand-50 text-brand-700 dark:bg-brand-900/40 dark:text-brand-300',
    low: 'bg-amber-50 text-amber-700 dark:bg-amber-900/30 dark:text-amber-300',
    out: 'bg-red-50 text-red-600 dark:bg-red-900/30 dark:text-red-300',
  };
  const key = stock === 'low' || stock === 'out' ? stock : 'in';
  return <span className={clsx('inline-flex w-fit whitespace-nowrap rounded-full px-2 py-0.5 text-[11px] font-semibold', map[key])}>{t(`market.stock.${key}`)}</span>;
}

/** Heart on a product: saves it to the signed-in shopper's favourites (market_favorites, RLS-protected). */
export function FavoriteHeart({ productId }: { productId: string }) {
  const { t } = useI18n();
  const { session } = useAuth();
  const qc = useQueryClient();
  const nav = useNavigate();
  const loc = useLocation();
  const ids = useQuery({
    queryKey: ['favorite-ids', session?.user.id], enabled: Boolean(session), staleTime: 60_000,
    queryFn: async () => (unwrap(await supabase.from('market_favorites').select('product_id')) as { product_id: string }[]).map((r) => r.product_id),
  });
  const on = Boolean(ids.data?.includes(productId));
  const toggle = async (e: React.MouseEvent) => {
    e.preventDefault(); e.stopPropagation();
    if (!session) { nav(`/login?next=${encodeURIComponent(loc.pathname)}`); return; }
    if (on) await supabase.from('market_favorites').delete().eq('product_id', productId);
    else await supabase.from('market_favorites').insert({ product_id: productId });
    qc.invalidateQueries({ queryKey: ['favorite-ids'] });
    qc.invalidateQueries({ queryKey: ['fav', productId] });
    qc.invalidateQueries({ queryKey: ['wishlist'] });
  };
  return (
    <button type="button" onClick={toggle} aria-pressed={on} aria-label={on ? t('market.removeFromWishlist') : t('market.addToWishlist')}
      className="absolute right-2 top-2 z-10 flex h-8 w-8 items-center justify-center rounded-full bg-white/95 text-ink shadow-sm ring-1 ring-black/5 hover:bg-white dark:bg-gray-900/95 dark:text-gray-100">
      <Heart className={clsx('h-4 w-4', on && 'fill-red-500 text-red-500')} />
    </button>
  );
}

export function ProductTile({ p, hideStore }: { p: ProductCard; hideStore?: boolean }) {
  const { t } = useI18n();
  const out = Number(p.available) <= 0 || p.sold;
  return (
    <div className="group relative flex flex-col">
      <Link to={`/s/${p.store.slug}/p/${p.id}`} className="flex flex-1 flex-col rounded-2xl border border-gray-200/80 bg-white p-2 shadow-card transition hover:-translate-y-0.5 hover:shadow-md dark:border-gray-800 dark:bg-gray-900">
        <div className="relative aspect-square w-full overflow-hidden rounded-xl bg-gray-50 dark:bg-gray-800">
          <MarketImage path={p.image} alt={p.name} rounded="" className="h-full w-full transition group-hover:scale-[1.02]" />
          {p.compare_at_price && <span className="absolute left-1.5 top-1.5 rounded-full bg-red-600 px-1.5 py-0.5 text-[10px] font-bold text-white">{t('market.sale')}</span>}
          {p.condition && p.condition !== 'new' && <span className="absolute bottom-1.5 left-1.5 rounded-full bg-white/95 px-1.5 py-0.5 text-[10px] font-semibold text-ink dark:bg-gray-900/95 dark:text-gray-100">{t(`market.condition.${p.condition}`)}</span>}
        </div>
        <div className="flex flex-1 flex-col gap-1 px-0.5 pb-0.5 pt-2">
          <p className="line-clamp-2 text-[13px] font-semibold leading-snug text-ink dark:text-gray-100">{p.name}</p>
          <Price value={Number(p.price)} compareAt={p.compare_at_price ? Number(p.compare_at_price) : null} from={Number(p.max_price) > Number(p.price)} className="text-sm" />
          <StockPill stock={out ? 'out' : p.stock} sold={p.sold} />
          {!hideStore && (
            <p className="mt-auto flex items-center gap-1 truncate pt-1 text-xs text-ink-muted">
              <Store className="h-3.5 w-3.5 shrink-0" /><span className="truncate">{p.store.name}</span>
              {p.store.verified && <BadgeCheck className="h-3.5 w-3.5 shrink-0 text-brand-600" aria-label={t('market.verified')} />}
              {p.store.city && <span className="truncate">· {p.store.city}</span>}
            </p>
          )}
        </div>
      </Link>
      <FavoriteHeart productId={p.id} />
    </div>
  );
}

/** Product grid. `dense` gives three columns on phones (storefront), two otherwise. */
export function ProductGrid({ items, empty, dense, hideStore }: { items: ProductCard[]; empty?: ReactNode; dense?: boolean; hideStore?: boolean }) {
  if (!items.length) return <>{empty}</>;
  return (
    <div className={clsx('grid gap-3 sm:gap-4', dense ? 'grid-cols-3 sm:grid-cols-4 lg:grid-cols-5' : 'grid-cols-2 sm:grid-cols-3 lg:grid-cols-4 xl:grid-cols-5')}>
      {items.map((p) => <ProductTile key={p.id} p={p} hideStore={hideStore} />)}
    </div>
  );
}

export function StoreTile({ s }: { s: StoreCard }) {
  const { t } = useI18n();
  return (
    <Link to={`/s/${s.slug}`} className="flex items-center gap-3 rounded-2xl border border-gray-200/80 bg-white p-3 shadow-card transition hover:shadow-md dark:border-gray-800 dark:bg-gray-900">
      <MarketImage path={s.logo_path} alt={s.name} className="h-14 w-14 shrink-0" />
      <div className="min-w-0">
        <p className="flex items-center gap-1 truncate font-bold text-ink dark:text-white">{s.name}{s.verified && <BadgeCheck className="h-4 w-4 shrink-0 text-brand-600" aria-label={t('market.verified')} />}</p>
        <p className="truncate text-xs text-ink-muted">{t(`businessCategories.${s.business_type}`)}{s.city ? ` · ${s.city}` : ''}</p>
        <p className="mt-0.5 flex items-center gap-2 text-xs text-ink-muted">{s.rating_count > 0 && <Stars value={s.rating_avg} count={s.rating_count} />}<span>{t('market.productsCount', { n: s.products })}</span></p>
      </div>
    </Link>
  );
}

export function QtyStepper({ value, onChange, max, min = 1, label }: { value: number; onChange: (v: number) => void; max: number; min?: number; label: string }) {
  const { t } = useI18n();
  return (
    <div className="inline-flex items-center rounded-xl border border-gray-300 dark:border-gray-700" role="group" aria-label={label}>
      <button type="button" className="flex h-10 w-10 items-center justify-center text-ink-soft disabled:opacity-40" onClick={() => onChange(Math.max(min, value - 1))} disabled={value <= min} aria-label={t('market.decrease')}><Minus className="h-4 w-4" /></button>
      <span className="w-10 text-center text-sm font-bold tabular-nums" aria-live="polite">{value}</span>
      <button type="button" className="flex h-10 w-10 items-center justify-center text-ink-soft disabled:opacity-40" onClick={() => onChange(Math.min(max, value + 1))} disabled={value >= max} aria-label={t('market.increase')}><Plus className="h-4 w-4" /></button>
    </div>
  );
}

export function ShareBar({ url, text, compact }: { url: string; text: string; compact?: boolean }) {
  const { t } = useI18n();
  const toast = useToast();
  const links = shareLinks(url, text);
  const copy = async () => {
    try { await navigator.clipboard.writeText(url); toast(t('market.linkCopied'), 'success'); } catch { window.prompt(t('market.copyLink'), url); }
  };
  const native = async () => {
    try { await navigator.share({ title: text, url }); } catch { /* cancelled */ }
  };
  const btn = 'inline-flex h-10 items-center gap-2 rounded-lg px-3 text-sm font-semibold transition';
  return (
    <div className="flex flex-wrap gap-2">
      <a href={links.whatsapp} target="_blank" rel="noopener noreferrer" className={clsx(btn, 'bg-[#25D366] text-white hover:brightness-95')}><MessageCircle className="h-4 w-4" />{!compact && 'WhatsApp'}</a>
      <a href={links.facebook} target="_blank" rel="noopener noreferrer" className={clsx(btn, 'bg-[#1877F2] text-white hover:brightness-95')}><Facebook className="h-4 w-4" />{!compact && 'Facebook'}</a>
      <button type="button" onClick={copy} className={clsx(btn, 'bg-gray-900 text-white hover:bg-gray-800 dark:bg-gray-700')} title={t('market.tiktokHint')}><Copy className="h-4 w-4" />{!compact && t('market.copyForTiktok')}</button>
      {typeof navigator !== 'undefined' && 'share' in navigator && (
        <button type="button" onClick={native} className={clsx(btn, 'border border-gray-300 text-ink hover:bg-gray-50 dark:border-gray-700 dark:text-gray-100')}><Share2 className="h-4 w-4" />{!compact && t('market.moreApps')}</button>
      )}
    </div>
  );
}

const REASONS = {
  product: ['counterfeit', 'prohibited', 'misleading', 'scam', 'other'],
  store: ['scam', 'misleading', 'harassment', 'other'],
  order: ['not_delivered', 'wrong_item', 'damaged', 'payment_problem', 'refund_problem', 'other'],
} as const;

export function ReportButton({ targetType, targetId, token, label, signedIn }:
  { targetType: 'product' | 'store' | 'order'; targetId: string; token?: string | null; label?: string; signedIn: boolean }) {
  const { t } = useI18n();
  const [open, setOpen] = useState(false);
  const [f, setF] = useState({ reason: REASONS[targetType][0] as string, details: '', contact: '' });
  const { run, busy } = useAction();
  const submit = async () => {
    const ok = await run(() => rpc('market_report', { p: { target_type: targetType, target_id: targetId, token, ...f } }), t('market.reportSent'));
    if (ok) setOpen(false);
  };
  return (
    <>
      <button type="button" onClick={() => setOpen(true)} className="inline-flex items-center gap-1.5 text-xs font-semibold text-ink-muted hover:text-red-600">
        <Flag className="h-3.5 w-3.5" />{label ?? t('market.report')}
      </button>
      <Modal open={open} onClose={() => setOpen(false)} title={targetType === 'order' ? t('market.disputeTitle') : t('market.reportTitle')} size="sm"
        footer={<><Button variant="outline" onClick={() => setOpen(false)}>{t('common.cancel')}</Button><Button variant="danger" loading={busy} onClick={submit}>{t('market.sendReport')}</Button></>}>
        <div className="space-y-4">
          <p className="text-sm text-ink-muted">{targetType === 'order' ? t('market.disputeHelp') : t('market.reportHelp')}</p>
          <Field label={t('market.reason')}>
            <Select value={f.reason} onChange={(e) => setF({ ...f, reason: e.target.value })}>
              {REASONS[targetType].map((r) => <option key={r} value={r}>{t(`market.reasons.${r}`)}</option>)}
            </Select>
          </Field>
          <Field label={t('market.details')} optional><Textarea maxLength={2000} value={f.details} onChange={(e) => setF({ ...f, details: e.target.value })} /></Field>
          {!signedIn && targetType !== 'order' && (
            <Field label={t('market.yourContact')} hint={t('market.yourContactHint')}><Input maxLength={120} value={f.contact} onChange={(e) => setF({ ...f, contact: e.target.value })} /></Field>
          )}
        </div>
      </Modal>
    </>
  );
}

export const ORDER_STEPS = ['pending', 'confirmed', 'processing', 'dispatched', 'delivered'] as const;

export function OrderStatusBadge({ status }: { status: string }) {
  const { t } = useI18n();
  const tone = status === 'delivered' ? 'bg-brand-50 text-brand-800 ring-brand-600/20' : status === 'cancelled' || status === 'refunded'
    ? 'bg-gray-100 text-gray-700 ring-gray-500/20' : status === 'pending' ? 'bg-amber-50 text-amber-800 ring-amber-600/20' : 'bg-blue-50 text-blue-700 ring-blue-600/20';
  return <span className={clsx('inline-flex items-center whitespace-nowrap rounded-full px-2 py-0.5 text-xs font-semibold ring-1 ring-inset', tone)}>{t(`orders.status.${status}`)}</span>;
}

export function PaymentStatusBadge({ status }: { status: string }) {
  const { t } = useI18n();
  const tone = ['paid', 'cod_collected', 'seller_confirmed', 'refunded'].includes(status) ? 'bg-brand-50 text-brand-800 ring-brand-600/20'
    : ['failed', 'refund_pending'].includes(status) ? 'bg-red-50 text-red-700 ring-red-600/20'
    : status === 'void' ? 'bg-gray-100 text-gray-700 ring-gray-500/20' : 'bg-amber-50 text-amber-800 ring-amber-600/20';
  return <span className={clsx('inline-flex items-center whitespace-nowrap rounded-full px-2 py-0.5 text-xs font-semibold ring-1 ring-inset', tone)}>{t(`orders.payment.${status}`)}</span>;
}

// Where the buyer stands on receiving the order. Nothing is shown for orders delivered before receipts existed.
export function ReceiptBadge({ status }: { status: string }) {
  const { t } = useI18n();
  if (status === 'none') return null;
  const tone = status === 'disputed' ? 'bg-red-50 text-red-700 ring-red-600/20'
    : status === 'confirmed' || status === 'resolved' ? 'bg-brand-50 text-brand-800 ring-brand-600/20' : 'bg-amber-50 text-amber-800 ring-amber-600/20';
  const label = status === 'awaiting' ? 'market.receipt.badgeAwaiting' : status === 'disputed' ? 'market.receipt.badgeDisputed'
    : status === 'confirmed' ? 'market.receipt.badgeConfirmed' : 'market.receipt.badgeResolved';
  return <span className={clsx('inline-flex items-center whitespace-nowrap rounded-full px-2 py-0.5 text-xs font-semibold ring-1 ring-inset', tone)}>{t(label)}</span>;
}

export function OrderTimeline({ status, events }: { status: string; events: { status?: string | null; created_at: string }[] }) {
  const { t } = useI18n();
  const cancelled = status === 'cancelled' || status === 'refunded';
  const reached = new Set(events.map((e) => e.status).filter(Boolean) as string[]);
  const current = ORDER_STEPS.indexOf(status as never);
  return (
    <ol className="flex w-full items-start gap-1" aria-label={t('orders.progress')}>
      {ORDER_STEPS.map((s, i) => {
        const done = cancelled ? reached.has(s) : i <= current;
        return (
          <li key={s} className="flex flex-1 flex-col items-center gap-1 text-center">
            <span className={clsx('flex h-7 w-7 items-center justify-center rounded-full text-xs font-bold',
              done ? 'bg-brand-700 text-white' : 'bg-gray-200 text-gray-500 dark:bg-gray-800')}>{i + 1}</span>
            <span className={clsx('text-[11px] font-semibold leading-tight', done ? 'text-ink dark:text-gray-100' : 'text-ink-muted')}>{t(`orders.status.${s}`)}</span>
          </li>
        );
      })}
    </ol>
  );
}

/** Choose the city the marketplace shows. Lists every town in Cameroon, with the number of shops where there are any. */
export function CitySelector({ block }: { block?: boolean }) {
  const { t } = useI18n();
  const [city, setCity] = useCity();
  const [open, setOpen] = useState(false);
  const [q, setQ] = useState('');
  const counts = useQuery({
    queryKey: ['market-home', ''], staleTime: 60_000,
    queryFn: () => rpc<{ cities: { city: string; shops: number }[] }>('market_home', { p_city: null }),
  });
  const shopsIn = new Map((counts.data?.cities ?? []).map((c) => [cityKey(c.city), c.shops]));
  const needle = cityKey(q);
  const list = CAMEROON_CITIES.filter((c) => !needle || cityKey(c).includes(needle));
  const choose = (next: string) => { setCity(next); setOpen(false); setQ(''); };
  return (
    <>
      <button type="button" onClick={() => setOpen(true)} aria-haspopup="dialog"
        className={clsx('flex min-h-12 items-center gap-3 rounded-2xl bg-brand-50 px-3 py-2 text-left transition hover:bg-brand-100 dark:bg-brand-950/40 dark:hover:bg-brand-900/40', block ? 'w-full' : 'w-fit')}>
        <span className="flex h-9 w-9 shrink-0 items-center justify-center rounded-full bg-brand-700 text-white"><MapPin className="h-4 w-4" /></span>
        <span className="min-w-0 flex-1">
          {block ? (
            <>
              <span className="block text-xs font-semibold text-ink-muted">{t('market.chooseCity')}</span>
              <span className="block truncate text-sm font-bold text-ink dark:text-gray-100">{city ? `${city}, ${t('market.cityCameroon')}` : t('market.allCameroon')}</span>
            </>
          ) : (
            <>
              <span className="block text-sm font-bold text-ink dark:text-gray-100">{city || t('market.chooseCity')}</span>
              <span className="block truncate text-xs text-ink-muted">{city ? t('market.cityCameroon') : t('market.allCameroon')}</span>
            </>
          )}
        </span>
        <ChevronDown className="h-5 w-5 shrink-0 text-ink-soft" />
      </button>
      <Modal open={open} onClose={() => setOpen(false)} title={t('market.chooseCity')} size="sm">
        <div className="space-y-3">
          <Input type="search" value={q} onChange={(e) => setQ(e.target.value)} placeholder={t('market.searchCity')} prefixIcon={<Search className="h-4 w-4" />} aria-label={t('market.searchCity')} />
          <ul className="max-h-[60vh] divide-y divide-gray-100 overflow-y-auto dark:divide-gray-800" aria-label={t('market.chooseCity')}>
            {!needle && (
              <li><button type="button" onClick={() => choose('')} aria-pressed={!city} className={clsx('flex w-full items-center justify-between gap-3 px-1 py-3 text-left text-sm font-semibold', !city && 'text-brand-700 dark:text-brand-400')}>
                {t('market.allCameroon')}{!city && <span aria-hidden="true">✓</span>}</button></li>
            )}
            {list.map((c) => (
              <li key={c}><button type="button" onClick={() => choose(c)} aria-pressed={city === c}
                className={clsx('flex w-full items-center justify-between gap-3 px-1 py-3 text-left text-sm', city === c ? 'font-bold text-brand-700 dark:text-brand-400' : 'font-medium')}>
                <span>{c}</span>
                <span className="flex items-center gap-2 text-xs text-ink-muted">
                  {shopsIn.get(cityKey(c)) ? t('market.shopsCount', { n: shopsIn.get(cityKey(c))! }) : null}
                  {city === c && <span aria-hidden="true">✓</span>}
                </span></button></li>
            ))}
            {list.length === 0 && <li className="py-6 text-center text-sm text-ink-muted">{t('market.noCity')}</li>}
          </ul>
        </div>
      </Modal>
    </>
  );
}

/** Bottom tabs on phones, as in the BizPilot Market design: Home, Shops, Categories, Messages, Profile. */
export function MarketTabBar() {
  const { t } = useI18n();
  const unread = useMessagesUnread().data ?? 0;
  const tabs = [
    { to: '/market', icon: Home, label: t('market.tabs.home'), end: true, badge: 0 },
    { to: '/market/shops', icon: Store, label: t('market.tabs.shops'), end: false, badge: 0 },
    { to: '/market/categories', icon: LayoutGrid, label: t('market.tabs.categories'), end: false, badge: 0 },
    { to: '/messages', icon: MessageCircle, label: t('market.tabs.messages'), end: false, badge: unread },
    { to: '/account', icon: UserRound, label: t('market.tabs.profile'), end: false, badge: 0 },
  ];
  return (
    <nav aria-label={t('market.tabs.label')} className="fixed inset-x-0 bottom-0 z-40 border-t border-gray-200 bg-white/95 pb-[env(safe-area-inset-bottom)] backdrop-blur md:hidden dark:border-gray-800 dark:bg-gray-950/95">
      <ul className="grid grid-cols-5">
        {tabs.map((x) => (
          <li key={x.to}>
            <NavLink to={x.to} end={x.end} className={({ isActive }) => clsx('flex flex-col items-center gap-0.5 py-2 text-[11px] font-semibold', isActive ? 'text-brand-700 dark:text-brand-400' : 'text-ink-muted')}>
              {({ isActive }) => (<>
                <span className="relative">
                  <x.icon className={clsx('h-6 w-6', isActive && 'fill-brand-100 dark:fill-brand-900')} strokeWidth={isActive ? 2.4 : 2} aria-hidden="true" />
                  {x.badge > 0 && <span className="absolute -right-2.5 -top-1.5 flex h-4 min-w-4 items-center justify-center rounded-full bg-red-600 px-1 text-[10px] font-bold text-white">{x.badge > 99 ? '99+' : x.badge}</span>}
                </span>
                {x.label}</>)}
            </NavLink>
          </li>
        ))}
      </ul>
    </nav>
  );
}
