import { Area, AreaChart, Bar, CartesianGrid, Cell, ComposedChart, Legend, Line, Pie, PieChart, ResponsiveContainer, Tooltip, XAxis, YAxis } from 'recharts';
import { useI18n } from '../i18n';
import { formatCompact, formatDate, formatMoney } from '../lib/format';

// Respect the user's reduced-motion preference.
const ANIMATE = typeof window === 'undefined' || !window.matchMedia?.('(prefers-reduced-motion: reduce)').matches;

export const CHART_COLORS = ['#156834', '#47bd6f', '#f59e0b', '#3b82f6', '#8b5cf6', '#ef4444', '#14b8a6', '#9ca3af'];

const axisProps = { tick: { fontSize: 11, fill: '#6b7280' }, tickLine: false, axisLine: false } as const;

function shortLabel(d: string, lang: 'en' | 'fr', grain: string) {
  const dt = new Date(d + 'T12:00:00Z');
  if (grain === 'month') return new Intl.DateTimeFormat(lang === 'fr' ? 'fr-FR' : 'en-GB', { month: 'short', year: '2-digit' }).format(dt);
  return new Intl.DateTimeFormat(lang === 'fr' ? 'fr-FR' : 'en-GB', { day: 'numeric', month: 'short' }).format(dt);
}

export function SalesProfitChart({ data, grain = 'day', height = 280 }:
  { data: { bucket: string; net_sales: number; gross_profit: number }[]; grain?: string; height?: number }) {
  const { t, lang } = useI18n();
  return (
    <div style={{ height }}>
      <ResponsiveContainer width="100%" height="100%">
        <ComposedChart data={data} margin={{ top: 8, right: 8, left: -12, bottom: 0 }}>
          <CartesianGrid vertical={false} stroke="#e5e7eb" strokeDasharray="3 3" />
          <XAxis dataKey="bucket" {...axisProps} tickFormatter={(d) => shortLabel(d, lang, grain)} minTickGap={16} />
          <YAxis {...axisProps} tickFormatter={(v) => formatCompact(v, lang)} width={56} />
          <Tooltip formatter={(v: number, name) => [formatMoney(v, lang), name]} labelFormatter={(d) => formatDate(d as string, lang)}
            contentStyle={{ borderRadius: 12, border: '1px solid #e5e7eb', fontSize: 12 }} />
          <Legend verticalAlign="top" align="right" iconType="circle" wrapperStyle={{ fontSize: 12, paddingBottom: 8 }} />
          <Bar isAnimationActive={ANIMATE} dataKey="net_sales" name={t('dashboard.netSales')} fill="#47bd6f" radius={[4, 4, 0, 0]} maxBarSize={22} />
          <Line isAnimationActive={ANIMATE} dataKey="gross_profit" name={t('dashboard.grossProfit')} stroke="#156834" strokeWidth={2.5} dot={{ r: 2.5 }} type="monotone" />
        </ComposedChart>
      </ResponsiveContainer>
    </div>
  );
}

export function ValueTrendChart({ data, height = 220 }: { data: { day: string; value: number }[]; height?: number }) {
  const { t, lang } = useI18n();
  return (
    <div style={{ height }}>
      <ResponsiveContainer width="100%" height="100%">
        <AreaChart data={data} margin={{ top: 8, right: 8, left: -12, bottom: 0 }}>
          <defs>
            <linearGradient id="invFill" x1="0" y1="0" x2="0" y2="1"><stop offset="0%" stopColor="#47bd6f" stopOpacity={0.35} /><stop offset="100%" stopColor="#47bd6f" stopOpacity={0.02} /></linearGradient>
          </defs>
          <CartesianGrid vertical={false} stroke="#e5e7eb" strokeDasharray="3 3" />
          <XAxis dataKey="day" {...axisProps} tickFormatter={(d) => shortLabel(d, lang, 'day')} minTickGap={20} />
          <YAxis {...axisProps} tickFormatter={(v) => formatCompact(v, lang)} width={56} />
          <Tooltip formatter={(v: number) => [formatMoney(v, lang), t('dashboard.inventoryValue')]} labelFormatter={(d) => formatDate(d as string, lang)}
            contentStyle={{ borderRadius: 12, border: '1px solid #e5e7eb', fontSize: 12 }} />
          <Area isAnimationActive={ANIMATE} dataKey="value" stroke="#18813e" strokeWidth={2} fill="url(#invFill)" type="monotone" />
        </AreaChart>
      </ResponsiveContainer>
    </div>
  );
}

export function DonutChart({ data, centerLabel, centerValue, height = 220 }:
  { data: { name: string; value: number }[]; centerLabel?: string; centerValue?: string; height?: number }) {
  const { lang } = useI18n();
  return (
    <div className="relative" style={{ height }}>
      <ResponsiveContainer width="100%" height="100%">
        <PieChart>
          <Pie isAnimationActive={ANIMATE} data={data} dataKey="value" nameKey="name" innerRadius="62%" outerRadius="95%" paddingAngle={1.5} stroke="none">
            {data.map((_, i) => <Cell key={i} fill={CHART_COLORS[i % CHART_COLORS.length]} />)}
          </Pie>
          <Tooltip formatter={(v: number, n) => [formatMoney(v, lang), n]} contentStyle={{ borderRadius: 12, fontSize: 12 }} />
        </PieChart>
      </ResponsiveContainer>
      {centerValue && (
        <div className="pointer-events-none absolute inset-0 flex flex-col items-center justify-center text-center">
          <span className="text-lg font-extrabold text-ink dark:text-white">{centerValue}</span>
          {centerLabel && <span className="text-[11px] text-ink-muted">{centerLabel}</span>}
        </div>
      )}
    </div>
  );
}

export function HBar({ label, value, max, color, right }: { label: string; value: number; max: number; color: string; right: string }) {
  const pct = max > 0 ? Math.max(0, Math.min(100, (value / max) * 100)) : 0;
  return (
    <div className="grid grid-cols-[minmax(0,1.3fr)_minmax(0,2fr)_auto] items-center gap-3 text-sm">
      <span className="truncate text-ink-soft dark:text-gray-300">{label}</span>
      <div className="h-2.5 overflow-hidden rounded-full bg-gray-100 dark:bg-gray-800"><div className="h-full rounded-full" style={{ width: `${pct}%`, background: color }} /></div>
      <span className="whitespace-nowrap text-right font-semibold tabular-nums">{right}</span>
    </div>
  );
}
