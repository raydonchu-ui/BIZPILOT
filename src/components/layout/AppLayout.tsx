import { ReactNode, useEffect, useMemo, useRef, useState } from 'react';
import { Link, NavLink, Outlet, useLocation, useNavigate } from 'react-router-dom';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import clsx from 'clsx';
import {
  BadgePercent, BarChart3, Bell, Bot, Boxes, ChevronDown, ClipboardCheck, CreditCard, ExternalLink, FolderTree, HelpCircle, Home, LayoutDashboard, Lock, Sparkles,
  LogOut, Menu, MessageSquare, Moon, MoreHorizontal, Package, PackageCheck, Plus, Receipt, Search, Settings, ShieldCheck, ShoppingBag,
  ShoppingCart, Sun, Truck, Upload, UserCog, Users, Wallet, WifiOff, X, Megaphone, Store,
} from 'lucide-react';
import { useI18n } from '../../i18n';
import { useAuth } from '../../lib/auth';
import { useStoreLockActions } from '../StoreLock';
import { useBiz } from '../../lib/business';
import { rpc, unwrap } from '../../lib/api';
import { supabase } from '../../lib/supabase';
import { formatDate, formatRelative } from '../../lib/format';
import { applyTheme, getTheme, Theme } from '../../lib/theme';
import { LogoMark } from '../Logo';
import { LanguageSwitch } from '../LanguageSwitch';
import { Badge, Button, Input } from '../ui';
import { useOfflineQueue } from '../../lib/offline';
import { notificationText } from '../../pages/app/notificationsText';
import { useMarketConfig } from '../../lib/market';

/** Marketplace summary for the seller (orders to confirm, store readiness). Null when not available. */
export function useSellerSummary() {
  const { id, can } = useBiz();
  const market = useMarketConfig().data;
  return useQuery({
    queryKey: ['seller-summary', id],
    enabled: Boolean(market) && can('orders.manage'),
    refetchInterval: 60_000,
    queryFn: () => rpc<any>('seller_market_summary', { p_business: id }),
  });
}

interface NavItem {
  to: string; key: string; icon: typeof Home; group: NavGroup; perm?: string; feature?: string; badge?: string; end?: boolean;
  /** Needs the marketplace database upgrade. */
  market?: boolean;
}
export type NavGroup = 'main' | 'online' | 'shop' | 'catalog' | 'buy' | 'money' | 'insights' | 'business';
export const NAV_GROUPS: NavGroup[] = ['main', 'online', 'shop', 'catalog', 'buy', 'money', 'insights', 'business'];

export const NAV: NavItem[] = [
  { to: '/app', key: 'dashboard', icon: LayoutDashboard, end: true, group: 'main' },
  { to: '/app/store', key: 'myStore', icon: Store, perm: 'store.manage', group: 'online' },
  { to: '/app/orders', key: 'orders', icon: PackageCheck, perm: 'orders.manage', group: 'online', market: true },
  { to: '/app/messages', key: 'messages', icon: MessageSquare, perm: 'orders.manage', group: 'online', market: true },
  { to: '/app/promotions', key: 'promotions', icon: BadgePercent, perm: 'store.manage', feature: 'promotions', group: 'online', market: true },
  { to: '/app/sales', key: 'sales', icon: ShoppingCart, perm: 'sales.view', group: 'shop' },
  { to: '/app/customers', key: 'customers', icon: Users, perm: 'customers.manage', group: 'shop' },
  { to: '/app/products', key: 'products', icon: Package, perm: 'products.view', group: 'catalog' },
  { to: '/app/products/categories', key: 'categories', icon: FolderTree, perm: 'products.manage', group: 'catalog' },
  { to: '/app/inventory', key: 'inventory', icon: Boxes, perm: 'inventory.view', group: 'catalog' },
  { to: '/app/purchases', key: 'purchases', icon: ShoppingBag, perm: 'purchases.manage', feature: 'purchases', group: 'buy' },
  { to: '/app/suppliers', key: 'suppliers', icon: Truck, perm: 'purchases.manage', feature: 'suppliers', group: 'buy' },
  { to: '/app/payments', key: 'payments', icon: CreditCard, perm: 'cash.manage', group: 'money', market: true },
  { to: '/app/cash', key: 'cash', icon: Wallet, perm: 'cash.manage', group: 'money' },
  { to: '/app/expenses', key: 'expenses', icon: Receipt, perm: 'expenses.manage', feature: 'expenses', group: 'money' },
  { to: '/app/reports', key: 'reports', icon: BarChart3, perm: 'reports.view', group: 'insights' },
  { to: '/app/advisor', key: 'advisor', icon: Bot, perm: 'reports.view', badge: 'new', group: 'insights' },
  { to: '/app/manager', key: 'manager', icon: Sparkles, perm: 'reports.view', feature: 'ai_business_manager', badge: 'premium', group: 'insights' },
  { to: '/app/staff', key: 'staff', icon: UserCog, perm: 'staff.manage', group: 'business' },
  { to: '/app/settings', key: 'settings', icon: Settings, perm: 'settings.manage', group: 'business' },
];

export function useVisibleNav() {
  const { can, biz } = useBiz();
  const market = useMarketConfig().data;
  // Before the marketplace database update the server knows no store permission: owners still see
  // My Store, which explains the update.
  return NAV.filter((n) => (!n.perm || can(n.perm) || (n.perm === 'store.manage' && !market && biz.role === 'owner'))
    && (!n.market || Boolean(market)));
}

/** The nav entry that best matches the current path (longest prefix), so nested pages stay highlighted. */
export function activeNav(path: string, items: NavItem[]) {
  return items.filter((n) => (n.end ? path === n.to : path === n.to || path.startsWith(`${n.to}/`)))
    .sort((a, b) => b.to.length - a.to.length)[0]?.to;
}

export function AppLayout() {
  const { t } = useI18n();
  const { biz, id } = useBiz();
  const [drawer, setDrawer] = useState(false);
  const [quick, setQuick] = useState(false);
  const [search, setSearch] = useState(false);
  const loc = useLocation();
  const qc = useQueryClient();
  useEffect(() => { setDrawer(false); setQuick(false); }, [loc.pathname]);

  // Generate alerts from current records once per business per session.
  useEffect(() => {
    const key = `alerts:${id}`;
    if (sessionStorage.getItem(key)) return;
    sessionStorage.setItem(key, '1');
    rpc('generate_alerts', { p_business: id }).then(() => qc.invalidateQueries({ queryKey: ['notifications', id] })).catch(() => {});
  }, [id, qc]);

  // Business language preference drives the UI language on first load.
  const { setLang } = useI18n();
  useEffect(() => {
    try { if (!localStorage.getItem('bizpilot.lang')) setLang(biz.language); } catch { /* ignore */ }
  }, [biz.language, setLang]);

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === 'k') { e.preventDefault(); setSearch(true); }
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, []);

  return (
    <div className="min-h-screen bg-[#f5f7f6] text-ink dark:bg-gray-950 dark:text-gray-100">
      <a href="#app-main" className="sr-only focus:not-sr-only focus:absolute focus:left-4 focus:top-4 focus:z-50 focus:rounded focus:bg-white focus:px-3 focus:py-2">Skip to content</a>
      <aside className="fixed inset-y-0 left-0 z-30 hidden w-64 flex-col bg-brand-950 text-gray-200 lg:flex print:hidden">
        <SidebarContent />
      </aside>

      {drawer && (
        <div className="fixed inset-0 z-50 lg:hidden print:hidden" role="dialog" aria-modal="true">
          <div className="absolute inset-0 bg-black/50" onClick={() => setDrawer(false)} />
          <aside className="absolute inset-y-0 left-0 flex w-72 flex-col bg-brand-950 text-gray-200 shadow-xl">
            <button className="absolute right-3 top-3 rounded-lg p-1.5 text-gray-300 hover:bg-white/10" onClick={() => setDrawer(false)} aria-label={t('common.close')}><X className="h-5 w-5" /></button>
            <SidebarContent />
          </aside>
        </div>
      )}

      <div className="lg:pl-64">
        <Topbar onMenu={() => setDrawer(true)} onSearch={() => setSearch(true)} />
        <Banners />
        <main id="app-main" className="mx-auto max-w-[1400px] px-4 pb-28 pt-4 sm:px-6 lg:pb-10 lg:pt-6">
          <Outlet />
        </main>
      </div>

      <BottomNav onQuick={() => setQuick(true)} />
      {quick && <QuickActions onClose={() => setQuick(false)} />}
      {search && <GlobalSearch onClose={() => setSearch(false)} />}
    </div>
  );
}

function SidebarContent() {
  const { t, lang } = useI18n();
  const { biz, has, can } = useBiz();
  const items = useVisibleNav();
  const loc = useLocation();
  const current = activeNav(loc.pathname, items);
  const summary = useSellerSummary();
  const toConfirm = Number(summary.data?.to_confirm ?? 0);
  const sub = biz.subscription;
  const planName = lang === 'fr' ? biz.plan.name_fr : biz.plan.name_en;
  const renew = sub.state === 'trial' ? sub.trial_ends_at : sub.current_period_end;
  return (
    <>
      <div className="m-3 rounded-xl bg-white px-3 py-2.5">
        <Link to="/app" className="flex items-center gap-2" aria-label="BizPilot">
          <LogoMark className="h-9 w-9" />
          <span className="leading-none">
            <span className="text-xl font-extrabold tracking-tight"><span className="text-ink">Biz</span><span className="text-brand-600">Pilot</span></span>
            <span className="mt-1 block text-[7.5px] font-bold uppercase tracking-[0.2em] text-ink-soft">{t('brand.tagline')}</span>
          </span>
        </Link>
      </div>
      <nav className="flex-1 space-y-0.5 overflow-y-auto px-3 py-2" aria-label="App">
        {NAV_GROUPS.map((g) => {
          const groupItems = items.filter((n) => n.group === g);
          if (!groupItems.length) return null;
          return (
            <div key={g} className={g === 'main' ? '' : 'pt-2.5'}>
              {g !== 'main' && <p className="px-3 pb-1 text-[11px] font-bold uppercase tracking-wider text-gray-400">{t(`navGroups.${g}`)}</p>}
              {groupItems.map((n) => {
                const locked = n.feature && !has(n.feature);
                const active = current === n.to;
                return (
                  <Link key={n.to} to={n.to} aria-current={active ? 'page' : undefined}
                    className={clsx('flex items-center gap-3 rounded-xl px-3 py-[7px] text-[15px] font-medium transition',
                      active ? 'bg-brand-600 text-white shadow-sm' : 'text-gray-200 hover:bg-white/10 hover:text-white')}>
                    <n.icon className="h-5 w-5 shrink-0" />
                    <span className="flex-1 truncate">{t(`nav.${n.key}`)}</span>
                    {n.key === 'orders' && toConfirm > 0 ? <span className="rounded-full bg-amber-400 px-2 py-0.5 text-[10px] font-bold text-gray-900" aria-label={t('orders.toConfirmCount', { n: toConfirm })}>{toConfirm}</span>
                      : locked ? <Lock className="h-3.5 w-3.5 opacity-60" /> : n.badge && <span className="rounded-full bg-brand-500 px-2 py-0.5 text-[10px] font-bold text-white">{t(n.badge === 'premium' ? 'nav.premiumBadge' : 'nav.newBadge')}</span>}
                  </Link>
                );
              })}
            </div>
          );
        })}
        {can('store.manage') && summary.data?.readiness?.published && summary.data.readiness.slug && (
          <a href={`/s/${summary.data.readiness.slug}`} target="_blank" rel="noopener noreferrer" className="mt-3 flex items-center gap-3 rounded-xl px-3 py-2 text-sm text-brand-200 hover:bg-white/10">
            <ExternalLink className="h-5 w-5" />{t('nav.viewStore')}
          </a>
        )}
        <div className="my-3 border-t border-white/10" />
        <NavLink to="/app/help" className={({ isActive }) => clsx('flex items-center gap-3 rounded-xl px-3 py-2 text-sm', isActive ? 'bg-white/10 text-white' : 'text-gray-300 hover:bg-white/10')}><HelpCircle className="h-5 w-5" />{t('nav.help')}</NavLink>
        <NavLink to="/app/help?feedback=1" className="flex items-center gap-3 rounded-xl px-3 py-2 text-sm text-gray-300 hover:bg-white/10"><MessageSquare className="h-5 w-5" />{t('nav.feedback')}</NavLink>
      </nav>
      <div className="m-3 rounded-xl bg-white/5 p-4 ring-1 ring-white/10">
        <div className="flex items-center gap-2">
          <span className="flex h-7 w-7 items-center justify-center rounded-full bg-brand-500 text-white"><ShieldCheck className="h-4 w-4" /></span>
          <div className="min-w-0">
            <p className="truncate text-sm font-bold text-white">{planName}</p>
            <p className={clsx('text-xs font-semibold', ['grace', 'expired', 'suspended'].includes(sub.state) ? 'text-amber-300' : 'text-brand-300')}>{t(`subscriptionState.${sub.state}`)}</p>
          </div>
        </div>
        {renew && <p className="mt-2 text-xs text-gray-400">{t('billing.renews', { date: formatDate(renew, lang) })}</p>}
        <Link to="/app/billing" className="mt-3 block rounded-lg bg-brand-600 py-2 text-center text-sm font-semibold text-white hover:bg-brand-500">{t('billing.managePlan')}</Link>
      </div>
    </>
  );
}

function Topbar({ onMenu, onSearch }: { onMenu: () => void; onSearch: () => void }) {
  const { t } = useI18n();
  return (
    <header className="sticky top-0 z-20 border-b border-gray-200/70 bg-white/90 backdrop-blur dark:border-gray-800 dark:bg-gray-950/90 print:hidden">
      <div className="mx-auto flex h-16 max-w-[1400px] items-center gap-3 px-4 sm:px-6">
        <button className="rounded-lg p-2 lg:hidden" onClick={onMenu} aria-label={t('common.menu')}><Menu className="h-6 w-6" /></button>
        <Link to="/app" className="flex items-center gap-1.5 lg:hidden">
          <LogoMark className="h-8 w-8" />
          <span className="text-lg font-extrabold"><span>Biz</span><span className="text-brand-600">Pilot</span></span>
        </Link>
        <button onClick={onSearch} className="hidden h-10 w-full max-w-md items-center gap-2 rounded-xl border border-gray-200 bg-gray-50 px-3 text-sm text-gray-500 hover:border-gray-300 dark:border-gray-800 dark:bg-gray-900 md:flex">
          <Search className="h-4 w-4" /><span className="flex-1 text-left">{t('search.placeholder')}</span>
          <kbd className="rounded border border-gray-200 bg-white px-1.5 text-[11px] dark:border-gray-700 dark:bg-gray-800">Ctrl K</kbd>
        </button>
        <div className="ml-auto flex items-center gap-1 sm:gap-2">
          <button onClick={onSearch} className="rounded-lg p-2 md:hidden" aria-label={t('common.search')}><Search className="h-5 w-5" /></button>
          <LockStoreButton />
          <NotificationBell />
          <UserMenu />
        </div>
      </div>
    </header>
  );
}

function LockStoreButton() {
  const { t } = useI18n();
  const { lock, enabled } = useStoreLockActions();
  if (!enabled) return null;
  return (
    <button onClick={lock} className="inline-flex items-center gap-1.5 rounded-lg p-2 text-sm font-semibold text-ink-soft hover:bg-gray-100 dark:text-gray-300 dark:hover:bg-gray-800"
      aria-label={t('storeLock.lockStore')} title={t('storeLock.lockStore')}>
      <Lock className="h-5 w-5" /><span className="hidden md:inline">{t('storeLock.lockStore')}</span>
    </button>
  );
}

function useNotifications() {
  const { id } = useBiz();
  const { session } = useAuth();
  return useQuery({
    queryKey: ['notifications', id],
    refetchInterval: 120_000,
    queryFn: async () => {
      const list = unwrap(await supabase.from('notifications').select('*').eq('business_id', id).order('created_at', { ascending: false }).limit(40)) as any[];
      const reads = unwrap(await supabase.from('notification_reads').select('notification_id').eq('user_id', session!.user.id)
        .in('notification_id', list.map((n) => n.id).concat('00000000-0000-0000-0000-000000000000'))) as any[];
      const readSet = new Set(reads.map((r) => r.notification_id));
      return list.map((n) => ({ ...n, read: readSet.has(n.id) }));
    },
  });
}

function NotificationBell() {
  const { t, lang } = useI18n();
  const { id } = useBiz();
  const [open, setOpen] = useState(false);
  const { data } = useNotifications();
  const qc = useQueryClient();
  const unread = (data ?? []).filter((n) => !n.read).length;
  const ref = useRef<HTMLDivElement>(null);
  useEffect(() => {
    const close = (e: MouseEvent) => { if (ref.current && !ref.current.contains(e.target as Node)) setOpen(false); };
    document.addEventListener('mousedown', close);
    return () => document.removeEventListener('mousedown', close);
  }, []);
  const markAll = async () => {
    await rpc('mark_notifications_read', { p_business: id, p_ids: null });
    qc.invalidateQueries({ queryKey: ['notifications', id] });
  };
  return (
    <div className="relative" ref={ref}>
      <button onClick={() => setOpen((o) => !o)} className="relative rounded-lg p-2 hover:bg-gray-100 dark:hover:bg-gray-800" aria-label={t('nav.notifications')}>
        <Bell className="h-5 w-5" />
        {unread > 0 && <span className="absolute -right-0.5 -top-0.5 flex h-5 min-w-5 items-center justify-center rounded-full bg-red-600 px-1 text-[10px] font-bold text-white">{unread > 9 ? '9+' : unread}</span>}
      </button>
      {open && (
        <div className="absolute right-0 mt-2 w-[min(92vw,380px)] overflow-hidden rounded-2xl border border-gray-200 bg-white shadow-xl dark:border-gray-800 dark:bg-gray-900">
          <div className="flex items-center justify-between border-b border-gray-100 px-4 py-3 dark:border-gray-800">
            <p className="font-bold">{t('nav.notifications')}</p>
            {unread > 0 && <button className="text-xs font-semibold text-brand-700 hover:underline" onClick={markAll}>{t('notifications.markAllRead')}</button>}
          </div>
          <ul className="max-h-[60vh] divide-y divide-gray-100 overflow-y-auto dark:divide-gray-800">
            {(data ?? []).length === 0 && <li className="px-4 py-8 text-center text-sm text-ink-muted">{t('notifications.empty')}</li>}
            {(data ?? []).slice(0, 15).map((n) => (
              <li key={n.id}>
                <Link to={n.link ?? '/app/notifications'} onClick={() => setOpen(false)} className={clsx('block px-4 py-3 hover:bg-gray-50 dark:hover:bg-gray-800', !n.read && 'bg-brand-50/50 dark:bg-brand-950/30')}>
                  <p className="text-sm font-semibold">{notificationText(n, t, lang).title}</p>
                  <p className="text-xs text-ink-muted dark:text-gray-400">{notificationText(n, t, lang).body}</p>
                  <p className="mt-1 text-[11px] text-gray-400">{formatRelative(n.created_at, lang)}</p>
                </Link>
              </li>
            ))}
          </ul>
          <Link to="/app/notifications" onClick={() => setOpen(false)} className="block border-t border-gray-100 py-2.5 text-center text-sm font-semibold text-brand-700 dark:border-gray-800">{t('common.viewAll')}</Link>
        </div>
      )}
    </div>
  );
}

function UserMenu() {
  const { t } = useI18n();
  const { context, signOut } = useAuth();
  const { biz, select } = useBiz();
  const [open, setOpen] = useState(false);
  const [theme, setTheme] = useState<Theme>(getTheme());
  const nav = useNavigate();
  const ref = useRef<HTMLDivElement>(null);
  useEffect(() => {
    const close = (e: MouseEvent) => { if (ref.current && !ref.current.contains(e.target as Node)) setOpen(false); };
    document.addEventListener('mousedown', close);
    return () => document.removeEventListener('mousedown', close);
  }, []);
  const name = context?.profile?.full_name || context?.email || '';
  const initials = name.split(/\s+/).map((s) => s[0]).slice(0, 2).join('').toUpperCase();
  const setThemeAndSave = (th: Theme) => { setTheme(th); applyTheme(th); };
  return (
    <div className="relative" ref={ref}>
      <button onClick={() => setOpen((o) => !o)} className="flex items-center gap-2 rounded-xl p-1 pr-2 hover:bg-gray-100 dark:hover:bg-gray-800" aria-haspopup="menu" aria-expanded={open}>
        <span className="flex h-9 w-9 items-center justify-center rounded-full bg-brand-700 text-sm font-bold text-white">{initials || '?'}</span>
        <span className="hidden text-left leading-tight sm:block">
          <span className="block max-w-[160px] truncate text-sm font-semibold">{name}</span>
          <span className="block max-w-[160px] truncate text-xs text-ink-muted dark:text-gray-400">{biz.name}</span>
        </span>
        <ChevronDown className="hidden h-4 w-4 text-gray-400 sm:block" />
      </button>
      {open && (
        <div className="absolute right-0 mt-2 w-72 rounded-2xl border border-gray-200 bg-white p-2 shadow-xl dark:border-gray-800 dark:bg-gray-900" role="menu">
          <div className="px-3 py-2">
            <p className="truncate text-sm font-bold">{name}</p>
            <p className="truncate text-xs text-ink-muted">{context?.email}</p>
            <Badge tone="green" className="mt-1.5">{t(`roles.${biz.role}`)}</Badge>
          </div>
          {(context?.businesses.length ?? 0) > 1 && (
            <div className="border-t border-gray-100 py-1 dark:border-gray-800">
              <p className="px-3 py-1 text-[11px] font-bold uppercase text-ink-muted">{t('nav.switchBusiness')}</p>
              {context!.businesses.map((b) => (
                <button key={b.id} onClick={() => { select(b.id); setOpen(false); nav('/app'); }}
                  className={clsx('flex w-full items-center gap-2 rounded-lg px-3 py-2 text-left text-sm hover:bg-gray-50 dark:hover:bg-gray-800', b.id === biz.id && 'font-bold text-brand-700')}>
                  <Store className="h-4 w-4" /><span className="flex-1 truncate">{b.name}</span><span className="text-xs text-ink-muted">{t(`roles.${b.role}`)}</span>
                </button>
              ))}
            </div>
          )}
          <div className="space-y-2 border-t border-gray-100 px-3 py-3 dark:border-gray-800">
            <div className="flex items-center justify-between text-sm"><span>{t('common.language')}</span><LanguageSwitch persist /></div>
            <div className="flex items-center justify-between text-sm">
              <span>{t('common.theme')}</span>
              <div className="inline-flex rounded-lg bg-gray-100 p-0.5 dark:bg-gray-800">
                {(['light', 'dark', 'system'] as Theme[]).map((th) => (
                  <button key={th} onClick={() => setThemeAndSave(th)} aria-pressed={theme === th} title={t(`common.${th}`)}
                    className={clsx('rounded-md px-2 py-1', theme === th ? 'bg-white shadow-sm dark:bg-gray-900' : 'text-gray-500')}>
                    {th === 'light' ? <Sun className="h-3.5 w-3.5" /> : th === 'dark' ? <Moon className="h-3.5 w-3.5" /> : <span className="text-[10px] font-bold">A</span>}
                  </button>
                ))}
              </div>
            </div>
          </div>
          <div className="border-t border-gray-100 py-1 dark:border-gray-800">
            <MenuLink to="/app/profile" icon={<UserCog className="h-4 w-4" />}>{t('nav.profile')}</MenuLink>
            <MenuLink to="/app/billing" icon={<CreditCard className="h-4 w-4" />}>{t('nav.billing')}</MenuLink>
            <MenuLink to="/onboarding/new" icon={<Plus className="h-4 w-4" />}>{t('settings.addBusiness')}</MenuLink>
            {context?.is_platform_admin && <MenuLink to="/admin" icon={<ShieldCheck className="h-4 w-4" />}>{t('nav.admin')}</MenuLink>}
            <button onClick={async () => { await signOut(); nav('/login'); }} className="flex w-full items-center gap-2 rounded-lg px-3 py-2 text-sm text-red-600 hover:bg-red-50 dark:hover:bg-red-950/30">
              <LogOut className="h-4 w-4" />{t('nav.logout')}
            </button>
          </div>
        </div>
      )}
    </div>
  );
}

function MenuLink({ to, icon, children }: { to: string; icon: ReactNode; children: ReactNode }) {
  return <Link to={to} className="flex items-center gap-2 rounded-lg px-3 py-2 text-sm hover:bg-gray-50 dark:hover:bg-gray-800">{icon}{children}</Link>;
}

function Banners() {
  const { t, lang } = useI18n();
  const { biz, can } = useBiz();
  const { pending, online } = useOfflineQueue();
  const { data: ann } = useQuery({
    queryKey: ['announcements'],
    staleTime: 10 * 60_000,
    queryFn: async () => unwrap(await supabase.from('announcements').select('*').order('created_at', { ascending: false }).limit(3)) as any[],
  });
  const [hidden, setHidden] = useState<string[]>(() => {
    try { return JSON.parse(localStorage.getItem('bizpilot.hiddenAnnouncements') ?? '[]'); } catch { return []; }
  });
  const hide = (id: string) => {
    const next = [...hidden, id];
    setHidden(next);
    try { localStorage.setItem('bizpilot.hiddenAnnouncements', JSON.stringify(next)); } catch { /* ignore */ }
  };
  const s = biz.subscription;
  const trialEnding = s.state === 'trial' && s.trial_ends_at && new Date(s.trial_ends_at).getTime() - Date.now() < 5 * 86400000;
  return (
    <div className="mx-auto max-w-[1400px] space-y-2 px-4 pt-3 empty:hidden sm:px-6 print:hidden">
      {!online && (
        <div className="flex items-center gap-2 rounded-xl bg-gray-900 px-4 py-2.5 text-sm text-white"><WifiOff className="h-4 w-4" />{t('offline.banner')}</div>
      )}
      {pending > 0 && (
        <Link to="/app/sales?offline=1" className="flex items-center gap-2 rounded-xl bg-amber-100 px-4 py-2.5 text-sm font-medium text-amber-900">
          <Upload className="h-4 w-4" />{t('offline.pending', { count: pending })}
        </Link>
      )}
      {(ann ?? []).filter((a) => !hidden.includes(a.id)).map((a) => (
        <div key={a.id} className={clsx('flex items-start gap-3 rounded-xl px-4 py-2.5 text-sm', a.level === 'info' ? 'bg-blue-50 text-blue-900' : 'bg-amber-50 text-amber-900')}>
          <Megaphone className="mt-0.5 h-4 w-4 shrink-0" />
          <div className="flex-1"><b>{lang === 'fr' ? a.title_fr : a.title_en}</b> {lang === 'fr' ? a.body_fr : a.body_en}</div>
          <button onClick={() => hide(a.id)} aria-label={t('common.close')}><X className="h-4 w-4" /></button>
        </div>
      ))}
      {can('billing.manage') && (['grace', 'expired', 'suspended'].includes(s.state) || trialEnding) && (
        <div className="flex flex-col gap-2 rounded-xl border border-amber-200 bg-amber-50 px-4 py-2.5 text-sm text-amber-900 sm:flex-row sm:items-center">
          <span className="flex-1">{trialEnding ? t('billing.bannerTrial', { date: formatDate(s.trial_ends_at!, lang) }) : t(`billing.banner_${s.state}`)}</span>
          <Link to="/app/billing"><Button size="sm">{t('billing.managePlan')}</Button></Link>
        </div>
      )}
    </div>
  );
}

function BottomNav({ onQuick }: { onQuick: () => void }) {
  const { t } = useI18n();
  const { can } = useBiz();
  const item = (to: string, icon: ReactNode, label: string, end?: boolean) => (
    <NavLink to={to} end={end} className={({ isActive }) => clsx('flex flex-1 flex-col items-center gap-0.5 py-2 text-[11px] font-semibold', isActive ? 'text-brand-700 dark:text-brand-400' : 'text-gray-500')}>
      {icon}{label}
    </NavLink>
  );
  return (
    <nav className="fixed inset-x-0 bottom-0 z-30 border-t border-gray-200 bg-white pb-[env(safe-area-inset-bottom)] dark:border-gray-800 dark:bg-gray-950 lg:hidden print:hidden" aria-label="Bottom">
      <div className="relative flex items-end">
        {item('/app', <Home className="h-5 w-5" />, t('nav.home'), true)}
        {item('/app/products', <Package className="h-5 w-5" />, t('nav.products'))}
        <div className="flex flex-1 justify-center">
          <button onClick={onQuick} className="-mt-6 flex h-14 w-14 items-center justify-center rounded-full bg-brand-700 text-white shadow-lg shadow-brand-900/30 ring-4 ring-white dark:ring-gray-950" aria-label={t('nav.quickActions')}>
            <Plus className="h-7 w-7" />
          </button>
        </div>
        {can('sales.view') ? item('/app/sales', <ShoppingCart className="h-5 w-5" />, t('nav.sales')) : item('/app/sales/new', <ShoppingCart className="h-5 w-5" />, t('nav.newSale'))}
        {item('/app/more', <MoreHorizontal className="h-5 w-5" />, t('nav.more'))}
      </div>
    </nav>
  );
}

export function useQuickActions() {
  const { can, has } = useBiz();
  return [
    { to: '/app/sales/new', key: 'newSale', icon: ShoppingCart, tone: 'text-brand-700 bg-brand-50', show: can('sales.create') },
    { to: '/app/purchases/new', key: 'newPurchase', icon: ShoppingBag, tone: 'text-red-600 bg-red-50', show: can('purchases.manage') && has('purchases') },
    { to: '/app/products/new', key: 'addProduct', icon: Package, tone: 'text-blue-600 bg-blue-50', show: can('products.manage') },
    { to: '/app/expenses?new=1', key: 'recordExpense', icon: Receipt, tone: 'text-amber-600 bg-amber-50', show: can('expenses.manage') && has('expenses') },
    { to: '/app/suppliers?new=1', key: 'addSupplier', icon: Truck, tone: 'text-violet-600 bg-violet-50', show: can('suppliers.manage') && has('suppliers') },
    { to: '/app/inventory/counts', key: 'stocktake', icon: ClipboardCheck, tone: 'text-gray-700 bg-gray-100', show: can('stock.adjust') },
  ].filter((a) => a.show);
}

function QuickActions({ onClose }: { onClose: () => void }) {
  const { t } = useI18n();
  const actions = useQuickActions();
  return (
    <div className="fixed inset-0 z-50 flex items-end lg:hidden" role="dialog" aria-modal="true">
      <div className="absolute inset-0 bg-black/40" onClick={onClose} />
      <div className="relative w-full rounded-t-3xl bg-white p-5 pb-[calc(env(safe-area-inset-bottom)+20px)] dark:bg-gray-900">
        <div className="mb-4 flex items-center justify-between"><p className="text-lg font-bold">{t('nav.quickActions')}</p><button onClick={onClose}><X className="h-5 w-5" /></button></div>
        <div className="grid grid-cols-3 gap-3">
          {actions.map((a) => (
            <Link key={a.key} to={a.to} className="flex flex-col items-center gap-2 rounded-2xl p-3 text-center text-xs font-semibold hover:bg-gray-50 dark:hover:bg-gray-800">
              <span className={clsx('flex h-12 w-12 items-center justify-center rounded-2xl', a.tone)}><a.icon className="h-6 w-6" /></span>
              {t(a.key === 'stocktake' ? 'inventory.newCount' : `nav.${a.key}`)}
            </Link>
          ))}
        </div>
      </div>
    </div>
  );
}

function GlobalSearch({ onClose }: { onClose: () => void }) {
  const { t, lang } = useI18n();
  const { id, can, has } = useBiz();
  const [q, setQ] = useState('');
  const nav = useNavigate();
  const term = q.trim();
  const { data, isFetching } = useQuery({
    queryKey: ['search', id, term],
    enabled: term.length >= 2,
    queryFn: async () => {
      const like = `%${term.replace(/[%_,()]/g, ' ')}%`;
      const [products, sales, customers, suppliers, purchases] = await Promise.all([
        supabase.from('products').select('id,name,sku,qty_on_hand,base_unit').eq('business_id', id).or(`name.ilike.${like},sku.ilike.${like},barcode.eq.${term}`).limit(6),
        can('sales.view') ? supabase.from('sales').select('id,number,total,sold_at').eq('business_id', id).ilike('number', like).limit(5) : Promise.resolve({ data: [] }),
        can('customers.manage') ? supabase.from('customers').select('id,name,phone').eq('business_id', id).or(`name.ilike.${like},phone.ilike.${like}`).limit(5) : Promise.resolve({ data: [] }),
        can('purchases.manage') && has('suppliers') ? supabase.from('suppliers').select('id,name,phone').eq('business_id', id).ilike('name', like).limit(5) : Promise.resolve({ data: [] }),
        can('purchases.manage') && has('purchases') ? supabase.from('purchases').select('id,number,invoice_number,total').eq('business_id', id).or(`number.ilike.${like},invoice_number.ilike.${like}`).limit(5) : Promise.resolve({ data: [] }),
      ]);
      return { products: products.data ?? [], sales: sales.data ?? [], customers: customers.data ?? [], suppliers: suppliers.data ?? [], purchases: purchases.data ?? [] };
    },
  });
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => e.key === 'Escape' && onClose();
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [onClose]);
  const go = (to: string) => { onClose(); nav(to); };
  const groups = useMemo(() => data ? [
    { label: t('nav.products'), rows: data.products.map((p: any) => ({ id: p.id, title: p.name, sub: `${p.sku} · ${p.qty_on_hand} ${p.base_unit}`, to: `/app/products/${p.id}` })) },
    { label: t('nav.sales'), rows: data.sales.map((s: any) => ({ id: s.id, title: s.number, sub: formatDate(s.sold_at, lang), to: `/app/sales/${s.id}` })) },
    { label: t('nav.purchases'), rows: data.purchases.map((s: any) => ({ id: s.id, title: s.number, sub: s.invoice_number ?? '', to: `/app/purchases/${s.id}` })) },
    { label: t('nav.customers'), rows: data.customers.map((c: any) => ({ id: c.id, title: c.name, sub: c.phone ?? '', to: `/app/customers/${c.id}` })) },
    { label: t('nav.suppliers'), rows: data.suppliers.map((c: any) => ({ id: c.id, title: c.name, sub: c.phone ?? '', to: `/app/suppliers/${c.id}` })) },
  ].filter((g) => g.rows.length) : [], [data, t, lang]);
  return (
    <div className="fixed inset-0 z-[80] flex items-start justify-center p-4 pt-[10vh]" role="dialog" aria-modal="true">
      <div className="absolute inset-0 bg-gray-950/50" onClick={onClose} />
      <div className="relative w-full max-w-xl overflow-hidden rounded-2xl bg-white shadow-2xl dark:bg-gray-900">
        <div className="border-b border-gray-100 p-3 dark:border-gray-800">
          <Input autoFocus prefixIcon={<Search className="h-4 w-4" />} placeholder={t('search.placeholder')} value={q} onChange={(e) => setQ(e.target.value)} />
        </div>
        <div className="max-h-[60vh] overflow-y-auto p-2">
          {term.length < 2 && <p className="p-6 text-center text-sm text-ink-muted">{t('search.hint')}</p>}
          {term.length >= 2 && !isFetching && groups.length === 0 && <p className="p-6 text-center text-sm text-ink-muted">{t('common.noResults')}</p>}
          {groups.map((g) => (
            <div key={g.label} className="mb-2">
              <p className="px-3 py-1 text-[11px] font-bold uppercase tracking-wide text-ink-muted">{g.label}</p>
              {g.rows.map((r) => (
                <button key={r.id} onClick={() => go(r.to)} className="flex w-full items-center justify-between gap-3 rounded-lg px-3 py-2 text-left hover:bg-gray-50 dark:hover:bg-gray-800">
                  <span className="truncate text-sm font-semibold">{r.title}</span><span className="truncate text-xs text-ink-muted">{r.sub}</span>
                </button>
              ))}
            </div>
          ))}
        </div>
      </div>
    </div>
  );
}
