import { BarChart3, Box, Coins, ShoppingCart, AlertTriangle } from 'lucide-react';
import { useI18n } from '../../i18n';
import { formatMoney } from '../../lib/format';

// Static, clearly-labelled illustration for the marketing site. Not customer data.
const bars = [32, 45, 38, 52, 47, 60, 55, 68, 62, 74, 70, 85, 78, 92];

export function DashboardPreview() {
  const { t, lang } = useI18n();
  const m = (v: number) => formatMoney(v, lang);
  const cards = [
    { icon: ShoppingCart, label: t('dashboard.totalSales'), value: m(850000), tone: 'bg-brand-50 text-brand-700' },
    { icon: Coins, label: t('dashboard.grossProfit'), value: m(230000), tone: 'bg-amber-50 text-amber-600' },
    { icon: Box, label: t('dashboard.inventoryValue'), value: m(1250000), tone: 'bg-violet-50 text-violet-600' },
  ];
  return (
    <figure className="relative">
      <div className="rounded-3xl border border-gray-200 bg-gray-50 p-3 shadow-2xl shadow-brand-900/10 dark:border-gray-800 dark:bg-gray-900">
        <div className="rounded-2xl bg-white p-4 dark:bg-gray-950">
          <div className="mb-3 flex items-center justify-between">
            <div>
              <p className="text-sm font-extrabold text-ink dark:text-white">{t('dashboard.title')}</p>
              <p className="text-[11px] text-ink-muted">{t('periods.this_month')}</p>
            </div>
            <span className="rounded-md bg-brand-700 px-2 py-1 text-[10px] font-semibold text-white">{t('nav.newSale')}</span>
          </div>
          <div className="grid grid-cols-3 gap-2">
            {cards.map((c) => (
              <div key={c.label} className="rounded-xl border border-gray-100 p-2.5 dark:border-gray-800">
                <div className={`mb-1.5 inline-flex rounded-lg p-1.5 ${c.tone}`}><c.icon className="h-3.5 w-3.5" /></div>
                <p className="truncate text-[10px] text-ink-muted">{c.label}</p>
                <p className="truncate text-xs font-extrabold text-ink dark:text-white">{c.value}</p>
              </div>
            ))}
          </div>
          <div className="mt-3 rounded-xl border border-gray-100 p-3 dark:border-gray-800">
            <p className="mb-2 flex items-center gap-1.5 text-[11px] font-bold text-ink dark:text-white"><BarChart3 className="h-3.5 w-3.5 text-brand-600" />{t('dashboard.salesOverview')}</p>
            <div className="flex h-24 items-end gap-1">
              {bars.map((h, i) => <div key={i} className="flex-1 rounded-t bg-linear-to-t from-brand-400 to-brand-300" style={{ height: `${h}%` }} />)}
            </div>
          </div>
          <div className="mt-3 flex items-center gap-2 rounded-xl bg-amber-50 p-2.5 text-[11px] text-amber-900 dark:bg-amber-950/40 dark:text-amber-200">
            <AlertTriangle className="h-3.5 w-3.5 shrink-0" />
            <span className="truncate">Indomie Noodles — {t('dashboard.previewRestock')}</span>
          </div>
        </div>
      </div>
      <figcaption className="mt-3 text-center text-xs text-ink-muted dark:text-gray-400">{t('site.home.previewCaption')}</figcaption>
    </figure>
  );
}
