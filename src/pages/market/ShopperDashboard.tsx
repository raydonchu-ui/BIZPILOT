// Shopper dashboard (the Profile tab of BizPilot Market): greeting, city, search, categories, order
// progress and the account menu. Every number is read from the database for the signed-in shopper.
import { Link } from 'react-router-dom';
import { useQuery } from '@tanstack/react-query';
import clsx from 'clsx';
import { CheckCircle2, ChevronRight, Clock, HelpCircle, Heart, LayoutGrid, Package, Search, Settings, SlidersHorizontal, Truck } from 'lucide-react';
import { useI18n } from '../../i18n';
import { rpc } from '../../lib/api';
import { useAuth } from '../../lib/auth';
import { useCity } from '../../lib/market';
import { OrderStatusBadge, MarketImage, CitySelector } from '../../components/market';
import { formatXaf } from '../../lib/format';
import { TYPE_ICONS, CityBanner } from './MarketHome';

export function ShopperDashboard() {
  const { t, lang } = useI18n();
  const { session, context } = useAuth();
  const [city] = useCity();
  const place = city || t('market.cityCameroon');
  const dash = useQuery({ queryKey: ['buyer-dashboard', session?.user.id], queryFn: () => rpc<any>('buyer_dashboard') });
  const latest = useQuery({ queryKey: ['my-latest-order'], queryFn: () => rpc<any[]>('market_my_orders', { p_limit: 1, p_offset: 0 }) });
  const home = useQuery({
    queryKey: ['market-home', city],
    queryFn: () => rpc<any>('market_home', { p_city: city || null }),
  });
  const fullName = (context?.profile?.full_name ?? '').trim();
  const first = fullName.split(/\s+/)[0] ?? '';
  const initials = (fullName || session?.user.email || '?').split(/\s+/).slice(0, 2).map((x) => x[0]?.toUpperCase() ?? '').join('');
  const orders = dash.data?.orders ?? { pending: 0, processing: 0, shipped: 0, delivered: 0 };
  // The five categories of the design, always shown; the list is a way into the search, not a count of shops.
  const types = ['fashion', 'electronics', 'home_goods', 'hair_beauty', 'grocery'];
  const order = latest.data?.[0];
  const stages = [
    { key: 'pending', label: t('market.shopper.pending'), n: orders.pending, icon: Clock, cls: 'bg-amber-50 text-amber-700 dark:bg-amber-950/40 dark:text-amber-300' },
    { key: 'processing', label: t('market.shopper.processing'), n: orders.processing, icon: Package, cls: 'bg-blue-50 text-blue-700 dark:bg-blue-950/40 dark:text-blue-300' },
    { key: 'shipped', label: t('market.shopper.shipped'), n: orders.shipped, icon: Truck, cls: 'bg-violet-50 text-violet-700 dark:bg-violet-950/40 dark:text-violet-300' },
    { key: 'delivered', label: t('market.shopper.delivered'), n: orders.delivered, icon: CheckCircle2, cls: 'bg-emerald-50 text-emerald-700 dark:bg-emerald-950/40 dark:text-emerald-300' },
  ];
  return (
    <div className="mx-auto max-w-2xl space-y-6 px-4 pb-10 pt-4 sm:px-6 sm:pt-6">
      <h1 className="sr-only">{t('market.accountTitle')}</h1>
      <Link to="/account?tab=profile" className="flex items-center gap-4 rounded-2xl bg-white p-4 shadow-card ring-1 ring-gray-100 dark:bg-gray-900 dark:ring-gray-800">
        {context?.profile?.avatar_path ? (
          <MarketImage path={context.profile.avatar_path} alt="" className="h-14 w-14 shrink-0" rounded="rounded-full" />
        ) : (
          <span className="flex h-14 w-14 shrink-0 items-center justify-center rounded-full bg-brand-100 text-lg font-extrabold text-brand-800 dark:bg-brand-900 dark:text-brand-200" aria-hidden="true">{initials}</span>
        )}
        <span className="min-w-0 flex-1">
          <span className="block truncate text-xl font-extrabold tracking-tight">{first ? t('market.shopper.hello', { name: first }) : t('market.shopper.helloPlain')}</span>
          <span className="block text-sm text-ink-muted">{t('market.shopper.happy')}</span>
        </span>
        <ChevronRight className="h-5 w-5 shrink-0 text-ink-soft" aria-hidden="true" />
      </Link>

      <CitySelector block />

      <div className="flex items-center gap-2">
        <Link to="/market/search" className="flex min-h-12 flex-1 items-center gap-2 rounded-2xl bg-white px-4 text-sm text-ink-muted shadow-xs ring-1 ring-gray-200 dark:bg-gray-900 dark:ring-gray-800" aria-label={t('market.searchLabel')}>
          <Search className="h-4 w-4" />{t('market.shopper.searchPlaceholder')}
        </Link>
        <Link to="/market/search" aria-label={t('market.shopper.filters')} className="flex h-12 w-12 shrink-0 items-center justify-center rounded-2xl bg-white text-ink shadow-xs ring-1 ring-gray-200 dark:bg-gray-900 dark:text-gray-100 dark:ring-gray-800">
          <SlidersHorizontal className="h-5 w-5" />
        </Link>
      </div>

      <CityBanner place={place} shops={home.data?.city_shops ?? 0} products={home.data?.city_products ?? 0} />

      <section aria-labelledby="dash-cats">
        <h2 id="dash-cats" className="sr-only">{t('market.shopByCategory')}</h2>
        <div className="grid grid-cols-6 gap-1">
          {types.map((ty) => {
            const Icon = TYPE_ICONS[ty] ?? Package;
            return (
              <Link key={ty} to={`/market/search?type=${ty}`} className="flex flex-col items-center gap-1.5 text-center">
                <span className="flex h-14 w-14 items-center justify-center rounded-2xl bg-white text-brand-700 shadow-card ring-1 ring-gray-100 dark:bg-gray-900 dark:text-brand-300 dark:ring-gray-800"><Icon className="h-6 w-6" /></span>
                <span className="line-clamp-2 text-[11px] font-semibold leading-tight">{t(`businessCategories.${ty}`)}</span>
              </Link>
            );
          })}
          <Link to="/market/categories" className="flex flex-col items-center gap-1.5 text-center">
            <span className="flex h-14 w-14 items-center justify-center rounded-2xl bg-white text-ink-soft shadow-card ring-1 ring-gray-100 dark:bg-gray-900 dark:ring-gray-800"><LayoutGrid className="h-6 w-6" /></span>
            <span className="text-[11px] font-semibold">{t('market.more')}</span>
          </Link>
        </div>
      </section>

      <section aria-labelledby="dash-orders" className="space-y-3">
        <div className="flex items-center justify-between">
          <h2 id="dash-orders" className="text-lg font-extrabold">{t('market.shopper.myOrders')}</h2>
          <Link to="/account?tab=orders" className="text-sm font-semibold text-brand-700 hover:underline dark:text-brand-400">{t('market.shopper.viewAll')}</Link>
        </div>
        <div className="grid grid-cols-4 gap-2">
          {stages.map((s) => (
            <Link key={s.key} to="/account?tab=orders" className={clsx('flex flex-col items-center gap-1 rounded-2xl px-1 py-3 text-center', s.cls)}>
              <s.icon className="h-6 w-6" aria-hidden="true" />
              <span className="text-[11px] font-semibold leading-tight">{s.label}</span>
              <span className="text-lg font-extrabold tabular-nums">{s.n}</span>
            </Link>
          ))}
        </div>
        {order ? (
          <Link to={`/order/${order.id}`} className="flex items-center gap-3 rounded-2xl bg-white p-3 shadow-card ring-1 ring-gray-100 dark:bg-gray-900 dark:ring-gray-800">
            <MarketImage path={order.first_image} alt="" className="h-14 w-14 shrink-0" />
            <span className="min-w-0 flex-1">
              <span className="block truncate font-bold">{order.store.name}</span>
              <span className="mt-0.5 block text-xs text-ink-muted">{order.number}</span>
              <span className="mt-1 flex flex-wrap items-center gap-2"><OrderStatusBadge status={order.status} /><span className="text-sm font-extrabold">{formatXaf(order.total, lang)}</span></span>
            </span>
            <ChevronRight className="h-5 w-5 shrink-0 text-ink-soft" aria-hidden="true" />
          </Link>
        ) : (
          <p className="rounded-2xl bg-white p-4 text-sm text-ink-muted shadow-card ring-1 ring-gray-100 dark:bg-gray-900 dark:ring-gray-800">
            {t('market.shopper.noOrders')} <Link to="/market" className="font-semibold text-brand-700 hover:underline dark:text-brand-400">{t('market.startShopping')}</Link>
          </p>
        )}
      </section>

      <section aria-labelledby="dash-account" className="space-y-2">
        <h2 id="dash-account" className="text-lg font-extrabold">{t('market.shopper.account')}</h2>
        <ul className="divide-y divide-gray-100 overflow-hidden rounded-2xl bg-white shadow-card ring-1 ring-gray-100 dark:divide-gray-800 dark:bg-gray-900 dark:ring-gray-800">
          {[
            { to: '/account?tab=wishlist', label: t('market.shopper.favorites'), icon: Heart, cls: 'text-rose-500', count: dash.data?.favorites },
            { to: '/contact', label: t('market.shopper.help'), icon: HelpCircle, cls: 'text-violet-500', count: undefined },
            { to: '/account?tab=profile', label: t('market.shopper.settings'), icon: Settings, cls: 'text-slate-600 dark:text-slate-300', count: undefined },
          ].map((x) => (
            <li key={x.to}>
              <Link to={x.to} className="flex min-h-14 items-center gap-3 px-4 py-3 hover:bg-gray-50 dark:hover:bg-gray-800/60">
                <x.icon className={clsx('h-5 w-5 shrink-0', x.cls)} aria-hidden="true" />
                <span className="flex-1 font-semibold">{x.label}</span>
                {x.count !== undefined && <span className="text-sm text-ink-muted">{x.count}</span>}
                <ChevronRight className="h-4 w-4 text-ink-soft" aria-hidden="true" />
              </Link>
            </li>
          ))}
        </ul>
      </section>
    </div>
  );
}
