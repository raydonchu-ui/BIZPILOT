import { describe, expect, it } from 'vitest';
import { formatClock, localClock, openStatus, toMinutes } from './hours';

const hours = {
  mon: { open: '08:00', close: '19:00' }, tue: { open: '08:00', close: '19:00' }, wed: { open: '08:00', close: '19:00' },
  thu: { open: '08:00', close: '19:00' }, fri: { open: '08:00', close: '19:00' }, sat: { open: '08:00', close: '19:00' },
  sun: { closed: true },
};
// 2026-10-26 is a Monday. Africa/Douala is UTC+1, so 09:00 local is 08:00 UTC.
const at = (iso: string) => new Date(iso);

describe('store opening hours (Africa/Douala)', () => {
  it('reads the weekday and time in Cameroon time, not in the visitor time zone', () => {
    expect(localClock(at('2026-10-26T08:00:00Z'))).toEqual({ day: 'mon', minutes: 9 * 60 });
    expect(localClock(at('2026-10-25T23:30:00Z'))).toEqual({ day: 'mon', minutes: 0 + 30 });
  });
  it('is open inside the hours and closed outside them', () => {
    expect(openStatus(hours, at('2026-10-26T08:00:00Z')).open).toBe(true); // 09:00 Monday
    expect(openStatus(hours, at('2026-10-26T19:30:00Z')).open).toBe(false); // 20:30 Monday
    expect(openStatus(hours, at('2026-10-26T06:30:00Z')).open).toBe(false); // 07:30 Monday
  });
  it('is closed all day on a day marked closed, and reports no hours for it', () => {
    const sunday = openStatus(hours, at('2026-10-25T08:00:00Z')); // Sunday 09:00
    expect(sunday.open).toBe(false);
    expect(sunday.today).toBeNull();
  });
  it('shows no status when no hours were entered', () => {
    expect(openStatus({}, at('2026-10-26T08:00:00Z')).configured).toBe(false);
    expect(openStatus(null, at('2026-10-26T08:00:00Z')).configured).toBe(false);
  });
  it('parses times and formats them for each language', () => {
    expect(toMinutes('08:30')).toBe(510);
    expect(toMinutes('bad')).toBeNull();
    expect(formatClock('08:00', 'en')).toMatch(/8:00\s?AM/);
    expect(formatClock('19:00', 'fr')).toMatch(/19:00/);
  });
});
