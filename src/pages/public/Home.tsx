import { Link, useNavigate } from 'react-router-dom';
import { ArrowRight, BarChart3, Boxes, Check, ClipboardList, Coins, Lightbulb, PackageSearch, ShoppingBag, ShoppingCart, Sparkles, Store, Truck } from 'lucide-react';
import { useI18n } from '../../i18n';
import { LinkButton } from '../../components/ui';
import { DashboardPreview } from './DashboardPreview';
import { PlanCards } from './PlanCards';
import { useAuth } from '../../lib/auth';

const pillarIcons = [Truck, Boxes, ShoppingCart, Coins, BarChart3, PackageSearch];

export function Home() {
  const { t, tv } = useI18n();
  const nav = useNavigate();
  const { session } = useAuth();
  const problems = tv<{ t: string; d: string }[]>('site.home.problems');
  const pillars = tv<{ t: string; d: string }[]>('site.home.pillars');
  const cats = tv<string[]>('site.home.categories');
  const faqs = tv<{ q: string; a: string }[]>('site.faq.items').slice(0, 5);
  return (
    <>
      <section className="relative overflow-hidden bg-gradient-to-b from-brand-50/70 via-white to-white dark:from-brand-950/40 dark:via-gray-950 dark:to-gray-950">
        <div className="mx-auto grid max-w-7xl items-center gap-12 px-4 pb-16 pt-12 sm:px-6 lg:grid-cols-2 lg:pb-24 lg:pt-20">
          <div>
            <span className="inline-flex items-center gap-2 rounded-full bg-white px-3 py-1 text-xs font-semibold text-brand-800 ring-1 ring-brand-200 dark:bg-gray-900 dark:text-brand-300 dark:ring-brand-900">
              <Store className="h-3.5 w-3.5" /> {t('site.home.heroBadge')}
            </span>
            <h1 className="mt-5 text-4xl font-extrabold leading-[1.1] tracking-tight text-ink dark:text-white sm:text-5xl">
              {t('site.home.heroTitle')} <span className="text-brand-700 dark:text-brand-400">{t('site.home.heroTitleAccent')}</span>
            </h1>
            <p className="mt-5 max-w-xl text-lg text-ink-soft dark:text-gray-300">{t('site.home.heroBody')}</p>
            <div className="mt-8 flex flex-col gap-3 sm:flex-row">
              <LinkButton to={session ? '/app' : '/signup'} size="lg" icon={<ArrowRight className="h-5 w-5" />}>{t('site.home.ctaPrimary')}</LinkButton>
              <LinkButton to="/market" size="lg" variant="outline" icon={<ShoppingBag className="h-5 w-5" />}>{t('site.home.ctaMarket')}</LinkButton>
            </div>
            <ul className="mt-6 flex flex-wrap gap-x-5 gap-y-2 text-sm text-ink-soft dark:text-gray-300">
              {tv<string[]>('site.home.heroPoints').map((p) => <li key={p} className="flex items-center gap-1.5"><Check className="h-4 w-4 text-brand-600" />{p}</li>)}
            </ul>
          </div>
          <DashboardPreview />
        </div>
      </section>

      <section className="mx-auto max-w-7xl px-4 py-16 sm:px-6">
        <h2 className="max-w-2xl text-3xl font-extrabold tracking-tight">{t('site.home.problemTitle')}</h2>
        <div className="mt-8 grid gap-5 md:grid-cols-3">
          {problems.map((p) => (
            <div key={p.t} className="rounded-2xl border border-gray-200 p-6 dark:border-gray-800">
              <h3 className="font-bold">{p.t}</h3>
              <p className="mt-2 text-sm text-ink-muted dark:text-gray-400">{p.d}</p>
            </div>
          ))}
        </div>
      </section>

      <section className="bg-gray-50 py-16 dark:bg-gray-900/50">
        <div className="mx-auto max-w-7xl px-4 sm:px-6">
          <h2 className="text-3xl font-extrabold tracking-tight">{t('site.home.pillarsTitle')}</h2>
          <div className="mt-8 grid gap-5 sm:grid-cols-2 lg:grid-cols-3">
            {pillars.map((p, i) => {
              const Icon = pillarIcons[i] ?? ClipboardList;
              return (
                <div key={p.t} className="rounded-2xl bg-white p-6 shadow-card dark:bg-gray-900">
                  <div className="flex h-11 w-11 items-center justify-center rounded-xl bg-brand-50 text-brand-700 dark:bg-brand-900/40 dark:text-brand-300"><Icon className="h-5 w-5" /></div>
                  <h3 className="mt-4 font-bold">{p.t}</h3>
                  <p className="mt-2 text-sm text-ink-muted dark:text-gray-400">{p.d}</p>
                </div>
              );
            })}
          </div>
        </div>
      </section>

      <section className="mx-auto grid max-w-7xl items-center gap-10 px-4 py-16 sm:px-6 lg:grid-cols-2">
        <div>
          <span className="inline-flex items-center gap-2 text-sm font-bold text-brand-700 dark:text-brand-400"><Sparkles className="h-4 w-4" />{t('nav.advisor')}</span>
          <h2 className="mt-2 text-3xl font-extrabold tracking-tight">{t('site.home.aiTitle')}</h2>
          <p className="mt-4 text-ink-soft dark:text-gray-300">{t('site.home.aiBody')}</p>
          <Link to="/ai-advisor" className="mt-5 inline-flex items-center gap-1 text-sm font-semibold text-brand-700 hover:underline dark:text-brand-400">{t('common.learnMore')} <ArrowRight className="h-4 w-4" /></Link>
        </div>
        <div className="rounded-2xl border border-gray-200 bg-white p-5 shadow-card dark:border-gray-800 dark:bg-gray-900">
          <div className="ml-auto w-fit max-w-[85%] rounded-2xl rounded-br-sm bg-brand-700 px-4 py-2.5 text-sm text-white">{t('site.home.aiQ')}</div>
          <div className="mt-3 flex gap-3">
            <div className="flex h-8 w-8 shrink-0 items-center justify-center rounded-full bg-brand-50 text-brand-700 dark:bg-brand-900/50"><Lightbulb className="h-4 w-4" /></div>
            <div className="rounded-2xl rounded-tl-sm bg-gray-100 px-4 py-2.5 text-sm text-ink dark:bg-gray-800 dark:text-gray-100">{t('site.home.aiA')}</div>
          </div>
          <p className="mt-3 text-xs text-ink-muted">{t('site.home.aiNote')}</p>
        </div>
      </section>

      <section className="bg-brand-950 py-14 text-white">
        <div className="mx-auto max-w-7xl px-4 sm:px-6">
          <h2 className="text-2xl font-extrabold">{t('site.home.categoriesTitle')}</h2>
          <div className="mt-6 flex flex-wrap gap-3">
            {cats.map((c) => <span key={c} className="rounded-full bg-white/10 px-4 py-2 text-sm font-semibold ring-1 ring-white/15">{c}</span>)}
          </div>
        </div>
      </section>

      <section className="mx-auto max-w-6xl px-4 py-16 sm:px-6" id="pricing">
        <div className="mb-8 text-center">
          <h2 className="text-3xl font-extrabold tracking-tight">{t('site.home.pricingTitle')}</h2>
          <p className="mt-2 text-ink-muted dark:text-gray-400">{t('site.home.pricingBody')}</p>
        </div>
        <PlanCards onChoose={() => nav(session ? '/app/billing' : '/signup')} />
      </section>

      <section className="bg-gray-50 py-16 dark:bg-gray-900/50">
        <div className="mx-auto max-w-3xl px-4 sm:px-6">
          <h2 className="text-center text-3xl font-extrabold tracking-tight">{t('site.home.faqTitle')}</h2>
          <FaqList items={faqs} />
          <p className="mt-6 text-center"><Link to="/faq" className="text-sm font-semibold text-brand-700 hover:underline dark:text-brand-400">{t('common.viewAll')}</Link></p>
        </div>
      </section>

      <section className="mx-auto max-w-7xl px-4 py-16 sm:px-6">
        <div className="rounded-3xl bg-gradient-to-br from-brand-800 to-brand-950 px-6 py-12 text-center text-white sm:px-12">
          <h2 className="text-3xl font-extrabold">{t('site.home.finalTitle')}</h2>
          <p className="mx-auto mt-3 max-w-xl text-brand-100">{t('site.home.finalBody')}</p>
          <div className="mt-6 flex flex-col justify-center gap-3 sm:flex-row">
            <LinkButton to={session ? '/app' : '/signup'} size="lg" className="bg-white !text-brand-900 hover:bg-brand-50">{t('site.home.ctaPrimary')}</LinkButton>
            <LinkButton to="/contact" size="lg" variant="ghost" className="!text-white hover:bg-white/10">{t('site.nav.contact')}</LinkButton>
          </div>
        </div>
      </section>
    </>
  );
}

export function FaqList({ items }: { items: { q: string; a: string }[] }) {
  return (
    <div className="mt-8 divide-y divide-gray-200 rounded-2xl border border-gray-200 bg-white dark:divide-gray-800 dark:border-gray-800 dark:bg-gray-900">
      {items.map((f) => (
        <details key={f.q} className="group px-5 py-4">
          <summary className="flex cursor-pointer list-none items-center justify-between gap-4 font-semibold">
            {f.q}<span className="text-brand-700 transition group-open:rotate-45 dark:text-brand-400">+</span>
          </summary>
          <p className="mt-3 text-sm text-ink-soft dark:text-gray-300">{f.a}</p>
        </details>
      ))}
    </div>
  );
}
