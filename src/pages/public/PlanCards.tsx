import { useState } from 'react';
import { useQuery } from '@tanstack/react-query';
import { Check } from 'lucide-react';
import clsx from 'clsx';
import { supabase } from '../../lib/supabase';
import { unwrap } from '../../lib/api';
import { useI18n } from '../../i18n';
import { formatMoney, formatNumber } from '../../lib/format';
import { Badge, Button, Spinner } from '../../components/ui';

export interface Plan {
  code: string; name_en: string; name_fr: string; description_en: string | null; description_fr: string | null;
  price_monthly: number; price_annual: number | null; features: string[]; limits: Record<string, number | null>;
  highlight: boolean; sort: number;
}

export function usePlans() {
  return useQuery({
    queryKey: ['plans'],
    queryFn: async () => unwrap(await supabase.from('plans').select('*').eq('active', true).eq('is_public', true).order('sort')) as Plan[],
    staleTime: 5 * 60_000,
  });
}

export function planLimitLines(p: Plan, t: (k: string, x?: Record<string, string | number>) => string, lang: 'en' | 'fr') {
  const L = p.limits;
  const n = (v: number) => formatNumber(v, lang);
  return [
    L.max_products == null ? t('limits.unlimited_products') : t('limits.max_products', { n: n(L.max_products) }),
    L.max_sales_per_month == null ? t('limits.unlimited_sales') : t('limits.max_sales_per_month', { n: n(L.max_sales_per_month) }),
    L.max_staff == null ? '' : t('limits.max_staff', { n: n(L.max_staff) }),
    L.history_days == null ? t('limits.unlimited_history') : t('limits.history_days', { n: n(L.history_days) }),
    L.ai_queries_per_month ? t('limits.ai_queries_per_month', { n: n(L.ai_queries_per_month) }) : '',
  ].filter(Boolean);
}

export function PlanCards({ onChoose, currentPlan, chooseLabel }:
  { onChoose: (plan: Plan, period: 'monthly' | 'annual') => void; currentPlan?: string; chooseLabel?: string }) {
  const { t, lang } = useI18n();
  const { data, isLoading } = usePlans();
  const [period, setPeriod] = useState<'monthly' | 'annual'>('monthly');
  if (isLoading) return <div className="flex justify-center py-10"><Spinner /></div>;
  const plans = data ?? [];
  return (
    <div>
      <div className="mb-6 flex flex-col items-center gap-2">
        <div className="inline-flex rounded-xl bg-gray-100 p-1 dark:bg-gray-800" role="group">
          {(['monthly', 'annual'] as const).map((p) => (
            <button key={p} onClick={() => setPeriod(p)} aria-pressed={period === p}
              className={clsx('rounded-lg px-4 py-1.5 text-sm font-semibold', period === p ? 'bg-white text-brand-800 shadow-sm dark:bg-gray-900 dark:text-brand-300' : 'text-gray-600 dark:text-gray-300')}>
              {t(`site.pricing.${p}`)}
            </button>
          ))}
        </div>
        {period === 'annual' && <p className="text-xs text-brand-700 dark:text-brand-400">{t('site.pricing.annualSave')}</p>}
      </div>
      <div className="grid gap-5 md:grid-cols-3">
        {plans.map((p) => {
          const price = period === 'annual' ? (p.price_annual ?? p.price_monthly * 12) : p.price_monthly;
          const name = lang === 'fr' ? p.name_fr : p.name_en;
          const desc = lang === 'fr' ? p.description_fr : p.description_en;
          const isCurrent = currentPlan === p.code;
          return (
            <div key={p.code} className={clsx('relative flex flex-col rounded-2xl border bg-white p-6 shadow-card dark:bg-gray-900',
              p.highlight ? 'border-brand-600 ring-2 ring-brand-600/20' : 'border-gray-200 dark:border-gray-800')}>
              {p.highlight && <Badge tone="green" className="absolute -top-3 left-6">{t('site.pricing.popular')}</Badge>}
              <h3 className="text-lg font-extrabold">{name}</h3>
              <p className="mt-1 min-h-[40px] text-sm text-ink-muted dark:text-gray-400">{desc}</p>
              <p className="mt-4 flex items-baseline gap-1">
                <span className="text-3xl font-extrabold tracking-tight">{price > 0 ? formatMoney(price, lang) : t('site.pricing.free')}</span>
                {price > 0 && <span className="text-sm text-ink-muted">{t(period === 'annual' ? 'site.pricing.perYear' : 'site.pricing.perMonth')}</span>}
              </p>
              <ul className="mt-5 flex-1 space-y-2 text-sm">
                {planLimitLines(p, t, lang).map((l) => <li key={l} className="flex gap-2"><Check className="mt-0.5 h-4 w-4 shrink-0 text-brand-600" />{l}</li>)}
                {p.features.map((f) => <li key={f} className="flex gap-2"><Check className="mt-0.5 h-4 w-4 shrink-0 text-brand-600" />{t(`features.${f}`)}</li>)}
              </ul>
              {chooseLabel && price === 0 && !isCurrent
                ? <p className="mt-6 rounded-lg bg-gray-50 px-3 py-2.5 text-center text-xs text-ink-muted dark:bg-gray-800 dark:text-gray-400">{t('billing.freeNoPayment')}</p>
                : <Button className="mt-6" variant={p.highlight ? 'primary' : 'outline'} block disabled={isCurrent}
                    onClick={() => onChoose(p, period)}>
                    {isCurrent ? t('billing.currentPlan') : chooseLabel ?? t('site.pricing.cta')}
                  </Button>}
            </div>
          );
        })}
      </div>
      <p className="mt-6 text-center text-xs text-ink-muted dark:text-gray-400">{t('site.pricing.paymentNote')} {t('site.pricing.currentNote')}</p>
    </div>
  );
}
