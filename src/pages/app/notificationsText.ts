import type { Lang } from '../../lib/format';
import { formatDate, formatMoney } from '../../lib/format';

type T = (k: string, p?: Record<string, string | number | null | undefined>) => string;

export function notificationText(n: { type: string; params: Record<string, any> }, t: T, lang: Lang) {
  const p = n.params ?? {};
  const money = (v: unknown) => formatMoney(v as number, lang);
  const date = (v: unknown) => formatDate(v as string, lang);
  const key = `notifications.types.${n.type}`;
  const params = {
    ...p, amount: p.amount !== undefined ? money(p.amount) : undefined, due_date: p.due_date ? date(p.due_date) : undefined,
    first_expiry: p.first_expiry ? date(p.first_expiry) : undefined, period_end: p.period_end ? date(p.period_end) : undefined,
    current_period_end: p.current_period_end ? date(p.current_period_end) : undefined, trial_ends_at: p.trial_ends_at ? date(p.trial_ends_at) : undefined,
  };
  return { title: t(`${key}.title`, params), body: t(`${key}.body`, params) };
}
