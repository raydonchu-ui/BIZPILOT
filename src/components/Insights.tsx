import { AlertTriangle, CheckCircle2, Info, Lightbulb, OctagonAlert } from 'lucide-react';
import clsx from 'clsx';
import { useI18n } from '../i18n';
import { formatDate, formatMoney, formatNumber, formatPct } from '../lib/format';

export interface Insight {
  code: string; severity: 'info' | 'success' | 'warning' | 'critical';
  period: { from: string; to: string }; params: Record<string, any>; limitations: string[];
}

const MONEY_KEYS = ['amount', 'value', 'gross_profit', 'prev_gross_profit', 'net_sales', 'prev_net_sales', 'expenses', 'prev_expenses',
  'operating_profit', 'prev_operating_profit', 'losses', 'prev_losses', 'cogs', 'revenue', 'price', 'cost'];
const PCT_KEYS = ['share', 'margin', 'prev_margin', 'pct', 'threshold'];

export function formatInsightParams(p: Record<string, any>, lang: 'en' | 'fr') {
  const out: Record<string, string | number> = {};
  for (const [k, v] of Object.entries(p ?? {})) {
    if (v === null || v === undefined || typeof v === 'object') continue;
    if (MONEY_KEYS.includes(k)) out[k] = formatMoney(v, lang);
    else if (PCT_KEYS.includes(k)) out[k] = formatPct(v, lang);
    else if (/(_date|_from|_to|first_expiry)$/.test(k) || k === 'first_expiry') out[k] = formatDate(v, lang);
    else if (typeof v === 'number') out[k] = formatNumber(v, lang);
    else out[k] = v;
  }
  if (p?.gross_profit !== undefined && p?.prev_gross_profit !== undefined && Number(p.prev_gross_profit) !== 0) {
    out.change = formatPct(((p.gross_profit - p.prev_gross_profit) / Math.abs(p.prev_gross_profit)) * 100, lang, 0);
  }
  if (p && 'category' in p && !p.category) out.category = lang === 'fr' ? 'Sans catégorie' : 'Uncategorised';
  return out;
}

function ItemList({ code, items }: { code: string; items: any[] }) {
  const { lang, t } = useI18n();
  if (!items?.length) return null;
  return (
    <ul className="mt-2 space-y-1 text-sm">
      {items.map((i, idx) => (
        <li key={idx} className="flex flex-wrap justify-between gap-x-3 rounded-lg bg-gray-50 px-3 py-1.5 dark:bg-gray-800/60">
          <span className="font-medium">{i.name}</span>
          <span className="text-ink-muted dark:text-gray-400">
            {code === 'restock_needed' && t('insights.itemRestock', { qty: formatNumber(i.qty_on_hand, lang), unit: i.unit, rec: formatNumber(i.recommended_qty, lang), cover: i.days_of_cover == null ? '—' : formatNumber(i.days_of_cover, lang) })}
            {code === 'price_below_cost' && t('insights.itemPrice', { price: formatMoney(i.price, lang), cost: formatMoney(i.cost, lang) })}
            {code === 'weak_margin' && t('insights.itemMargin', { margin: formatPct(i.margin, lang), revenue: formatMoney(i.revenue, lang) })}
            {code === 'slow_moving_capital' && t('insights.itemSlow', { value: formatMoney(i.value, lang), last: i.last_sold_at ? formatDate(i.last_sold_at, lang) : t('insights.never') })}
          </span>
        </li>
      ))}
    </ul>
  );
}

const icons = { info: Info, success: CheckCircle2, warning: AlertTriangle, critical: OctagonAlert };
const colors = {
  info: 'text-blue-600 bg-blue-50 dark:bg-blue-950/40', success: 'text-brand-700 bg-brand-50 dark:bg-brand-950/40',
  warning: 'text-amber-600 bg-amber-50 dark:bg-amber-950/40', critical: 'text-red-600 bg-red-50 dark:bg-red-950/40',
};

export function InsightCard({ insight, compact }: { insight: Insight; compact?: boolean }) {
  const { t, lang, has } = useI18n();
  const base = `insights.${insight.code}`;
  if (!has(`${base}.title`)) return null;
  const p = formatInsightParams(insight.params, lang);
  const Icon = icons[insight.severity] ?? Info;
  return (
    <div className="rounded-xl border border-gray-200 p-4 dark:border-gray-800">
      <div className="flex items-start gap-3">
        <span className={clsx('flex h-9 w-9 shrink-0 items-center justify-center rounded-lg', colors[insight.severity])}><Icon className="h-5 w-5" /></span>
        <div className="min-w-0 flex-1">
          <p className="font-bold">{t(`${base}.title`, p)}</p>
          <p className="mt-0.5 text-xs text-ink-muted dark:text-gray-400">{t('insights.period', { from: formatDate(insight.period.from, lang), to: formatDate(insight.period.to, lang) })}</p>
          <p className="mt-2 text-sm text-ink-soft dark:text-gray-300"><span className="font-semibold">{t('insights.found')}:</span> {t(`${base}.finding`, p)}</p>
          <ItemList code={insight.code} items={insight.params?.items} />
          {!compact && (
            <>
              <p className="mt-2 text-sm text-ink-soft dark:text-gray-300"><span className="font-semibold">{t('insights.why')}:</span> {t(`${base}.why`, p)}</p>
              <p className="mt-2 flex gap-1.5 text-sm text-brand-800 dark:text-brand-300"><Lightbulb className="mt-0.5 h-4 w-4 shrink-0" /><span><span className="font-semibold">{t('insights.action')}:</span> {t(`${base}.action`, p)}</span></p>
              {insight.limitations?.length > 0 && (
                <p className="mt-2 text-xs text-ink-muted dark:text-gray-400">{t('insights.limitations')}: {insight.limitations.map((l) => t(`insights.limits.${l}`)).join(' ')}</p>
              )}
            </>
          )}
        </div>
      </div>
    </div>
  );
}
