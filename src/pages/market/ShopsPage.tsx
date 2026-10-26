// Shops and categories for the chosen city: the "Shops" and "Categories" tabs of BizPilot Market.
import { FormEvent, useState } from 'react';
import { Link, useSearchParams } from 'react-router-dom';
import { useQuery } from '@tanstack/react-query';
import clsx from 'clsx';
import { LayoutGrid, Package, Search, Store } from 'lucide-react';
import { useI18n } from '../../i18n';
import { rpc } from '../../lib/api';
import { BUSINESS_TYPES } from '../../lib/catalogTemplates';
import { StoreCard, useCity } from '../../lib/market';
import { CitySelector, StoreTile } from '../../components/market';
import { EmptyState, ErrorState, Input, PageLoader } from '../../components/ui';
import { TYPE_ICONS } from './MarketHome';

export function ShopsPage() {
  const { t } = useI18n();
  const [city] = useCity();
  const [params, setParams] = useSearchParams();
  const type = params.get('type') ?? '';
  const [text, setText] = useState(params.get('q') ?? '');
  const [page, setPage] = useState(1);
  const cats = useQuery({
    queryKey: ['market-home', city],
    queryFn: () => rpc<{ types: { type: string; products: number }[] }>('market_home', { p_city: city || null }),
  });
  const shops = useQuery({
    queryKey: ['market-shops', city, type, params.get('q') ?? '', page],
    queryFn: () => rpc<{ total: number; items: StoreCard[] }>('market_shops', { p: { city: city || null, type: type || null, q: params.get('q') || null, page, page_size: 24 } }),
    placeholderData: (prev) => prev,
  });
  const set = (patch: Record<string, string | null>) => {
    const next = new URLSearchParams(params);
    for (const [k, v] of Object.entries(patch)) { if (v) next.set(k, v); else next.delete(k); }
    setParams(next, { replace: true });
    setPage(1);
  };
  const submit = (e: FormEvent) => { e.preventDefault(); set({ q: text.trim() || null }); };
  const total = shops.data?.total ?? 0;
  const hasMore = page * 24 < total;
  const place = city || t('market.allCameroon');
  return (
    <div className="mx-auto max-w-7xl space-y-5 px-4 pb-12 pt-4 sm:px-6 sm:pt-8">
      <div className="flex flex-col gap-3 md:flex-row md:items-center">
        <CitySelector />
        <form onSubmit={submit} className="min-w-0 flex-1" role="search">
          <label htmlFor="shop-search" className="sr-only">{t('market.searchShops')}</label>
          <Input id="shop-search" type="search" value={text} onChange={(e) => setText(e.target.value)} placeholder={t('market.searchShops')} prefixIcon={<Search className="h-4 w-4" />} />
        </form>
      </div>
      <div>
        <h1 className="text-2xl font-extrabold tracking-tight">{t('market.shopsTitle')}</h1>
        <p className="text-sm text-ink-muted">{shops.isFetching && !shops.data ? t('common.loading') : t('market.shopsResults', { n: total, place })}</p>
      </div>
      <div className="-mx-4 flex gap-2 overflow-x-auto px-4 pb-1 sm:mx-0 sm:flex-wrap sm:px-0" role="group" aria-label={t('market.categories')}>
        <button type="button" aria-pressed={!type} onClick={() => set({ type: null })} className={chip(!type)}>{t('market.allCategories')}</button>
        {(cats.data?.types ?? []).map((x) => (
          <button key={x.type} type="button" aria-pressed={type === x.type} onClick={() => set({ type: x.type })} className={chip(type === x.type)}>
            {t(`businessCategories.${x.type}`)}
          </button>
        ))}
      </div>
      {shops.isLoading ? <PageLoader /> : shops.error ? <ErrorState error={shops.error} onRetry={() => shops.refetch()} /> : total === 0 ? (
        <EmptyState icon={<Store className="h-6 w-6" />} title={city ? t('market.noShopsInCity', { city }) : t('market.noShops')} body={t('market.noShopsBody')} />
      ) : (
        <>
          <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">{shops.data!.items.map((s) => <StoreTile key={s.business_id} s={s} />)}</div>
          {hasMore && <div className="flex justify-center"><button type="button" onClick={() => setPage((p) => p + 1)} className="min-h-11 rounded-xl border border-gray-300 px-5 text-sm font-semibold hover:bg-gray-50 dark:border-gray-700 dark:hover:bg-gray-800">{t('market.loadMore')}</button></div>}
        </>
      )}
    </div>
  );
}

function chip(active: boolean) {
  return clsx('whitespace-nowrap rounded-full px-4 py-2 text-sm font-semibold ring-1 transition',
    active ? 'bg-brand-700 text-white ring-brand-700' : 'bg-white text-ink-soft ring-gray-200 dark:bg-gray-900 dark:text-gray-300 dark:ring-gray-800');
}

/** Every kind of shop, with how many products each kind has in the chosen city. */
export function CategoriesPage() {
  const { t } = useI18n();
  const [city] = useCity();
  const cats = useQuery({
    queryKey: ['market-home', city],
    queryFn: () => rpc<{ types: { type: string; products: number }[] }>('market_home', { p_city: city || null }),
  });
  if (cats.isLoading) return <PageLoader />;
  if (cats.error) return <ErrorState error={cats.error} onRetry={() => cats.refetch()} />;
  const counts = Object.fromEntries((cats.data?.types ?? []).map((x) => [x.type, x.products]));
  const present = BUSINESS_TYPES.filter((ty) => counts[ty]).sort((a, b) => (counts[b] ?? 0) - (counts[a] ?? 0));
  return (
    <div className="mx-auto max-w-7xl space-y-5 px-4 pb-12 pt-4 sm:px-6 sm:pt-8">
      <CitySelector />
      <div>
        <h1 className="flex items-center gap-2 text-2xl font-extrabold tracking-tight"><LayoutGrid className="h-6 w-6 text-brand-700" />{t('market.categoriesTitle')}</h1>
        <p className="text-sm text-ink-muted">{t('market.categoriesSub', { place: city || t('market.allCameroon') })}</p>
      </div>
      {present.length === 0 ? (
        <EmptyState icon={<Package className="h-6 w-6" />} title={city ? t('market.noShopsInCity', { city }) : t('market.noShops')} body={t('market.noShopsBody')} />
      ) : (
        <div className="grid grid-cols-2 gap-3 sm:grid-cols-3 lg:grid-cols-4">
          {present.map((ty) => {
            const Icon = TYPE_ICONS[ty] ?? Package;
            return (
              <Link key={ty} to={`/market/shops?type=${ty}`} className="flex items-center gap-3 rounded-2xl border border-gray-200/80 bg-white p-4 shadow-card transition hover:shadow-md dark:border-gray-800 dark:bg-gray-900">
                <span className="flex h-12 w-12 shrink-0 items-center justify-center rounded-xl bg-brand-50 text-brand-700 dark:bg-brand-900/40 dark:text-brand-300"><Icon className="h-6 w-6" /></span>
                <span className="min-w-0">
                  <span className="block truncate font-bold">{t(`businessCategories.${ty}`)}</span>
                  <span className="block text-xs text-ink-muted">{t('market.productsCount', { n: counts[ty] })}</span>
                </span>
              </Link>
            );
          })}
        </div>
      )}
    </div>
  );
}
