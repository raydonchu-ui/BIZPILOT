import { Link } from 'react-router-dom';
import { useQuery } from '@tanstack/react-query';
import clsx from 'clsx';
import { CheckCircle2, Circle, PartyPopper } from 'lucide-react';
import { useI18n } from '../../i18n';
import { useBiz } from '../../lib/business';
import { supabase } from '../../lib/supabase';
import { Card, LinkButton, PageHeader, PageLoader } from '../../components/ui';

export function dashboardVisitedKey(id: string) { return `bizpilot.visitedDashboard.${id}`; }

export default function SetupChecklist() {
  const { t } = useI18n();
  const { id, has } = useBiz();
  const { data, isLoading } = useQuery({
    queryKey: ['setup', id],
    queryFn: async () => {
      const head = { count: 'exact' as const, head: true };
      const [b, p, m, s, pu, sa] = await Promise.all([
        supabase.from('businesses').select('phone,city,address,logo_path').eq('id', id).single(),
        supabase.from('products').select('id', head).eq('business_id', id),
        supabase.from('stock_movements').select('id', head).eq('business_id', id).in('movement_type', ['opening', 'purchase_receipt']),
        supabase.from('suppliers').select('id', head).eq('business_id', id),
        supabase.from('purchases').select('id', head).eq('business_id', id).neq('status', 'draft').neq('status', 'cancelled'),
        supabase.from('sales').select('id', head).eq('business_id', id),
      ]);
      let visited = false;
      try { visited = Boolean(localStorage.getItem(dashboardVisitedKey(id))); } catch { /* ignore */ }
      return {
        business: Boolean(b.data && (b.data.phone || b.data.city || b.data.address || b.data.logo_path)),
        products: (p.count ?? 0) > 0, opening: (m.count ?? 0) > 0, suppliers: (s.count ?? 0) > 0,
        purchase: (pu.count ?? 0) > 0, sale: (sa.count ?? 0) > 0, dashboard: visited,
      };
    },
  });
  if (isLoading || !data) return <PageLoader />;
  const steps = [
    { key: 'business', to: '/app/settings', done: data.business },
    { key: 'products', to: '/app/products/new', done: data.products, alt: '/app/import' },
    { key: 'opening', to: '/app/products', done: data.opening },
    ...(has('suppliers') ? [{ key: 'suppliers', to: '/app/suppliers?new=1', done: data.suppliers }] : []),
    ...(has('purchases') ? [{ key: 'purchase', to: '/app/purchases/new', done: data.purchase }] : []),
    { key: 'sale', to: '/app/sales/new', done: data.sale },
    { key: 'dashboard', to: '/app', done: data.dashboard },
  ];
  const done = steps.filter((s) => s.done).length;
  return (
    <div className="mx-auto max-w-3xl">
      <PageHeader title={t('setup.title')} subtitle={t('setup.subtitle')} />
      <Card>
        <div className="mb-5">
          <div className="flex items-center justify-between text-sm font-semibold"><span>{t('setup.progress', { done, total: steps.length })}</span><span>{Math.round((done / steps.length) * 100)}%</span></div>
          <div className="mt-2 h-2.5 overflow-hidden rounded-full bg-gray-100 dark:bg-gray-800"><div className="h-full rounded-full bg-brand-600 transition-all" style={{ width: `${(done / steps.length) * 100}%` }} /></div>
        </div>
        {done === steps.length && <div className="mb-4 flex items-center gap-3 rounded-xl bg-brand-50 p-4 text-brand-900 dark:bg-brand-950/50 dark:text-brand-100"><PartyPopper className="h-6 w-6" />{t('setup.allDone')}</div>}
        <ol className="space-y-2">
          {steps.map((s, i) => (
            <li key={s.key} className={clsx('flex items-center gap-4 rounded-xl border p-4', s.done ? 'border-brand-200 bg-brand-50/40 dark:border-brand-900 dark:bg-brand-950/20' : 'border-gray-200 dark:border-gray-800')}>
              {s.done ? <CheckCircle2 className="h-6 w-6 shrink-0 text-brand-600" /> : <Circle className="h-6 w-6 shrink-0 text-gray-300" />}
              <div className="min-w-0 flex-1">
                <p className={clsx('font-semibold', s.done && 'text-ink-muted line-through')}>{i + 1}. {t(`setup.steps.${s.key}.t`)}</p>
                <p className="text-sm text-ink-muted">{t(`setup.steps.${s.key}.d`)}</p>
              </div>
              {!s.done && <div className="flex flex-col gap-1 sm:flex-row">
                <LinkButton to={s.to} size="sm">{t('setup.go')}</LinkButton>
                {'alt' in s && s.alt && <Link to={s.alt} className="text-center text-xs font-semibold text-brand-700 sm:self-center sm:px-2">{t('setup.importInstead')}</Link>}
              </div>}
            </li>
          ))}
        </ol>
      </Card>
    </div>
  );
}
