import { useEffect, useState } from 'react';
import { Link, NavLink, Outlet, useLocation } from 'react-router-dom';
import { Menu, X } from 'lucide-react';
import clsx from 'clsx';
import { Logo } from '../Logo';
import { LanguageSwitch } from '../LanguageSwitch';
import { LinkButton } from '../ui';
import { useI18n } from '../../i18n';
import { useAuth } from '../../lib/auth';

const links = [
  { to: '/features', key: 'features' }, { to: '/how-it-works', key: 'how' }, { to: '/inventory-management', key: 'inventory' },
  { to: '/business-analytics', key: 'analytics' }, { to: '/ai-advisor', key: 'ai' }, { to: '/pricing', key: 'pricing' },
];

export function PublicLayout() {
  const { t } = useI18n();
  const { session } = useAuth();
  const [open, setOpen] = useState(false);
  const loc = useLocation();
  useEffect(() => { setOpen(false); window.scrollTo(0, 0); }, [loc.pathname]);

  return (
    <div className="flex min-h-screen flex-col bg-white text-ink dark:bg-gray-950 dark:text-gray-100">
      <a href="#main" className="sr-only focus:not-sr-only focus:absolute focus:left-4 focus:top-4 focus:z-50 focus:rounded focus:bg-white focus:px-3 focus:py-2">Skip to content</a>
      <header className="sticky top-0 z-40 border-b border-gray-100 bg-white/90 backdrop-blur dark:border-gray-900 dark:bg-gray-950/90">
        <div className="mx-auto flex h-16 max-w-7xl items-center justify-between gap-4 px-4 sm:px-6">
          <Logo size="sm" />
          <nav className="hidden items-center gap-1 lg:flex" aria-label="Main">
            {links.map((l) => (
              <NavLink key={l.to} to={l.to} className={({ isActive }) => clsx('rounded-lg px-3 py-2 text-sm font-semibold transition',
                isActive ? 'text-brand-700 dark:text-brand-400' : 'text-ink-soft hover:text-ink dark:text-gray-300 dark:hover:text-white')}>
                {t(`site.nav.${l.key}`)}
              </NavLink>
            ))}
          </nav>
          <div className="hidden items-center gap-2 lg:flex">
            <LanguageSwitch />
            {session ? <LinkButton to="/app" size="sm">{t('site.nav.openApp')}</LinkButton> : (
              <>
                <LinkButton to="/login" variant="ghost" size="sm">{t('site.nav.login')}</LinkButton>
                <LinkButton to="/signup" size="sm">{t('site.nav.signup')}</LinkButton>
              </>
            )}
          </div>
          <button className="rounded-lg p-2 lg:hidden" onClick={() => setOpen((o) => !o)} aria-label={t('common.menu')} aria-expanded={open}>
            {open ? <X className="h-6 w-6" /> : <Menu className="h-6 w-6" />}
          </button>
        </div>
        {open && (
          <div className="border-t border-gray-100 bg-white px-4 pb-6 pt-2 dark:border-gray-900 dark:bg-gray-950 lg:hidden">
            <nav className="flex flex-col" aria-label="Mobile">
              {[...links, { to: '/about', key: 'about' }, { to: '/faq', key: 'faq' }, { to: '/contact', key: 'contact' }].map((l) => (
                <Link key={l.to} to={l.to} className="rounded-lg px-2 py-3 text-base font-semibold text-ink-soft dark:text-gray-200">{t(`site.nav.${l.key}`)}</Link>
              ))}
            </nav>
            <div className="mt-4 flex items-center justify-between gap-3">
              <LanguageSwitch />
              <div className="flex gap-2">
                {session ? <LinkButton to="/app" size="sm">{t('site.nav.openApp')}</LinkButton> : (
                  <>
                    <LinkButton to="/login" variant="outline" size="sm">{t('site.nav.login')}</LinkButton>
                    <LinkButton to="/signup" size="sm">{t('site.nav.signup')}</LinkButton>
                  </>
                )}
              </div>
            </div>
          </div>
        )}
      </header>
      <main id="main" className="flex-1"><Outlet /></main>
      <Footer />
    </div>
  );
}

function Footer() {
  const { t } = useI18n();
  const col = (title: string, items: { to: string; label: string }[]) => (
    <div>
      <h3 className="text-sm font-bold text-white">{title}</h3>
      <ul className="mt-3 space-y-2">
        {items.map((i) => <li key={i.to}><Link to={i.to} className="text-sm text-gray-300 hover:text-white">{i.label}</Link></li>)}
      </ul>
    </div>
  );
  return (
    <footer className="bg-brand-950 text-gray-300">
      <div className="mx-auto grid max-w-7xl gap-10 px-4 py-14 sm:px-6 md:grid-cols-5">
        <div className="md:col-span-2">
          <Logo inverse size="sm" />
          <p className="mt-4 max-w-sm text-sm">{t('site.footer.blurb')}</p>
          <p className="mt-2 text-xs text-gray-400">{t('site.footer.madeFor')}</p>
        </div>
        {col(t('site.footer.product'), [
          { to: '/features', label: t('site.nav.features') }, { to: '/inventory-management', label: t('site.nav.inventory') },
          { to: '/business-analytics', label: t('site.nav.analytics') }, { to: '/ai-advisor', label: t('site.nav.ai') },
          { to: '/pricing', label: t('site.nav.pricing') }])}
        {col(t('site.footer.company'), [
          { to: '/about', label: t('site.nav.about') }, { to: '/how-it-works', label: t('site.nav.how') },
          { to: '/faq', label: t('site.nav.faq') }, { to: '/contact', label: t('site.nav.contact') }])}
        {col(t('site.footer.legal'), [
          { to: '/privacy', label: t('site.footer.privacy') }, { to: '/terms', label: t('site.footer.terms') },
          { to: '/billing-policy', label: t('site.footer.billing') }, { to: '/login', label: t('site.nav.login') },
          { to: '/signup', label: t('site.nav.signup') }])}
      </div>
      <div className="border-t border-white/10 py-5 text-center text-xs text-gray-400">{t('site.footer.rights', { year: new Date().getFullYear() })}</div>
    </footer>
  );
}
