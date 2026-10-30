// Mobile Money payment through Fapshi: the payer enters their number, Fapshi sends the payment
// request to that phone, they approve it with their PIN, and this panel updates on its own when the
// server has confirmed the payment with Fapshi. Nothing is marked paid by the browser.
import { FormEvent, useEffect, useRef, useState } from 'react';
import clsx from 'clsx';
import { CheckCircle2, ExternalLink, Loader2, Smartphone, XCircle } from 'lucide-react';
import { useI18n } from '../i18n';
import { errorMessage } from '../lib/errors';
import { formatMoney } from '../lib/format';
import { detectMedium, Medium, PayStart, verifyPayment } from '../lib/market';
import { rememberPendingPayment } from '../lib/pendingPayment';
import { Alert, Button, Field, Input } from './ui';

type Phase = { k: 'form' } | { k: 'waiting'; paymentId: string; since: number; test?: boolean } | { k: 'paid' } | { k: 'failed'; reason: string }
  | { k: 'page'; link: string };

const POLL_MS = 5000;
const MAX_WAIT_MS = 5 * 60_000;

export function MobileMoneyPay({ amount, defaultPhone, request, onPaid, compact, waitingFor }: {
  amount: number;
  /** A request already sent to the phone (e.g. right after checkout): start in the waiting state. */
  waitingFor?: string | null;
  defaultPhone?: string | null;
  /** Without a phone, returns a Fapshi payment page link instead of a phone prompt. */
  request: (phone?: string, medium?: Medium) => Promise<PayStart>;
  onPaid: () => void;
  compact?: boolean;
}) {
  const { t, lang, has } = useI18n();
  const [phone, setPhone] = useState(defaultPhone ?? '');
  const [choice, setChoice] = useState<Medium | 'auto'>('auto');
  const [phase, setPhase] = useState<Phase>(waitingFor ? { k: 'waiting', paymentId: waitingFor, since: Date.now() } : { k: 'form' });
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [now, setNow] = useState(Date.now());
  const detected = detectMedium(phone);
  const medium = choice === 'auto' ? detected ?? undefined : choice;
  const paidCalled = useRef(false);

  // While waiting, ask the server (which asks Fapshi) every few seconds.
  useEffect(() => {
    if (phase.k !== 'waiting') return;
    let stop = false;
    const tick = async () => {
      setNow(Date.now());
      try {
        const r = await verifyPayment(phase.paymentId);
        if (stop) return;
        if (r.status === 'successful') {
          setPhase({ k: 'paid' });
          if (!paidCalled.current) { paidCalled.current = true; onPaid(); }
          return;
        }
        if (r.status === 'failed' || r.status === 'expired') { setPhase({ k: 'failed', reason: 'declined' }); return; }
      } catch { /* network blip: keep waiting */ }
      if (Date.now() - phase.since > MAX_WAIT_MS) { setPhase({ k: 'failed', reason: 'timeout' }); return; }
      if (!stop) timer = setTimeout(tick, POLL_MS);
    };
    let timer = setTimeout(tick, 3000);
    return () => { stop = true; clearTimeout(timer); };
  }, [phase, onPaid]);

  const start = async (e?: FormEvent) => {
    e?.preventDefault();
    setError(null);
    if (!detectMedium(phone) && choice === 'auto') { setError(t('pay.invalidPhone')); return; }
    setBusy(true);
    try {
      const r = await request(phone, medium);
      if (r.mode === 'direct') setPhase({ k: 'waiting', paymentId: r.payment_id, since: Date.now(), test: r.test_mode });
      // Fapshi refused to push the request to the phone (direct pay not activated on the Fapshi
      // account): say so plainly and continue on Fapshi's secure page, where the number is entered.
      // The payment is remembered, so it is checked when the customer comes back to BizPilot.
      else if (r.direct_failed) { rememberPendingPayment(r.payment_id); setPhase({ k: 'page', link: r.link }); }
      else { rememberPendingPayment(r.payment_id); window.location.assign(r.link); }
    } catch (err) {
      setError(errorMessage(err, t, has));
    } finally {
      setBusy(false);
    }
  };
  const usePage = async () => {
    setBusy(true);
    try {
      const r = await request();
      if (r.mode === 'link') window.location.assign(r.link);
    } catch (err) { setError(errorMessage(err, t, has)); setBusy(false); }
  };

  if (phase.k === 'page') {
    return (
      <div className="space-y-3 rounded-2xl border border-blue-200 bg-blue-50 p-5 dark:border-blue-900 dark:bg-blue-950/40" role="status">
        <p className="font-bold">{t('pay.pageTitle')}</p>
        <p className="text-sm">{t('pay.pageBody', { phone })}</p>
        <ol className="list-decimal space-y-1 pl-6 text-sm text-ink-soft dark:text-gray-300">
          <li>{t('pay.pageStep1')}</li><li>{t('pay.pageStep2', { phone })}</li><li>{t('pay.pageStep3')}</li>
        </ol>
        <a href={phase.link} className="inline-flex w-full items-center justify-center gap-2 rounded-xl bg-brand-700 px-4 py-3 font-semibold text-white hover:bg-brand-800">
          <ExternalLink className="h-4 w-4" />{t('pay.pageButton', { amount: formatMoney(amount, lang) })}</a>
        <Button size="sm" variant="ghost" onClick={() => setPhase({ k: 'form' })}>{t('pay.changeNumber')}</Button>
      </div>
    );
  }
  if (phase.k === 'paid') {
    return (
      <div className="flex flex-col items-center gap-2 rounded-2xl bg-brand-50 p-5 text-center dark:bg-brand-900/30" role="status">
        <CheckCircle2 className="h-10 w-10 text-brand-600" />
        <p className="text-lg font-bold">{t('pay.paidTitle')}</p>
        <p className="text-sm text-ink-soft dark:text-gray-300">{t('pay.paidBody', { amount: formatMoney(amount, lang) })}</p>
      </div>
    );
  }
  if (phase.k === 'waiting') {
    const secs = Math.max(0, Math.round((now - phase.since) / 1000));
    return (
      <div className="space-y-3 rounded-2xl border border-amber-200 bg-amber-50 p-5 dark:border-amber-900 dark:bg-amber-950/40" role="status" aria-live="polite">
        <div className="flex items-start gap-3">
          <Loader2 className="mt-0.5 h-6 w-6 shrink-0 animate-spin text-amber-700" />
          <div>
            <p className="font-bold">{t('pay.checkPhoneTitle')}</p>
            <p className="mt-1 text-sm">{t('pay.checkPhoneBody', { amount: formatMoney(amount, lang), phone })}</p>
          </div>
        </div>
        {phase.test && <Alert tone="blue" title={t('pay.testTitle')}>{t('pay.testBody')}</Alert>}
        <ol className="list-decimal space-y-1 pl-6 text-sm text-ink-soft dark:text-gray-300">
          <li>{t('pay.step1')}</li><li>{t('pay.step2')}</li><li>{t('pay.step3')}</li>
        </ol>
        <p className="text-xs text-ink-muted">{medium === 'orange money' ? t('pay.noPromptOrange') : t('pay.noPromptMtn')}</p>
        <p className="text-xs text-ink-muted">{t('pay.waiting', { s: secs })}</p>
        <Button size="sm" variant="ghost" onClick={() => setPhase({ k: 'form' })}>{t('pay.changeNumber')}</Button>
      </div>
    );
  }
  return (
    <form onSubmit={start} className={clsx('space-y-3', !compact && 'rounded-2xl border border-brand-200 bg-brand-50/60 p-4 dark:border-brand-900 dark:bg-brand-950/30')}>
      {phase.k === 'failed' && <Alert tone="red">{phase.reason === 'timeout' ? t('pay.timeout') : t('pay.declined')}</Alert>}
      <p className="flex items-center gap-2 font-bold"><Smartphone className="h-5 w-5 text-brand-700" />{t('pay.title', { amount: formatMoney(amount, lang) })}</p>
      <p className="text-sm text-ink-soft dark:text-gray-300">{t('pay.intro')}</p>
      <Field label={t('pay.phone')} hint={detected ? t(`pay.detected.${detected === 'mobile money' ? 'mtn' : 'orange'}`) : t('pay.phoneHint')}>
        <Input type="tel" inputMode="tel" autoComplete="tel" required value={phone} onChange={(e) => setPhone(e.target.value)} placeholder="6XX XX XX XX" />
      </Field>
      <div className="flex flex-wrap gap-2" role="radiogroup" aria-label={t('pay.operator')}>
        {(['auto', 'mobile money', 'orange money'] as const).map((m) => (
          <button key={m} type="button" role="radio" aria-checked={choice === m} onClick={() => setChoice(m)}
            className={clsx('rounded-full px-3 py-1.5 text-sm font-semibold ring-1', choice === m
              ? m === 'orange money' ? 'bg-orange-500 text-white ring-orange-500' : m === 'mobile money' ? 'bg-yellow-400 text-gray-900 ring-yellow-400' : 'bg-brand-700 text-white ring-brand-700'
              : 'bg-white ring-gray-300 dark:bg-gray-900 dark:ring-gray-700')}>
            {t(`pay.op.${m === 'auto' ? 'auto' : m === 'mobile money' ? 'mtn' : 'orange'}`)}
          </button>
        ))}
      </div>
      {error && <Alert tone="red">{error}</Alert>}
      <Button type="submit" block size="lg" loading={busy}>{t('pay.send', { amount: formatMoney(amount, lang) })}</Button>
      <p className="text-xs text-ink-muted">{t('pay.secure')}</p>
      <button type="button" onClick={usePage} disabled={busy} className="inline-flex items-center gap-1 text-xs font-semibold text-brand-700 hover:underline disabled:opacity-50">
        <ExternalLink className="h-3.5 w-3.5" />{t('pay.usePage')}
      </button>
      {phase.k === 'failed' && <p className="flex items-center gap-1 text-xs text-ink-muted"><XCircle className="h-3.5 w-3.5" />{t('pay.retryHint')}</p>}
    </form>
  );
}
