export type PeriodKey =
  | 'today' | 'yesterday' | 'this_week' | 'last_7' | 'this_month' | 'last_month' | 'last_30' | 'last_90' | 'this_year' | 'custom';

export interface Period { key: PeriodKey; from: string; to: string }

/** Today's date (YYYY-MM-DD) in the business timezone. */
export function localToday(tz = 'Africa/Douala'): string {
  const parts = new Intl.DateTimeFormat('en-CA', { timeZone: tz, year: 'numeric', month: '2-digit', day: '2-digit' })
    .format(new Date());
  return parts; // en-CA formats as YYYY-MM-DD
}

export function addDays(iso: string, days: number) {
  const d = new Date(iso + 'T12:00:00Z');
  d.setUTCDate(d.getUTCDate() + days);
  return d.toISOString().slice(0, 10);
}

export function daysBetween(a: string, b: string) {
  return Math.round((new Date(b + 'T12:00:00Z').getTime() - new Date(a + 'T12:00:00Z').getTime()) / 86400000);
}

export function periodRange(key: PeriodKey, tz = 'Africa/Douala', custom?: { from: string; to: string }): Period {
  const today = localToday(tz);
  const d = new Date(today + 'T12:00:00Z');
  const iso = (x: Date) => x.toISOString().slice(0, 10);
  switch (key) {
    case 'today': return { key, from: today, to: today };
    case 'yesterday': { const y = addDays(today, -1); return { key, from: y, to: y }; }
    case 'this_week': { const dow = (d.getUTCDay() + 6) % 7; return { key, from: addDays(today, -dow), to: today }; }
    case 'last_7': return { key, from: addDays(today, -6), to: today };
    case 'last_30': return { key, from: addDays(today, -29), to: today };
    case 'last_90': return { key, from: addDays(today, -89), to: today };
    case 'this_month': return { key, from: today.slice(0, 8) + '01', to: today };
    case 'last_month': {
      const first = new Date(Date.UTC(d.getUTCFullYear(), d.getUTCMonth() - 1, 1, 12));
      const last = new Date(Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), 0, 12));
      return { key, from: iso(first), to: iso(last) };
    }
    case 'this_year': return { key, from: today.slice(0, 4) + '-01-01', to: today };
    case 'custom': return { key, from: custom?.from ?? today, to: custom?.to ?? today };
  }
}

export function grainFor(from: string, to: string): 'day' | 'week' | 'month' {
  const days = daysBetween(from, to) + 1;
  if (days <= 45) return 'day';
  if (days <= 200) return 'week';
  return 'month';
}
