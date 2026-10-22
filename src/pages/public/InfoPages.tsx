import { ReactNode } from 'react';
import { useNavigate } from 'react-router-dom';
import { ArrowRight, CheckCircle2 } from 'lucide-react';
import { useI18n } from '../../i18n';
import { LinkButton } from '../../components/ui';
import { FaqList } from './Home';
import { PlanCards } from './PlanCards';
import { useAuth } from '../../lib/auth';

function Hero({ title, subtitle }: { title: string; subtitle: string }) {
  return (
    <section className="bg-gradient-to-b from-brand-50/70 to-white dark:from-brand-950/40 dark:to-gray-950">
      <div className="mx-auto max-w-4xl px-4 py-14 text-center sm:px-6">
        <h1 className="text-4xl font-extrabold tracking-tight sm:text-5xl">{title}</h1>
        <p className="mx-auto mt-4 max-w-2xl text-lg text-ink-soft dark:text-gray-300">{subtitle}</p>
      </div>
    </section>
  );
}

function Cta() {
  const { t } = useI18n();
  const { session } = useAuth();
  return (
    <div className="mx-auto max-w-4xl px-4 pb-16 text-center sm:px-6">
      <LinkButton to={session ? '/app' : '/signup'} size="lg" icon={<ArrowRight className="h-5 w-5" />}>{t('site.home.ctaPrimary')}</LinkButton>
    </div>
  );
}

function Blocks({ blocks }: { blocks: { t: string; d: string }[] }) {
  return (
    <div className="mx-auto grid max-w-5xl gap-5 px-4 py-14 sm:px-6 md:grid-cols-2">
      {blocks.map((b) => (
        <div key={b.t} className="rounded-2xl border border-gray-200 p-6 dark:border-gray-800">
          <h2 className="flex items-center gap-2 text-lg font-bold"><CheckCircle2 className="h-5 w-5 text-brand-600" />{b.t}</h2>
          <p className="mt-2 text-sm text-ink-soft dark:text-gray-300">{b.d}</p>
        </div>
      ))}
    </div>
  );
}

function Page({ children }: { children: ReactNode }) {
  return <div>{children}</div>;
}

export function Features() {
  const { t, tv } = useI18n();
  return (
    <Page>
      <Hero title={t('site.features.title')} subtitle={t('site.features.subtitle')} />
      <div className="mx-auto grid max-w-6xl gap-6 px-4 py-14 sm:px-6 md:grid-cols-2 lg:grid-cols-3">
        {tv<{ t: string; items: string[] }[]>('site.features.groups').map((g) => (
          <div key={g.t} className="rounded-2xl border border-gray-200 p-6 dark:border-gray-800">
            <h2 className="text-lg font-bold">{g.t}</h2>
            <ul className="mt-4 space-y-2 text-sm text-ink-soft dark:text-gray-300">
              {g.items.map((i) => <li key={i} className="flex gap-2"><CheckCircle2 className="mt-0.5 h-4 w-4 shrink-0 text-brand-600" />{i}</li>)}
            </ul>
          </div>
        ))}
      </div>
      <Cta />
    </Page>
  );
}

export function HowItWorks() {
  const { t, tv } = useI18n();
  return (
    <Page>
      <Hero title={t('site.how.title')} subtitle={t('site.how.subtitle')} />
      <ol className="mx-auto max-w-3xl space-y-5 px-4 py-14 sm:px-6">
        {tv<{ t: string; d: string }[]>('site.how.steps').map((s, i) => (
          <li key={s.t} className="flex gap-4 rounded-2xl border border-gray-200 p-5 dark:border-gray-800">
            <span className="flex h-9 w-9 shrink-0 items-center justify-center rounded-full bg-brand-700 font-bold text-white">{i + 1}</span>
            <div><h2 className="font-bold">{s.t}</h2><p className="mt-1 text-sm text-ink-soft dark:text-gray-300">{s.d}</p></div>
          </li>
        ))}
      </ol>
      <Cta />
    </Page>
  );
}

export function InventoryPage() {
  const { t, tv } = useI18n();
  return <Page><Hero title={t('site.inventory.title')} subtitle={t('site.inventory.subtitle')} /><Blocks blocks={tv('site.inventory.blocks')} /><Cta /></Page>;
}

export function AnalyticsPage() {
  const { t, tv } = useI18n();
  return <Page><Hero title={t('site.analytics.title')} subtitle={t('site.analytics.subtitle')} /><Blocks blocks={tv('site.analytics.blocks')} /><Cta /></Page>;
}

export function AiPage() {
  const { t, tv } = useI18n();
  return (
    <Page>
      <Hero title={t('site.ai.title')} subtitle={t('site.ai.subtitle')} />
      <Blocks blocks={tv('site.ai.blocks')} />
      <div className="mx-auto max-w-3xl px-4 pb-10 sm:px-6">
        <div className="flex flex-wrap justify-center gap-2">
          {tv<string[]>('site.ai.questions').map((q) => <span key={q} className="rounded-full bg-brand-50 px-3 py-1.5 text-sm font-medium text-brand-800 dark:bg-brand-900/40 dark:text-brand-200">{q}</span>)}
        </div>
        <p className="mt-6 text-center text-sm text-ink-muted">{t('site.ai.availability')}</p>
      </div>
      <Cta />
    </Page>
  );
}

export function PricingPage() {
  const { t } = useI18n();
  const nav = useNavigate();
  const { session } = useAuth();
  return (
    <Page>
      <Hero title={t('site.pricing.title')} subtitle={t('site.pricing.subtitle')} />
      <div className="mx-auto max-w-6xl px-4 py-12 sm:px-6"><PlanCards onChoose={() => nav(session ? '/app/billing' : '/signup')} /></div>
    </Page>
  );
}

export function AboutPage() {
  const { t, tv } = useI18n();
  return (
    <Page>
      <Hero title={t('site.about.title')} subtitle={t('brand.promise')} />
      <div className="mx-auto max-w-3xl space-y-4 px-4 py-12 text-ink-soft dark:text-gray-300 sm:px-6">
        {tv<string[]>('site.about.body').map((p) => <p key={p}>{p}</p>)}
        <h2 className="pt-6 text-2xl font-extrabold text-ink dark:text-white">{t('site.about.principlesTitle')}</h2>
        <div className="grid gap-4 sm:grid-cols-3">
          {tv<{ t: string; d: string }[]>('site.about.principles').map((p) => (
            <div key={p.t} className="rounded-2xl border border-gray-200 p-5 dark:border-gray-800"><h3 className="font-bold text-ink dark:text-white">{p.t}</h3><p className="mt-1 text-sm">{p.d}</p></div>
          ))}
        </div>
      </div>
      <Cta />
    </Page>
  );
}

export function FaqPage() {
  const { t, tv } = useI18n();
  return (
    <Page>
      <Hero title={t('site.faq.title')} subtitle={t('brand.promise')} />
      <div className="mx-auto max-w-3xl px-4 pb-16 sm:px-6"><FaqList items={tv('site.faq.items')} /></div>
    </Page>
  );
}
