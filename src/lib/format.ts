export type Lang = 'en' | 'fr';

const locale = (lang: Lang) => (lang === 'fr' ? 'fr-FR' : 'en-GB');

export function currencyLabel(currency: string) {
  return currency === 'XAF' ? 'FCFA' : currency;
}

export function formatMoney(value: number | string | null | undefined, lang: Lang, currency = 'XAF', decimals = 0) {
  if (value === null || value === undefined || value === '') return '—';
  const n = Number(value);
  if (!Number.isFinite(n)) return '—';
  const s = new Intl.NumberFormat(locale(lang), { minimumFractionDigits: 0, maximumFractionDigits: decimals }).format(n);
  return `${s} ${currencyLabel(currency)}`;
}

/** Shopper prices (storefront, product cards, shopper dashboard): "9,000 XAF", as in the BizPilot Market design. */
export function formatXaf(value: number | string | null | undefined, lang: Lang) {
  if (value === null || value === undefined || value === '') return '—';
  const n = Number(value);
  if (!Number.isFinite(n)) return '—';
  return `${new Intl.NumberFormat(locale(lang), { minimumFractionDigits: 0, maximumFractionDigits: 0 }).format(n)} XAF`;
}

/** Compact money for chart axes and small cards: 1.2M, 850K */
export function formatCompact(value: number, lang: Lang) {
  return new Intl.NumberFormat(locale(lang), { notation: 'compact', maximumFractionDigits: 1 }).format(value);
}

export function formatNumber(value: number | string | null | undefined, lang: Lang, maxDecimals = 3) {
  if (value === null || value === undefined || value === '') return '—';
  const n = Number(value);
  if (!Number.isFinite(n)) return '—';
  return new Intl.NumberFormat(locale(lang), { maximumFractionDigits: maxDecimals }).format(n);
}

export function formatPct(value: number | string | null | undefined, lang: Lang, digits = 1) {
  if (value === null || value === undefined) return '—';
  const n = Number(value);
  if (!Number.isFinite(n)) return '—';
  return `${new Intl.NumberFormat(locale(lang), { maximumFractionDigits: digits }).format(n)} %`;
}

export function formatDate(value: string | Date | null | undefined, lang: Lang, tz = 'Africa/Douala') {
  if (!value) return '—';
  const d = typeof value === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(value) ? new Date(value + 'T12:00:00Z') : new Date(value);
  return new Intl.DateTimeFormat(locale(lang), { day: '2-digit', month: 'short', year: 'numeric', timeZone: tz }).format(d);
}

export function formatDateTime(value: string | Date | null | undefined, lang: Lang, tz = 'Africa/Douala') {
  if (!value) return '—';
  return new Intl.DateTimeFormat(locale(lang), {
    day: '2-digit', month: 'short', year: 'numeric', hour: '2-digit', minute: '2-digit', timeZone: tz,
  }).format(new Date(value));
}

export function formatRelative(value: string | Date, lang: Lang) {
  const diff = (new Date(value).getTime() - Date.now()) / 1000;
  const rtf = new Intl.RelativeTimeFormat(locale(lang), { numeric: 'auto' });
  const abs = Math.abs(diff);
  if (abs < 60) return rtf.format(Math.round(diff), 'second');
  if (abs < 3600) return rtf.format(Math.round(diff / 60), 'minute');
  if (abs < 86400) return rtf.format(Math.round(diff / 3600), 'hour');
  if (abs < 86400 * 30) return rtf.format(Math.round(diff / 86400), 'day');
  return formatDate(value, lang);
}

/** Percentage change helper; null when the base is zero (no meaningful comparison). */
export function pctChange(cur: number, prev: number): number | null {
  if (!prev) return null;
  return ((cur - prev) / Math.abs(prev)) * 100;
}

export function toNumber(v: unknown, fallback = 0) {
  const n = typeof v === 'string' ? Number(v.replace(/\s/g, '').replace(',', '.')) : Number(v);
  return Number.isFinite(n) ? n : fallback;
}
