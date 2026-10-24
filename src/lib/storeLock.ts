// Store Lock client helpers. The server decides whether this signed-in session is locked
// (see migration 20261024000200_store_lock.sql); the app only mirrors that state, asks for the
// PIN and reports activity. The PIN itself is never stored in the browser.
import type { Session } from '@supabase/supabase-js';

export interface LockStatus {
  has_pin: boolean; locked: boolean; reason?: 'new_session' | 'manual' | 'idle' | 'pin_reset' | 'pin_changed' | null;
  idle_minutes?: number; retry_after?: number; can_reset?: boolean;
  /** The database has no Store Lock yet (older deployment): the app works without it. */
  unavailable?: boolean;
}

export interface UnlockResult { ok: boolean; error?: 'wrong_pin' | 'pin_temporarily_locked' | 'pin_not_set'; retry_after?: number; attempts_left?: number; status?: LockStatus }

export function sessionIdOf(session: Session | null | undefined): string | null {
  const token = session?.access_token;
  if (!token) return null;
  try {
    const payload = JSON.parse(atob(token.split('.')[1].replace(/-/g, '+').replace(/_/g, '/')));
    return typeof payload.session_id === 'string' ? payload.session_id : null;
  } catch {
    return null;
  }
}

// PostgREST answers this when the function does not exist (Store Lock migration not applied).
export const isMissingFunction = (e: any) => e?.code === 'PGRST202' || /Could not find the function/i.test(String(e?.message ?? ''));

// Mirrors the server rule so obvious PINs are refused before a round trip.
export function pinProblem(pin: string): 'four_digits' | 'too_simple' | null {
  if (!/^\d{4}$/.test(pin)) return 'four_digits';
  if (/^(\d)\1{3}$/.test(pin) || '0123456789'.includes(pin) || '9876543210'.includes(pin)) return 'too_simple';
  return null;
}

// Last known state per session, used only while offline. Contains no PIN.
const KEY = (sid: string) => `bizpilot.lock.${sid}`;
export function rememberLock(sid: string | null, locked: boolean) {
  if (!sid) return;
  try { localStorage.setItem(KEY(sid), locked ? 'locked' : 'unlocked'); } catch { /* storage unavailable */ }
}
export function lastKnownLock(sid: string | null): boolean | null {
  if (!sid) return null;
  try { const v = localStorage.getItem(KEY(sid)); return v === null ? null : v === 'locked'; } catch { return null; }
}

// Lets every open tab follow a lock/unlock done in another tab.
const channel = typeof BroadcastChannel !== 'undefined' ? new BroadcastChannel('bizpilot-store-lock') : null;
export function announceLockChange() { channel?.postMessage('changed'); }
export function onLockChange(cb: () => void) {
  const h = () => cb();
  channel?.addEventListener('message', h);
  window.addEventListener('bizpilot:store-locked', h);
  return () => { channel?.removeEventListener('message', h); window.removeEventListener('bizpilot:store-locked', h); };
}
// Any API call refused with 'store_locked' re-checks the lock (e.g. after an inactivity lock).
export function signalStoreLocked() { window.dispatchEvent(new Event('bizpilot:store-locked')); }
