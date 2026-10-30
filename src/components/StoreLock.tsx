import { FormEvent, ReactNode, useCallback, useEffect, useRef, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { Delete, Lock, LogOut, ShieldCheck } from 'lucide-react';
import { useI18n } from '../i18n';
import { useAuth } from '../lib/auth';
import { queryClient, rpc } from '../lib/api';
import { errorMessage } from '../lib/errors';
import { LockStatus, pinProblem, UnlockResult } from '../lib/storeLock';
import { Alert, Button, Card, ErrorState, PageLoader } from './ui';
import { Logo } from './Logo';

// Business data cached in memory is dropped when the store locks.
function dropBusinessData() {
  queryClient.removeQueries({ predicate: (q) => !['store-lock', 'my_context', 'auth-providers'].includes(String(q.queryKey[0])) });
}

export function useStoreLockActions() {
  const { storeLock } = useAuth();
  const lock = useCallback(async () => {
    try {
      const s = await rpc<LockStatus>('lock_store');
      dropBusinessData();
      storeLock.set(s);
    } catch {
      // Offline: lock locally; unlocking needs the server.
      dropBusinessData();
      storeLock.set({ ...(storeLock.status ?? { has_pin: true }), has_pin: true, locked: true, reason: 'manual' });
    }
  }, [storeLock]);
  return { lock, enabled: Boolean(storeLock.status?.has_pin && !storeLock.status.unavailable) };
}

/** 4-digit PIN entry: masked field (works with phone keyboards and hardware keypads) + on-screen keypad. */
function PinPad({ value, onChange, onComplete, label, disabled, autoFocus = true }:
  { value: string; onChange: (v: string) => void; onComplete?: (v: string) => void; label: string; disabled?: boolean; autoFocus?: boolean }) {
  const input = useRef<HTMLInputElement>(null);
  const put = (v: string) => {
    const clean = v.replace(/\D/g, '').slice(0, 4);
    onChange(clean);
    if (clean.length === 4) onComplete?.(clean);
  };
  return (
    <div>
      <label className="sr-only" htmlFor={`pin-${label}`}>{label}</label>
      <div className="relative mx-auto w-56" onClick={() => input.current?.focus()}>
        <input ref={input} id={`pin-${label}`} aria-label={label} type="password" inputMode="numeric" pattern="[0-9]*" autoComplete="off"
          maxLength={4} autoFocus={autoFocus} disabled={disabled} value={value} onChange={(e) => put(e.target.value)}
          className="absolute inset-0 h-full w-full cursor-pointer opacity-0" />
        <div className="grid grid-cols-4 gap-3" aria-hidden="true">
          {[0, 1, 2, 3].map((i) => (
            <div key={i} className={`flex h-14 items-center justify-center rounded-xl border-2 text-2xl ${i < value.length ? 'border-brand-600 bg-brand-50 dark:bg-brand-950/40' : 'border-gray-300 dark:border-gray-700'}`}>
              {i < value.length ? '•' : ''}
            </div>
          ))}
        </div>
      </div>
      <div className="mx-auto mt-5 grid w-56 grid-cols-3 gap-2" aria-hidden="true">
        {['1', '2', '3', '4', '5', '6', '7', '8', '9', '', '0', 'del'].map((k) => k === '' ? <span key="blank" /> : (
          <button key={k} type="button" tabIndex={-1} disabled={disabled} onClick={() => (k === 'del' ? onChange(value.slice(0, -1)) : put(value + k))}
            className="flex h-12 items-center justify-center rounded-xl bg-gray-100 text-lg font-semibold text-ink hover:bg-gray-200 disabled:opacity-50 dark:bg-gray-800 dark:text-white dark:hover:bg-gray-700">
            {k === 'del' ? <Delete className="h-5 w-5" /> : k}
          </button>
        ))}
      </div>
    </div>
  );
}

function Shell({ title, body, children, icon }: { title: string; body?: ReactNode; children: ReactNode; icon?: ReactNode }) {
  return (
    <div className="flex min-h-screen flex-col items-center justify-center bg-gray-50 px-4 py-10 dark:bg-gray-950">
      <div className="mb-6"><Logo /></div>
      <Card className="w-full max-w-sm text-center">
        <div className="mx-auto mb-3 flex h-12 w-12 items-center justify-center rounded-full bg-brand-50 text-brand-700 dark:bg-brand-950/50 dark:text-brand-300">{icon ?? <Lock className="h-6 w-6" />}</div>
        <h1 className="text-xl font-extrabold">{title}</h1>
        {body && <p className="mt-1 text-sm text-ink-muted dark:text-gray-400">{body}</p>}
        <div className="mt-6">{children}</div>
      </Card>
    </div>
  );
}

function PinSetup({ onDone, mode = 'create' }: { onDone: (s: LockStatus) => void; mode?: 'create' | 'reset' }) {
  const { t, has } = useI18n();
  const [pin, setPin] = useState('');
  const [confirm, setConfirm] = useState('');
  const [step, setStep] = useState<1 | 2>(1);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const first = (v: string) => {
    const p = pinProblem(v);
    if (p) { setError(t(p === 'too_simple' ? 'storeLock.tooSimple' : 'storeLock.fourDigits')); setPin(''); return; }
    setError(null); setStep(2);
  };
  const second = async (v: string) => {
    if (v !== pin) { setError(t('storeLock.mismatch')); setPin(''); setConfirm(''); setStep(1); return; }
    setBusy(true);
    try {
      const s = await rpc<LockStatus>(mode === 'reset' ? 'reset_store_pin' : 'set_store_pin', { [mode === 'reset' ? 'p_new' : 'p_pin']: v });
      onDone(s);
    } catch (e) {
      setError(errorMessage(e, t, has)); setPin(''); setConfirm(''); setStep(1);
    } finally { setBusy(false); }
  };
  return (
    <Shell title={mode === 'reset' ? t('storeLock.resetTitle') : t('storeLock.setupTitle')} icon={<ShieldCheck className="h-6 w-6" />}
      body={mode === 'reset' ? t('storeLock.resetBody') : t('storeLock.setupBody')}>
      <p className="mb-3 text-sm font-semibold">{step === 1 ? t(mode === 'reset' ? 'storeLock.newPin' : 'storeLock.pin') : t('storeLock.confirmPin')}</p>
      {step === 1
        ? <PinPad key="p1" label={t('storeLock.pin')} value={pin} onChange={setPin} onComplete={first} disabled={busy} />
        : <PinPad key="p2" label={t('storeLock.confirmPin')} value={confirm} onChange={setConfirm} onComplete={second} disabled={busy} />}
      {error && <div className="mt-4"><Alert tone="red">{error}</Alert></div>}
      <p className="mt-5 text-xs text-ink-muted">{t('storeLock.note')}</p>
    </Shell>
  );
}

function LockScreen({ status, onStatus }: { status: LockStatus; onStatus: (s: LockStatus) => void }) {
  const { t, has } = useI18n();
  const { signOut, context, storeLock } = useAuth();
  const nav = useNavigate();
  const [pin, setPin] = useState('');
  const [error, setError] = useState<string | null>(null);
  const [wait, setWait] = useState(status.retry_after ?? 0);
  const [busy, setBusy] = useState(false);
  const [forgot, setForgot] = useState(false);
  // Coming back from "Forgot PIN?" → signed in again: go straight to choosing a new PIN. The marker is read once,
  // but the server's can_reset is checked on every render, because the first status may not include it yet.
  const [wantsReset, setWantsReset] = useState(() => new URLSearchParams(window.location.search).get('pin') === 'reset');
  const [resetting, setResetting] = useState(false);
  const showReset = resetting || (wantsReset && Boolean(status.can_reset));
  useEffect(() => { // the marker is used once
    const url = new URL(window.location.href);
    if (!url.searchParams.has('pin')) return;
    url.searchParams.delete('pin');
    window.history.replaceState(window.history.state, '', url.pathname + url.search + url.hash);
  }, []);
  useEffect(() => {
    if (wait <= 0) return;
    const id = setInterval(() => setWait((w) => Math.max(0, w - 1)), 1000);
    return () => clearInterval(id);
  }, [wait > 0]); // eslint-disable-line react-hooks/exhaustive-deps

  const submit = async (v: string) => {
    if (busy || wait > 0) return;
    setBusy(true); setError(null);
    try {
      const r = await rpc<UnlockResult>('unlock_store', { p_pin: v });
      if (r.ok && r.status) { onStatus(r.status); return; }
      setPin('');
      if (r.error === 'pin_temporarily_locked') { setWait(r.retry_after ?? 30); setError(null); }
      else setError(r.attempts_left !== undefined ? t('storeLock.wrongPin', { n: r.attempts_left }) : t('storeLock.wrongPinNoCount'));
    } catch (e) {
      setPin('');
      setError(storeLock.offline || !navigator.onLine ? t('storeLock.offline') : errorMessage(e, t, has));
    } finally { setBusy(false); }
  };
  if (showReset) return <PinSetup mode="reset" onDone={(s) => { setResetting(false); setWantsReset(false); onStatus(s); setError(t('storeLock.resetDone')); }} />;
  const reasonText = status.reason === 'idle' ? t('storeLock.lockedIdle') : status.reason === 'new_session' ? t('storeLock.lockedNew')
    : status.reason === 'pin_reset' ? t('storeLock.lockedReset') : status.reason === 'pin_changed' ? t('storeLock.lockedChanged') : t('storeLock.lockedBody');
  const startForgot = () => (status.can_reset ? setResetting(true) : setForgot(true));
  return (
    <Shell title={t('storeLock.lockedTitle')} body={<>{reasonText}{context?.email && <span className="mt-1 block text-xs">{context.email}</span>}</>}>
      {forgot ? (
        <div className="space-y-4 text-left">
          <p className="font-semibold">{t('storeLock.forgotTitle')}</p>
          <p className="text-sm text-ink-muted">{t('storeLock.forgotBody')}</p>
          <Button block onClick={async () => { await signOut(); nav(`/login?next=${encodeURIComponent('/app?pin=reset')}`, { replace: true }); }}>{t('storeLock.forgotContinue')}</Button>
          <Button block variant="ghost" onClick={() => setForgot(false)}>{t('common.cancel')}</Button>
        </div>
      ) : (
        <form onSubmit={(e: FormEvent) => { e.preventDefault(); if (pin.length === 4) submit(pin); }}>
          <PinPad label={t('storeLock.pin')} value={pin} onChange={setPin} onComplete={submit} disabled={busy || wait > 0} />
          {wait > 0 && <div className="mt-4"><Alert tone="amber">{t('storeLock.waitSeconds', { s: wait })}</Alert></div>}
          {error && <div className="mt-4"><Alert tone={error === t('storeLock.resetDone') ? 'green' : 'red'}>{error}</Alert></div>}
          <Button type="submit" className="mt-5" block loading={busy} disabled={pin.length !== 4 || wait > 0}>{t('storeLock.unlock')}</Button>
          <div className="mt-4 flex items-center justify-between text-sm">
            <button type="button" className="font-semibold text-brand-700 hover:underline dark:text-brand-400" onClick={startForgot}>{t('storeLock.forgot')}</button>
            <button type="button" className="inline-flex items-center gap-1 text-ink-muted hover:text-ink" onClick={async () => { await signOut(); nav('/login', { replace: true }); }}>
              <LogOut className="h-4 w-4" />{t('storeLock.signOut')}</button>
          </div>
        </form>
      )}
    </Shell>
  );
}

/** Locks after the user's inactivity period and reports activity so the server can enforce it too. */
function IdleWatcher({ minutes }: { minutes: number }) {
  const { lock } = useStoreLockActions();
  const { storeLock } = useAuth();
  const last = useRef(Date.now());
  const lastBeat = useRef(Date.now());
  useEffect(() => {
    const mark = () => { last.current = Date.now(); };
    const events = ['pointerdown', 'keydown', 'touchstart', 'wheel', 'scroll', 'mousemove'] as const;
    events.forEach((e) => window.addEventListener(e, mark, { passive: true }));
    const beatEvery = Math.min(60_000, (minutes * 60_000) / 2);
    const id = window.setInterval(async () => {
      const now = Date.now();
      if (now - last.current >= minutes * 60_000) { lock(); return; }
      if (last.current > lastBeat.current && now - lastBeat.current >= beatEvery && navigator.onLine) {
        lastBeat.current = now;
        try {
          const s = await rpc<LockStatus>('store_lock_heartbeat');
          if (s.locked) storeLock.refresh();
        } catch { /* next tick */ }
      }
    }, 5_000);
    const onVisible = () => { if (document.visibilityState === 'visible') storeLock.refresh(); };
    document.addEventListener('visibilitychange', onVisible);
    return () => { events.forEach((e) => window.removeEventListener(e, mark)); window.clearInterval(id); document.removeEventListener('visibilitychange', onVisible); };
  }, [minutes, lock, storeLock]);
  return null;
}

// A PIN is created on first access to a store dashboard; someone without a business yet is
// sent on to onboarding first (the PIN screen follows once the business exists).
function NeedsPin({ children, onDone }: { children: ReactNode; onDone: (s: LockStatus) => void }) {
  const { context, contextLoading } = useAuth();
  if (contextLoading || context === undefined) return <PageLoader />;
  if (!context || context.businesses.length === 0) return <>{children}</>;
  return <PinSetup onDone={onDone} />;
}

/**
 * Protects the dashboard: asks for a PIN to be created on first access (requirePin), shows the lock
 * screen while the server says this session is locked, and locks after inactivity.
 */
export function StoreLockGate({ children, requirePin }: { children: ReactNode; requirePin: boolean }) {
  const { t } = useI18n();
  const { storeLock, signOut, refreshContext } = useAuth();
  const nav = useNavigate();
  const s = storeLock.status;
  const accept = (st: LockStatus) => { storeLock.set(st); if (!st.locked) refreshContext(); };
  if (storeLock.loading) return <PageLoader />;
  if (!s) {
    return (
      <div className="flex min-h-screen items-center justify-center p-4">
        <div className="w-full max-w-md space-y-3">
          <ErrorState error={storeLock.error ?? { message: 'network_error' }} onRetry={() => storeLock.refresh()} />
          <Button block variant="ghost" onClick={async () => { await signOut(); nav('/login', { replace: true }); }}>{t('storeLock.signOut')}</Button>
        </div>
      </div>
    );
  }
  if (s.unavailable) return <>{children}</>;
  if (!s.has_pin) return requirePin ? <NeedsPin onDone={accept}>{children}</NeedsPin> : <>{children}</>;
  if (s.locked) return <LockScreen status={s} onStatus={accept} />;
  return <><IdleWatcher minutes={s.idle_minutes ?? 15} />{children}</>;
}
