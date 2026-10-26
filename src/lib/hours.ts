// Opening hours of a store, read in the store's own time zone (Cameroon, UTC+1) so "Open now" is
// right for every visitor, wherever they are.

export type DayHours = { open?: string; close?: string; closed?: boolean } | undefined;
export const STORE_TIMEZONE = 'Africa/Douala';

/** Current weekday (mon…sun) and minutes since midnight in the given time zone. */
export function localClock(now: Date = new Date(), tz = STORE_TIMEZONE): { day: string; minutes: number } {
  const parts = new Intl.DateTimeFormat('en-GB', { timeZone: tz, weekday: 'short', hour: '2-digit', minute: '2-digit', hourCycle: 'h23' }).formatToParts(now);
  const get = (type: string) => parts.find((p) => p.type === type)?.value ?? '';
  return { day: get('weekday').slice(0, 3).toLowerCase(), minutes: Number(get('hour')) * 60 + Number(get('minute')) };
}

/** "08:00" → 480. Null when not a valid HH:MM. */
export function toMinutes(v: string | undefined): number | null {
  const m = /^(\d{1,2}):(\d{2})/.exec(v ?? '');
  return m ? Number(m[1]) * 60 + Number(m[2]) : null;
}

/**
 * Whether the store is open right now. `configured` is false when the seller has not entered any
 * hours, so the app shows no status rather than a guess.
 */
export function openStatus(hours: Record<string, DayHours> | null | undefined, now: Date = new Date()) {
  const { day, minutes } = localClock(now);
  const today = hours?.[day];
  const start = toMinutes(today?.open);
  const end = toMinutes(today?.close);
  const hasHours = Boolean(today && !today.closed && start !== null && end !== null);
  return {
    configured: Object.keys(hours ?? {}).length > 0,
    open: hasHours && start !== null && end !== null && minutes >= start && minutes < end,
    today: hasHours ? { open: today!.open!, close: today!.close! } : null,
  };
}

/** "08:00" → "8:00 AM" (English) or "08:00" (French, 24-hour). */
export function formatClock(hhmm: string, lang: 'en' | 'fr'): string {
  const m = toMinutes(hhmm);
  if (m === null) return hhmm;
  return new Date(2000, 0, 1, Math.floor(m / 60), m % 60).toLocaleTimeString(lang === 'fr' ? 'fr-FR' : 'en-US', { hour: 'numeric', minute: '2-digit' });
}
