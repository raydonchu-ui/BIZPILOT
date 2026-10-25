import { FormEvent, useMemo, useState } from 'react';
import { Link, useNavigate, useSearchParams } from 'react-router-dom';
import { useQuery } from '@tanstack/react-query';
import clsx from 'clsx';
import {
  Blocks, BookOpen, Car, CupSoda, Dumbbell, Filter, Footprints, Gem, Gift, Hammer, Home, MapPin, Package, PawPrint, PenLine,
  Search, Shirt, ShoppingBasket, Smartphone, Sofa, Sparkles, Sprout, Store, X,
} from 'lucide-react';
import { useI18n } from '../../i18n';
import { rpc } from '../../lib/api';
import { BUSINESS_TYPES } from '../../lib/catalogTemplates';
import { ProductCard, recentlyViewed, StoreCard } from '../../lib/market';
import { useAuth } from '../../lib/auth';
import { ProductGrid, StoreTile } from '../../components/market';
import { Button, Checkbox, EmptyState, ErrorState, Field, Input, LinkButton, PageLoader, Select } from '../../components/ui';

export const TYPE_ICONS: Record<string, typeof Store> = {
  fashion: Shirt, footwear: Footprints, electronics: Smartphone, grocery: ShoppingBasket, supermarket: ShoppingBasket, drinks: CupSoda,
  hair_beauty: Sparkles, cosmetics: Sparkles, furniture: Sofa, hardware: Hammer, automotive: Car, sports: Dumbbell, toys: Blocks,
  books: BookOpen, stationery: PenLine, jewelry: Gem, pets: PawPrint, agriculture: Sprout, home_goods: Home, gifts: Gift, general: Store, other: Package,
};

export default function MarketHome() {
  const { t } = useI18n();
  const { session } = useAuth();
  const [city, setCityState] = useState<string>(() => { try { return localStorage.getItem('bizpilot.city') ?? ''; } catch { return ''; } });
  const setCity = (c: string) => { setCityState(c); try { localStorage.setItem('bizpilot.city', c); } catch { /* private mode */ } };
  const viewedIds = useMemo(() => recentlyViewed(), []);
  const viewed = useQuery({
    queryKey: ['market-viewed', viewedIds], enabled: viewedIds.length > 0,
    queryFn: () => rpc<ProductCard[]>('market_products_by_ids', { p_ids: viewedIds }),
  });
  const q = useQuery({
    queryKey: ['market-home', city],
    queryFn: () => rpc<{ types: { type: string; products: number }[]; stores: StoreCard[]; cities: string[]; latest: ProductCard[] }>('market_home', { p_city: city || null }),
  });
  const counts = Object.fromEntries((q.data?.types ?? []).map((x) => [x.type, x.products]));
  const types = [...BUSINESS_TYPES].sort((a, b) => (counts[b] ?? 0) - (counts[a] ?? 0));
  return (
    <div>
      <section className="bg-gradient-to-b from-brand-50 to-transparent dark:from-brand-950/40">
        <div className="mx-auto max-w-7xl px-4 pb-6 pt-8 sm:px-6 sm:pt-12">
          <h1 className="max-w-2xl text-3xl font-extrabold tracking-tight sm:text-4xl">{t('market.heroTitle')}</h1>
          <p className="mt-2 max-w-2xl text-ink-soft dark:text-gray-300">{t('market.heroBody')}</p>
          {(q.data?.cities.length ?? 0) > 0 && (
            <div className="mt-5 flex flex-wrap items-center gap-2" aria-label={t('market.city')}>
              <MapPin className="h-4 w-4 text-ink-muted" />
              {['', ...(q.data?.cities ?? [])].map((c) => (
                <button key={c || 'all'} onClick={() => setCity(c)} aria-pressed={city === c}
                  className={clsx('rounded-full px-3 py-1 text-sm font-semibold ring-1', city === c ? 'bg-brand-700 text-white ring-brand-700' : 'bg-white text-ink-soft ring-gray-200 hover:bg-gray-50 dark:bg-gray-900 dark:text-gray-300 dark:ring-gray-800')}>
                  {c || t('market.allCities')}
                </button>
              ))}
            </div>
          )}
        </div>
      </section>

      <div className="mx-auto max-w-7xl space-y-10 px-4 pb-12 sm:px-6">
        <section aria-labelledby="cats">
          <h2 id="cats" className="mb-3 text-lg font-bold">{t('market.shopByCategory')}</h2>
          <div className="-mx-4 flex gap-2 overflow-x-auto px-4 pb-2 sm:mx-0 sm:grid sm:grid-cols-4 sm:overflow-visible sm:px-0 lg:grid-cols-6 xl:grid-cols-8">
            {types.map((ty) => {
              const Icon = TYPE_ICONS[ty] ?? Package;
              return (
                <Link key={ty} to={`/market/search?type=${ty}${city ? `&city=${encodeURIComponent(city)}` : ''}`}
                  className="flex w-28 shrink-0 flex-col items-center gap-2 rounded-2xl border border-gray-200/80 bg-white p-3 text-center shadow-card transition hover:border-brand-300 dark:border-gray-800 dark:bg-gray-900 sm:w-auto">
                  <span className="flex h-11 w-11 items-center justify-center rounded-xl bg-brand-50 text-brand-700 dark:bg-brand-900/40 dark:text-brand-300"><Icon className="h-5 w-5" /></span>
                  <span className="text-xs font-semibold leading-tight">{t(`businessCategories.${ty}`)}</span>
                  {counts[ty] ? <span className="text-[11px] text-ink-muted">{t('market.productsCount', { n: counts[ty] })}</span> : null}
                </Link>
              );
            })}
          </div>
        </section>

        {q.isLoading ? <PageLoader /> : q.error ? <ErrorState error={q.error} onRetry={() => q.refetch()} /> : (
          <>
            {(q.data?.stores.length ?? 0) > 0 && (
              <section aria-labelledby="stores">
                <h2 id="stores" className="mb-3 text-lg font-bold">{t('market.featuredStores')}</h2>
                <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">{q.data!.stores.map((s) => <StoreTile key={s.business_id} s={s} />)}</div>
              </section>
            )}
            {(viewed.data?.length ?? 0) > 0 && (
              <section aria-labelledby="viewed">
                <h2 id="viewed" className="mb-3 text-lg font-bold">{t('market.recentlyViewed')}</h2>
                <ProductGrid items={[...viewed.data!].sort((a, b) => viewedIds.indexOf(a.id) - viewedIds.indexOf(b.id)).slice(0, 8)} />
              </section>
            )}
            <section aria-labelledby="latest">
              <div className="mb-3 flex items-end justify-between gap-3">
                <h2 id="latest" className="text-lg font-bold">{t('market.newArrivals')}</h2>
                <Link to="/market/search?sort=newest" className="text-sm font-semibold text-brand-700 hover:underline dark:text-brand-400">{t('common.viewAll')}</Link>
              </div>
              <ProductGrid items={q.data?.latest ?? []} empty={<EmptyState icon={<Store className="h-6 w-6" />} title={t('market.emptyTitle')} body={t('market.emptyBody')} />} />
            </section>
          </>
        )}

        <section className="flex flex-col items-start gap-4 rounded-3xl bg-brand-950 p-6 text-white sm:flex-row sm:items-center sm:p-8">
          <div className="flex-1">
            <h2 className="text-xl font-extrabold">{t('market.sellTitle')}</h2>
            <p className="mt-1 text-sm text-gray-300">{t('market.sellBody')}</p>
          </div>
          <LinkButton to={session ? '/app/store' : '/signup?next=/app/store'} size="lg" className="bg-white !text-brand-900 hover:bg-gray-100">{t('market.sellCta')}</LinkButton>
        </section>
      </div>
    </div>
  );
}

export function SearchPage() {
  const { t } = useI18n();
  const [params, setParams] = useSearchParams();
  const nav = useNavigate();
  const [showFilters, setShowFilters] = useState(false);
  const get = (k: string) => params.get(k) ?? '';
  const page = Math.max(1, Number(params.get('page') ?? 1));
  const filters = { q: get('q'), type: get('type'), category: get('category'), city: get('city'), min_price: get('min'), max_price: get('max'),
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
    filters.city && { k: 'city', label: filters.city }, (filters.min_price || filters.max_price) && { k: 'price', label: `${filters.min_price || 0} – ${filters.max_price || '∞'} FCFA` },
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
      <Field label={t('market.city')}>
        <Input value={filters.city} placeholder={t('market.cityPlaceholder')} onChange={(e) => set({ city: e.target.value || null })} />
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
