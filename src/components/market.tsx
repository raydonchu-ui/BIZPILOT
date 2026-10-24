import { ReactNode, useState } from 'react';
import { Link } from 'react-router-dom';
import clsx from 'clsx';
import { BadgeCheck, Copy, Facebook, Flag, MessageCircle, Minus, Package, Plus, Share2, Star, Store } from 'lucide-react';
import { useI18n } from '../i18n';
import { formatMoney } from '../lib/format';
import { ProductCard, publicUrl, shareLinks, StoreCard } from '../lib/market';
import { rpc } from '../lib/api';
import { useAction } from '../lib/useAction';
import { useToast } from '../lib/toast';
import { Button, Field, Input, Modal, Select, Textarea } from './ui';

export function MarketImage({ path, alt, className, iconClassName, rounded = 'rounded-xl' }:
  { path: string | null | undefined; alt: string; className?: string; iconClassName?: string; rounded?: string }) {
  const [broken, setBroken] = useState(false);
  const src = publicUrl(path);
  if (!src || broken) {
    return (
      <div className={clsx('flex items-center justify-center bg-gradient-to-br from-brand-50 to-gray-100 text-brand-700/60 dark:from-gray-800 dark:to-gray-900', rounded, className)} aria-label={alt} role="img">
        <Package className={clsx('h-1/3 w-1/3', iconClassName)} />
      </div>
    );
  }
  return <img src={src} alt={alt} loading="lazy" onError={() => setBroken(true)} className={clsx('object-cover', rounded, className)} />;
}

export function Price({ value, compareAt, from, className }: { value: number; compareAt?: number | null; from?: boolean; className?: string }) {
  const { t, lang } = useI18n();
  return (
    <span className={clsx('inline-flex flex-wrap items-baseline gap-x-2', className)}>
      <span className="font-extrabold text-ink dark:text-white">{from && <span className="mr-1 text-xs font-semibold text-ink-muted">{t('market.from')}</span>}{formatMoney(value, lang)}</span>
      {compareAt ? <span className="text-xs text-ink-muted line-through">{formatMoney(compareAt, lang)}</span> : null}
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

export function ProductTile({ p }: { p: ProductCard }) {
  const { t } = useI18n();
  const out = Number(p.available) <= 0;
  return (
    <Link to={`/s/${p.store.slug}/p/${p.id}`} className="group flex flex-col overflow-hidden rounded-2xl border border-gray-200/80 bg-white shadow-card transition hover:-translate-y-0.5 hover:shadow-md dark:border-gray-800 dark:bg-gray-900">
      <div className="relative aspect-square w-full overflow-hidden bg-gray-50 dark:bg-gray-800">
        <MarketImage path={p.image} alt={p.name} rounded="" className="h-full w-full transition group-hover:scale-[1.02]" />
        {p.compare_at_price && <span className="absolute left-2 top-2 rounded-full bg-red-600 px-2 py-0.5 text-[11px] font-bold text-white">{t('market.sale')}</span>}
        {out && <span className="absolute inset-x-0 bottom-0 bg-gray-900/70 py-1 text-center text-xs font-semibold text-white">{t('market.outOfStock')}</span>}
      </div>
      <div className="flex flex-1 flex-col gap-1 p-3">
        <p className="line-clamp-2 text-sm font-semibold leading-snug text-ink dark:text-gray-100">{p.name}</p>
        <Price value={Number(p.price)} compareAt={p.compare_at_price ? Number(p.compare_at_price) : null} from={Number(p.max_price) > Number(p.price)} className="text-sm" />
        {p.rating_count > 0 && <Stars value={p.rating_avg} count={p.rating_count} />}
        <p className="mt-auto flex items-center gap-1 truncate pt-1 text-xs text-ink-muted">
          <Store className="h-3.5 w-3.5 shrink-0" /><span className="truncate">{p.store.name}</span>
          {p.store.verified && <BadgeCheck className="h-3.5 w-3.5 shrink-0 text-brand-600" aria-label={t('market.verified')} />}
          {p.store.city && <span className="truncate">· {p.store.city}</span>}
        </p>
      </div>
    </Link>
  );
}

export function ProductGrid({ items, empty }: { items: ProductCard[]; empty?: ReactNode }) {
  if (!items.length) return <>{empty}</>;
  return <div className="grid grid-cols-2 gap-3 sm:grid-cols-3 sm:gap-4 lg:grid-cols-4 xl:grid-cols-5">{items.map((p) => <ProductTile key={p.id} p={p} />)}</div>;
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
  const tone = ['paid', 'cod_collected', 'refunded'].includes(status) ? 'bg-brand-50 text-brand-800 ring-brand-600/20'
    : ['failed', 'refund_pending'].includes(status) ? 'bg-red-50 text-red-700 ring-red-600/20'
    : status === 'void' ? 'bg-gray-100 text-gray-700 ring-gray-500/20' : 'bg-amber-50 text-amber-800 ring-amber-600/20';
  return <span className={clsx('inline-flex items-center whitespace-nowrap rounded-full px-2 py-0.5 text-xs font-semibold ring-1 ring-inset', tone)}>{t(`orders.payment.${status}`)}</span>;
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
