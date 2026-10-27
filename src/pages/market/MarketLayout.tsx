import { FormEvent, useEffect, useState } from 'react';
import clsx from 'clsx';
import { Link, Outlet, useLocation, useNavigate, useSearchParams } from 'react-router-dom';
import { ChevronLeft, Search, ShoppingBag, Store, UserRound } from 'lucide-react';
import { useI18n } from '../../i18n';
import { useAuth } from '../../lib/auth';
import { useCart, useMarketConfig } from '../../lib/market';
import { LogoMark } from '../../components/Logo';
import { LanguageSwitch } from '../../components/LanguageSwitch';
import { MarketTabBar } from '../../components/market';
import { MessageBell } from '../../components/messaging';
import { Alert, Input, PageLoader } from '../../components/ui';
import { rpc } from '../../lib/api';

export function MarketLayout() {
  const { t } = useI18n();
  const { session } = useAuth();
  const { count } = useCart();
  const loc = useLocation();
  const nav = useNavigate();
  const [params] = useSearchParams();
  const [q, setQ] = useState(params.get('q') ?? '');
  const cfg = useMarketConfig();
  useEffect(() => { window.scrollTo(0, 0); }, [loc.pathname]);
  const isShop = loc.pathname.startsWith('/s/');
  // Storefronts, the cart, checkout, payment and a conversation (its message box sits at the bottom) have their
  // own footer actions, so no tab bar there.
  const tabBar = !/^\/(s\/|cart|checkout|order\/|pay\/|messages\/)/.test(loc.pathname);
  const back = () => { if (window.history.length > 1) nav(-1); else nav('/market'); };
  useEffect(() => { setQ(params.get('q') ?? ''); }, [params]);
  // A creator's link (?ref=CODE) is kept on this device and counted as a visit. Once signed in, the account is attached
  // to that creator once; the server refuses self-referrals and a second attachment.
  useEffect(() => {
    const code = params.get('ref');
    if (!code || !/^[A-Za-z0-9]{6,10}$/.test(code)) return;
    try { localStorage.setItem('bizpilot.ref', code.toUpperCase()); } catch { /* storage unavailable: still counted below */ }
    rpc('creator_track_click', { p_code: code }).catch(() => undefined);
  }, [params]);
  useEffect(() => {
    if (!session) return;
    let code: string | null = null;
    try { code = localStorage.getItem('bizpilot.ref'); } catch { code = null; }
    if (!code) return;
    rpc('creator_attach_referral', { p_code: code })
      .catch(() => undefined)
      .finally(() => { try { localStorage.removeItem('bizpilot.ref'); } catch { /* ignore */ } });
  }, [session]);
  const submit = (e: FormEvent) => {
    e.preventDefault();
    nav(`/market/search?q=${encodeURIComponent(q.trim())}`);
  };
  return (
    <div className="flex min-h-screen flex-col bg-[#f6f7f6] text-ink dark:bg-gray-950 dark:text-gray-100">
      <a href="#market-main" className="sr-only focus:not-sr-only focus:absolute focus:left-4 focus:top-4 focus:z-50 focus:rounded focus:bg-white focus:px-3 focus:py-2">{t('market.skip')}</a>
      {/* Phone header (reference): back arrow on a shop, BizPilot logo centred, search and cart. */}
      <header className="sticky top-0 z-40 border-b border-gray-200/80 bg-white/95 backdrop-blur md:hidden dark:border-gray-800 dark:bg-gray-950/95">
        <div className="relative flex h-14 items-center justify-between px-3">
          {isShop ? (
            <button type="button" onClick={back} className="flex h-10 w-10 items-center justify-center rounded-full text-ink hover:bg-gray-100 dark:text-gray-100 dark:hover:bg-gray-800" aria-label={t('common.back')}>
              <ChevronLeft className="h-6 w-6" />
            </button>
          ) : <span className="h-10 w-10" aria-hidden="true" />}
          <Link to="/market" className="absolute left-1/2 flex -translate-x-1/2 items-center gap-1.5" aria-label={t('market.title')}>
            <LogoMark className="h-8 w-8" />
            <span className="text-lg font-extrabold leading-none"><span>Biz</span><span className="text-brand-600">Pilot</span></span>
          </Link>
          <div className="flex items-center gap-1">
            <MessageBell />
            <Link to="/market/search" className="flex h-10 w-10 items-center justify-center rounded-full text-ink hover:bg-gray-100 dark:text-gray-100 dark:hover:bg-gray-800" aria-label={t('market.searchLabel')}><Search className="h-5 w-5" /></Link>
            <Link to="/cart" className="relative flex h-10 w-10 items-center justify-center rounded-full text-ink hover:bg-gray-100 dark:text-gray-100 dark:hover:bg-gray-800" aria-label={t('market.cartCount', { n: count })}>
              <ShoppingBag className="h-5 w-5" />
              {count > 0 && <span className="absolute right-0.5 top-0.5 flex h-4 min-w-4 items-center justify-center rounded-full bg-brand-600 px-1 text-[10px] font-bold text-white">{count > 99 ? '99+' : count}</span>}
            </Link>
          </div>
        </div>
      </header>
      <header className="sticky top-0 z-40 hidden border-b border-gray-200/80 bg-white/95 backdrop-blur md:block dark:border-gray-800 dark:bg-gray-950/95">
        <div className="mx-auto flex h-16 max-w-7xl items-center gap-3 px-4 sm:px-6">
          <Link to="/market" className="flex shrink-0 items-center gap-2" aria-label={t('market.title')}>
            <LogoMark className="h-9 w-9" />
            <span className="hidden leading-none sm:block">
              <span className="block text-lg font-extrabold"><span>Biz</span><span className="text-brand-600">Pilot</span></span>
              <span className="block text-[10px] font-bold uppercase tracking-[0.2em] text-ink-muted">{t('market.brandTag')}</span>
            </span>
          </Link>
          <form onSubmit={submit} className="min-w-0 flex-1" role="search">
            <label htmlFor="market-search" className="sr-only">{t('market.searchLabel')}</label>
            <Input id="market-search" type="search" value={q} onChange={(e) => setQ(e.target.value)} placeholder={t('market.searchPlaceholder')}
              prefixIcon={<Search className="h-4 w-4" />} className="rounded-full bg-gray-50 dark:bg-gray-900" />
          </form>
          <nav className="flex shrink-0 items-center gap-1" aria-label={t('market.title')}>
            <MessageBell />
            <Link to={session ? '/account' : '/login?next=/account'} className="flex items-center gap-1.5 rounded-lg p-2 text-sm font-semibold hover:bg-gray-100 dark:hover:bg-gray-800">
              <UserRound className="h-5 w-5" /><span className="hidden md:inline">{session ? t('market.myAccount') : t('market.signIn')}</span>
            </Link>
            <Link to="/cart" className="relative flex items-center gap-1.5 rounded-lg p-2 text-sm font-semibold hover:bg-gray-100 dark:hover:bg-gray-800" aria-label={t('market.cartCount', { n: count })}>
              <ShoppingBag className="h-5 w-5" /><span className="hidden md:inline">{t('market.cart')}</span>
              {count > 0 && <span className="absolute -right-0.5 -top-0.5 flex h-5 min-w-5 items-center justify-center rounded-full bg-brand-600 px-1 text-[10px] font-bold text-white">{count > 99 ? '99+' : count}</span>}
            </Link>
          </nav>
        </div>
      </header>
      <main id="market-main" className={clsx('flex-1', tabBar && 'pb-20 md:pb-0')}>
        {cfg.isLoading ? <PageLoader /> : cfg.data === null ? (
          <div className="mx-auto max-w-3xl px-4 py-16"><Alert tone="blue" title={t('market.comingSoonTitle')}>{t('market.comingSoonBody')}</Alert></div>
        ) : cfg.data && !cfg.data.enabled ? (
          <div className="mx-auto max-w-3xl px-4 py-16"><Alert tone="amber" title={t('market.closedTitle')}>{t('market.closedBody')}</Alert></div>
        ) : <Outlet />}
      </main>
      {tabBar && <MarketTabBar />}
      <footer className="hidden border-t border-gray-200 bg-white md:block dark:border-gray-800 dark:bg-gray-950">
        <div className="mx-auto grid max-w-7xl gap-6 px-4 py-8 text-sm sm:grid-cols-3 sm:px-6">
          <div>
            <p className="font-bold">{t('market.title')}</p>
            <p className="mt-1 text-ink-muted">{t('market.footerBlurb')}</p>
          </div>
          <div className="flex flex-col gap-2">
            <Link to="/market" className="hover:underline">{t('market.browse')}</Link>
            <Link to="/account" className="hover:underline">{t('market.myOrders')}</Link>
            <Link to="/contact" className="hover:underline">{t('market.help')}</Link>
          </div>
          <div className="flex flex-col gap-2">
            <Link to={session ? '/app/store' : '/signup?next=/app/store'} className="inline-flex items-center gap-1.5 font-semibold text-brand-700 hover:underline dark:text-brand-400"><Store className="h-4 w-4" />{t('market.sellCta')}</Link>
            <Link to="/terms" className="hover:underline">{t('site.footer.terms')}</Link>
            <Link to="/privacy" className="hover:underline">{t('site.footer.privacy')}</Link>
            <div className="pt-1"><LanguageSwitch /></div>
          </div>
        </div>
      </footer>
    </div>
  );
}
