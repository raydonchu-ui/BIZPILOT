import { FormEvent, useMemo, useState } from 'react';
import { Link, useNavigate, useSearchParams } from 'react-router-dom';
import { useQuery } from '@tanstack/react-query';
import clsx from 'clsx';
import {
  ArrowRight, Blocks, BookOpen, Car, CupSoda, Dumbbell, Filter, Footprints, Gem, Gift, Hammer, Home, LayoutGrid, Package, PawPrint, PenLine,
  Search, Shirt, ShoppingBasket, Smartphone, Sofa, Sparkles, Sprout, Store, X,
} from 'lucide-react';
import { useI18n } from '../../i18n';
import { rpc } from '../../lib/api';
import { BUSINESS_TYPES } from '../../lib/catalogTemplates';
import { ProductCard, recentlyViewed, StoreCard, useCity } from '../../lib/market';
import { useAuth } from '../../lib/auth';
import { CitySelector, ProductGrid, StoreTile } from '../../components/market';
import { Button, Checkbox, EmptyState, ErrorState, Field, Input, LinkButton, PageLoader, Select } from '../../components/ui';

export const TYPE_ICONS: Record<string, typeof Store> = {
  fashion: Shirt, footwear: Footprints, electronics: Smartphone, grocery: ShoppingBasket, supermarket: ShoppingBasket, drinks: CupSoda,
  hair_beauty: Sparkles, cosmetics: Sparkles, furniture: Sofa, hardware: Hammer, automotive: Car, sports: Dumbbell, toys: Blocks,
  books: BookOpen, stationery: PenLine, jewelry: Gem, pets: PawPrint, agriculture: Sprout, home_goods: Home, gifts: Gift, general: Store, other: Package,
};

export default function MarketHome() {
  const { t } = useI18n();
  const { session } = useAuth();
  const [city] = useCity();
  const q = useQuery({
    queryKey: ['market-home', city],
    queryFn: () => rpc<{ types: { type: string; products: number }[]; stores: StoreCard[]; cities: { city: string; shops: number }[];
      latest: ProductCard[]; city_shops: number; city_products: number }>('market_home', { p_city: city || null }),
  });
  const counts = Object.fromEntries((q.data?.types ?? []).map((x) => [x.type, x.products]));
  const types = [...BUSINESS_TYPES].sort((a, b) => (counts[b] ?? 0) - (counts[a] ?? 0));
  const place = city || t('market.cityCameroon');
  return (
    <div className="mx-auto max-w-7xl space-y-7 px-4 pb-12 pt-4 sm:px-6 sm:pt-8">
      <h1 className="sr-only">{t('market.title')}</h1>
      <div className="flex flex-col gap-3 md:flex-row md:items-center">
        <CitySelector />
        <Link to="/market/search" className="flex min-h-12 flex-1 items-center gap-2 rounded-2xl bg-white px-4 text-sm text-ink-muted shadow-xs ring-1 ring-gray-200 dark:bg-gray-900 dark:ring-gray-800" aria-label={t('market.searchLabel')}>
          <Search className="h-4 w-4" />{t('market.searchPlaceholder')}
        </Link>
      </div>

      <CityBanner place={place} shops={q.data?.city_shops ?? 0} products={q.data?.city_products ?? 0} />

      <section aria-labelledby="cats">
        <div className="mb-3 flex items-end justify-between gap-3">
          <h2 id="cats" className="text-lg font-bold">{t('market.shopByCategory')}</h2>
          <Link to="/market/categories" className="text-sm font-semibold text-brand-700 hover:underline dark:text-brand-400">{t('common.viewAll')}</Link>
        </div>
        <div className="-mx-4 flex gap-3 overflow-x-auto px-4 pb-2 sm:mx-0 sm:grid sm:grid-cols-4 sm:overflow-visible sm:px-0 lg:grid-cols-8">
          {types.slice(0, 7).map((ty) => {
            const Icon = TYPE_ICONS[ty] ?? Package;
            return (
              <Link key={ty} to={`/market/search?type=${ty}`} className="flex w-[4.75rem] shrink-0 flex-col items-center gap-2 text-center sm:w-auto">
                <span className="flex h-16 w-16 items-center justify-center rounded-2xl bg-white text-brand-700 shadow-card ring-1 ring-gray-100 dark:bg-gray-900 dark:text-brand-300 dark:ring-gray-800"><Icon className="h-7 w-7" /></span>
                <span className="text-xs font-semibold leading-tight">{t(`businessCategories.${ty}`)}</span>
              </Link>
            );
          })}
          <Link to="/market/categories" className="flex w-[4.75rem] shrink-0 flex-col items-center gap-2 text-center sm:w-auto">
            <span className="flex h-16 w-16 items-center justify-center rounded-2xl bg-white text-ink-soft shadow-card ring-1 ring-gray-100 dark:bg-gray-900 dark:ring-gray-800"><LayoutGrid className="h-7 w-7" /></span>
            <span className="text-xs font-semibold">{t('market.more')}</span>
          </Link>
        </div>
      </section>

      {q.isLoading ? <PageLoader /> : q.error ? <ErrorState error={q.error} onRetry={() => q.refetch()} /> : (
        <>
          {(q.data?.stores.length ?? 0) > 0 && (
            <section aria-labelledby="stores">
              <div className="mb-3 flex items-end justify-between gap-3">
                <h2 id="stores" className="text-lg font-bold">{city ? t('market.shopsIn', { city }) : t('market.featuredStores')}</h2>
                <Link to="/market/shops" className="text-sm font-semibold text-brand-700 hover:underline dark:text-brand-400">{t('common.viewAll')}</Link>
              </div>
              <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">{q.data!.stores.map((x) => <StoreTile key={x.business_id} s={x} />)}</div>
            </section>
          )}
          <section aria-labelledby="latest">
            <div className="mb-3 flex items-end justify-between gap-3">
              <h2 id="latest" className="text-lg font-bold">{t('market.newArrivals')}</h2>
              <Link to="/market/search?sort=newest" className="text-sm font-semibold text-brand-700 hover:underline dark:text-brand-400">{t('common.viewAll')}</Link>
            </div>
            <ProductGrid dense items={q.data?.latest ?? []} empty={<EmptyState icon={<Store className="h-6 w-6" />} title={city ? t('market.noShopsInCity', { city }) : t('market.emptyTitle')} body={t('market.emptyBody')} />} />
          </section>
        </>
      )}
      <RecentlyViewed />

      <section className="flex flex-col items-start gap-4 rounded-3xl bg-brand-950 p-6 text-white sm:flex-row sm:items-center sm:p-8">
        <div className="flex-1">
          <h2 className="text-xl font-extrabold">{t('market.sellTitle')}</h2>
          <p className="mt-1 text-sm text-gray-300">{t('market.sellBody')}</p>
        </div>
        <LinkButton to={session ? '/app/store' : '/signup?next=/app/store'} size="lg" className="bg-white !text-brand-900 hover:bg-gray-100">{t('market.sellCta')}</LinkButton>
      </section>
    </div>
  );
}

/** The city banner with the real number of shops and products there. Used on the home and the shopper dashboard. */
export function CityBanner({ place, shops, products }: { place: string; shops: number; products: number }) {
  const { t } = useI18n();
  return (
    <section aria-labelledby="banner" className="relative overflow-hidden rounded-3xl bg-linear-to-br from-brand-700 via-brand-800 to-brand-950 p-5 text-white shadow-md sm:p-8">
      <span aria-hidden="true" className="pointer-events-none absolute -right-10 -top-10 h-44 w-44 rounded-full bg-white/10" />
      <span aria-hidden="true" className="pointer-events-none absolute -bottom-12 right-10 h-32 w-32 rounded-full bg-white/10" />
      <p className="text-xs font-bold uppercase tracking-widest text-brand-100">{t('market.bannerKicker')}</p>
      <h2 id="banner" className="mt-2 max-w-md text-2xl font-extrabold leading-tight sm:text-3xl">{t('market.bannerTitle', { place })}</h2>
      <p className="mt-2 text-sm text-brand-50">{t('market.bannerStats', { shops, products })}</p>
      <Link to="/market/shops" className="mt-5 inline-flex min-h-11 items-center gap-2 rounded-xl bg-white px-5 text-sm font-bold text-brand-800 shadow-xs hover:bg-brand-50">
        {t('market.shopNow')}<ArrowRight className="h-4 w-4" />
      </Link>
    </section>
  );
}

/** Products the shopper looked at on this device, newest first. */
function RecentlyViewed() {
  const { t } = useI18n();
  const ids = useMemo(() => recentlyViewed(), []);
  const viewed = useQuery({
    queryKey: ['market-viewed', ids], enabled: ids.length > 0,
    queryFn: () => rpc<ProductCard[]>('market_products_by_ids', { p_ids: ids }),
  });
  if (!viewed.data?.length) return null;
  const ordered = [...viewed.data].sort((a, b) => ids.indexOf(a.id) - ids.indexOf(b.id)).slice(0, 8);
  return (
    <section aria-labelledby="viewed">
      <h2 id="viewed" className="mb-3 text-lg font-bold">{t('market.recentlyViewed')}</h2>
      <ProductGrid dense items={ordered} />
    </section>
  );
}

export function SearchPage() {
  const { t } = useI18n();
  const [params, setParams] = useSearchParams();
  const nav = useNavigate();
  const [showFilters, setShowFilters] = useState(false);
  const get = (k: string) => params.get(k) ?? '';
  const page = Math.max(1, Number(params.get('page') ?? 1));
  const [city] = useCity();
  const filters = { q: get('q'), type: get('type'), category: get('category'), city, min_price: get('min'), max_price: get('max'),
    in_stock: params.get('stock') === '1', sort: get('sort') || (get('q') ? 'relevance' : 'newest'), page, page_size: 24,
    min_rating: get('rating'), delivery: params.get('delivery') === '1', condition: get('condition') };
  const res = useQuery({
    queryKey: ['market-search', filters],
    queryFn: () => rpc<{ total: number; items: ProductCard[] }>('market_search', { p: filters }),
    placeholderData: (prev) => prev,
  });
  const set = (patch: Record<string, string | null>) => {
    const next = new URLSearchParams(params);
    for (const [k, v] of Object.entries(patch)) { if (v) next.set(k, v); else next.delete(k); }
    if (!('page' in patch)) next.delete('page');
    setParams(next);
  };
  const [price, setPrice] = useState({ min: get('min'), max: get('max') });
  const applyPrice = (e: FormEvent) => { e.preventDefault(); set({ min: price.min || null, max: price.max || null }); };
  const total = res.data?.total ?? 0;
  const pages = Math.ceil(total / 24);
  const title = filters.q ? t('market.resultsFor', { q: filters.q }) : filters.type ? t(`businessCategories.${filters.type}`) : t('market.allProducts');
  const active = [filters.type && { k: 'type', label: t(`businessCategories.${filters.type}`) }, filters.category && { k: 'category', label: filters.category },
    (filters.min_price || filters.max_price) && { k: 'price', label: `${filters.min_price || 0} – ${filters.max_price || '∞'} FCFA` },
    filters.in_stock && { k: 'stock', label: t('market.inStockOnly') }, filters.min_rating && { k: 'rating', label: `★ ${filters.min_rating}+` },
    filters.delivery && { k: 'delivery', label: t('market.deliversOnly') }, filters.condition && { k: 'condition', label: t(`market.condition.${filters.condition}`) }].filter(Boolean) as { k: string; label: string }[];

  const filterPanel = (
    <div className="space-y-4">
      <Field label={t('market.category')}>
        <Select value={filters.type} onChange={(e) => set({ type: e.target.value || null })}>
          <option value="">{t('market.allCategories')}</option>
          {BUSINESS_TYPES.map((ty) => <option key={ty} value={ty}>{t(`businessCategories.${ty}`)}</option>)}
        </Select>
      </Field>
      <Field label={t('market.city')} hint={t('market.cityFilterHint')}>
        <CitySelector block />
      </Field>
      <form onSubmit={applyPrice}>
        <p className="mb-1.5 text-sm font-medium text-ink-soft dark:text-gray-300">{t('market.priceRange')}</p>
        <div className="flex items-center gap-2">
          <Input aria-label={t('market.minPrice')} type="number" min="0" inputMode="numeric" placeholder={t('market.min')} value={price.min} onChange={(e) => setPrice({ ...price, min: e.target.value })} />
          <span>–</span>
          <Input aria-label={t('market.maxPrice')} type="number" min="0" inputMode="numeric" placeholder={t('market.max')} value={price.max} onChange={(e) => setPrice({ ...price, max: e.target.value })} />
        </div>
        <Button type="submit" size="sm" variant="secondary" className="mt-2">{t('market.apply')}</Button>
      </form>
      <Field label={t('market.minRating')}>
        <Select value={filters.min_rating} onChange={(e) => set({ rating: e.target.value || null })}>
          <option value="">{t('market.anyRating')}</option>
          {['4', '3'].map((r) => <option key={r} value={r}>★ {r}+</option>)}
        </Select>
      </Field>
      <Field label={t('market.conditionLabel')}>
        <Select value={filters.condition} onChange={(e) => set({ condition: e.target.value || null })}>
          <option value="">{t('market.anyCondition')}</option>
          {['new', 'like_new', 'used_good', 'used_fair', 'refurbished', 'for_parts'].map((c) => <option key={c} value={c}>{t(`market.condition.${c}`)}</option>)}
        </Select>
      </Field>
      <Checkbox label={t('market.inStockOnly')} checked={filters.in_stock} onChange={(v) => set({ stock: v ? '1' : null })} />
      <Checkbox label={t('market.deliversOnly')} checked={filters.delivery} onChange={(v) => set({ delivery: v ? '1' : null })} />
    </div>
  );

  return (
    <div className="mx-auto max-w-7xl px-4 py-6 sm:px-6">
      <div className="mb-4 flex flex-col gap-3 sm:flex-row sm:items-end sm:justify-between">
        <div>
          <h1 className="text-2xl font-extrabold tracking-tight">{title}</h1>
          <p className="text-sm text-ink-muted">{res.isFetching && !res.data ? t('common.loading') : t('market.resultsCount', { n: total })}</p>
        </div>
        <div className="flex items-center gap-2">
          <Button variant="outline" size="sm" className="lg:hidden" icon={<Filter className="h-4 w-4" />} onClick={() => setShowFilters((v) => !v)} aria-expanded={showFilters}>{t('market.filters')}</Button>
          <label htmlFor="sort" className="sr-only">{t('market.sortBy')}</label>
          <Select id="sort" className="w-auto" value={filters.sort} onChange={(e) => set({ sort: e.target.value })}>
            {['relevance', 'newest', 'price_asc', 'price_desc', 'rating'].map((s) => <option key={s} value={s}>{t(`market.sort.${s}`)}</option>)}
          </Select>
        </div>
      </div>
      {active.length > 0 && (
        <div className="mb-4 flex flex-wrap gap-2">
          {active.map((a) => (
            <button key={a.k} onClick={() => set(a.k === 'price' ? { min: null, max: null } : { [a.k]: null })}
              className="inline-flex items-center gap-1 rounded-full bg-brand-50 px-3 py-1 text-xs font-semibold text-brand-800 ring-1 ring-brand-200 dark:bg-brand-900/40 dark:text-brand-100">
              {a.label}<X className="h-3.5 w-3.5" aria-label={t('market.removeFilter')} />
            </button>
          ))}
          <button className="text-xs font-semibold text-ink-muted hover:underline" onClick={() => nav(`/market/search${filters.q ? `?q=${encodeURIComponent(filters.q)}` : ''}`)}>{t('market.clearFilters')}</button>
        </div>
      )}
      <div className="grid gap-6 lg:grid-cols-[240px_minmax(0,1fr)]">
        <aside className={clsx('rounded-2xl border border-gray-200/80 bg-white p-4 dark:border-gray-800 dark:bg-gray-900 lg:block', showFilters ? 'block' : 'hidden')} aria-label={t('market.filters')}>
          {filterPanel}
        </aside>
        <div>
          {res.error ? <ErrorState error={res.error} onRetry={() => res.refetch()} /> : !res.data ? <PageLoader /> : (
            <ProductGrid items={res.data.items} empty={
              <EmptyState icon={<Search className="h-6 w-6" />} title={t('market.noResults')} body={t('market.noResultsBody')}
                action={<LinkButton to="/market" variant="outline">{t('market.backToMarket')}</LinkButton>} />} />
          )}
          {pages > 1 && (
            <div className="mt-6 flex items-center justify-center gap-2">
              <Button variant="outline" size="sm" disabled={page <= 1} onClick={() => set({ page: String(page - 1) })}>{t('common.previous')}</Button>
              <span className="text-sm text-ink-muted">{t('market.pageOf', { page, pages })}</span>
              <Button variant="outline" size="sm" disabled={page >= pages} onClick={() => set({ page: String(page + 1) })}>{t('common.next')}</Button>
            </div>
          )}
        </div>
      </div>
    </div>
  );
}
