import { useEffect, useState } from 'react';
import { useI18n } from '../../../i18n';
import { useAuth } from '../../../lib/auth';
import { supabase } from '../../../lib/supabase';
import { rpc, unwrap } from '../../../lib/api';
import { errorMessage } from '../../../lib/errors';
import { LockStatus, pinProblem, UnlockResult } from '../../../lib/storeLock';
import { PinSetup, useStoreLockActions } from '../../../components/StoreLock';
import { Lock } from 'lucide-react';
import { useAction } from '../../../lib/useAction';
import { applyTheme, getTheme, Theme } from '../../../lib/theme';
import { Alert, Button, Card, CardHeader, Field, Input, PageHeader, Select } from '../../../components/ui';

export default function ProfilePage() {
  const { t, setLang, lang } = useI18n();
  const { context, refreshContext } = useAuth();
  const { run, busy } = useAction();
  const [f, setF] = useState({ full_name: '', phone: '' });
  const [theme, setTheme] = useState<Theme>(getTheme());
  const [pw, setPw] = useState({ a: '', b: '' });
  useEffect(() => { if (context?.profile) setF({ full_name: context.profile.full_name ?? '', phone: context.profile.phone ?? '' }); }, [context?.profile]);
  const save = async () => {
    await run(async () => unwrap(await supabase.from('profiles').update({ full_name: f.full_name, phone: f.phone || null, language: lang, theme }).eq('id', context!.user_id)), t('common.saved'));
    refreshContext();
  };
  const changePw = async () => {
    if (pw.a.length < 8 || pw.a !== pw.b) return;
    const ok = await run(async () => { const { error } = await supabase.auth.updateUser({ password: pw.a }); if (error) throw error; return true; }, t('auth.passwordUpdated'));
    if (ok) setPw({ a: '', b: '' });
  };
  return (
    <div>
      <PageHeader title={t('nav.profile')} subtitle={context?.email} />
      <div className="grid gap-4 lg:grid-cols-2">
        <Card>
          <CardHeader title={t('profile.details')} />
          <div className="space-y-4">
            <Field label={t('auth.fullName')}><Input value={f.full_name} onChange={(e) => setF({ ...f, full_name: e.target.value })} /></Field>
            <Field label={t('auth.phone')}><Input type="tel" value={f.phone} onChange={(e) => setF({ ...f, phone: e.target.value })} /></Field>
            <Field label={t('auth.email')} hint={context?.email_confirmed ? t('profile.emailVerified') : t('profile.emailNotVerified')}><Input disabled value={context?.email ?? ''} /></Field>
            <div className="grid grid-cols-2 gap-3">
              <Field label={t('common.language')}><Select value={lang} onChange={(e) => setLang(e.target.value as 'en' | 'fr')}><option value="fr">Français</option><option value="en">English</option></Select></Field>
              <Field label={t('common.theme')}><Select value={theme} onChange={(e) => { const th = e.target.value as Theme; setTheme(th); applyTheme(th); }}>
                <option value="light">{t('common.light')}</option><option value="dark">{t('common.dark')}</option><option value="system">{t('common.system')}</option></Select></Field>
            </div>
            <div className="flex justify-end"><Button loading={busy} onClick={save}>{t('common.save')}</Button></div>
          </div>
        </Card>
        <Card>
          <CardHeader title={t('profile.password')} />
          <div className="space-y-4">
            <Field label={t('auth.newPassword')} hint={t('auth.passwordHint')}><Input type="password" autoComplete="new-password" value={pw.a} onChange={(e) => setPw({ ...pw, a: e.target.value })} /></Field>
            <Field label={t('auth.confirmPassword')} error={pw.b && pw.a !== pw.b ? t('auth.passwordMismatch') : undefined}><Input type="password" autoComplete="new-password" value={pw.b} onChange={(e) => setPw({ ...pw, b: e.target.value })} /></Field>
            <div className="flex justify-end"><Button variant="outline" loading={busy} disabled={pw.a.length < 8 || pw.a !== pw.b} onClick={changePw}>{t('auth.updatePassword')}</Button></div>
          </div>
        </Card>
        <StoreLockSettings />
      </div>
    </div>
  );
}

const TIMEOUTS = [1, 5, 10, 15, 30, 60, 120, 240];

function StoreLockSettings() {
  const { t, has } = useI18n();
  const { storeLock } = useAuth();
  const { lock, enabled } = useStoreLockActions();
  const [cur, setCur] = useState('');
  const [next, setNext] = useState('');
  const [msg, setMsg] = useState<{ tone: 'green' | 'red'; text: string } | null>(null);
  const [busy, setBusy] = useState(false);
  const [creatingPin, setCreatingPin] = useState(false);
  const current = storeLock.status;
  if (!current || current.unavailable) return null;
  // The PIN is optional: until one is set, offer it here instead of asking for it on first access.
  if (!current.has_pin) {
    if (creatingPin) return <PinSetup mode="create" onDone={(s) => { storeLock.set(s); setCreatingPin(false); }} />;
    return (
      <Card>
        <CardHeader title={t('storeLock.settingsTitle')} subtitle={t('storeLock.pinOptional')}
          action={<Button size="sm" variant="outline" icon={<Lock className="h-4 w-4" />} onClick={() => setCreatingPin(true)}>{t('storeLock.setPin')}</Button>} />
      </Card>
    );
  }
  if (!enabled) return null;
  const status = storeLock.status!;
  const setTimeoutMinutes = async (m: number) => {
    try { storeLock.set(await rpc<LockStatus>('set_store_lock_timeout', { p_minutes: m })); setMsg({ tone: 'green', text: t('common.saved') }); }
    catch (e) { setMsg({ tone: 'red', text: errorMessage(e, t, has) }); }
  };
  const change = async () => {
    const p = pinProblem(next);
    if (p) { setMsg({ tone: 'red', text: t(p === 'too_simple' ? 'storeLock.tooSimple' : 'storeLock.fourDigits') }); return; }
    setBusy(true);
    try {
      const r = await rpc<UnlockResult>('change_store_pin', { p_current: cur, p_new: next });
      if (r.ok) { setCur(''); setNext(''); setMsg({ tone: 'green', text: t('storeLock.changed') }); }
      else setMsg({ tone: 'red', text: r.error === 'pin_temporarily_locked' ? t('storeLock.waitSeconds', { s: r.retry_after ?? 30 }) : t('storeLock.wrongPinNoCount') });
    } catch (e) { setMsg({ tone: 'red', text: errorMessage(e, t, has) }); } finally { setBusy(false); }
  };
  const label = (m: number) => (m < 60 ? t('storeLock.minutes', { n: m }) : m === 60 ? t('storeLock.hour') : t('storeLock.hours', { n: m / 60 }));
  return (
    <Card>
      <CardHeader title={t('storeLock.settingsTitle')} subtitle={t('storeLock.settingsSub')} action={<Button size="sm" variant="outline" icon={<Lock className="h-4 w-4" />} onClick={lock}>{t('storeLock.lockStore')}</Button>} />
      <div className="space-y-4">
        <Field label={t('storeLock.autoLock')}>
          <Select value={String(status.idle_minutes ?? 15)} onChange={(e) => setTimeoutMinutes(Number(e.target.value))}>
            {TIMEOUTS.map((m) => <option key={m} value={m}>{label(m)}</option>)}
          </Select>
        </Field>
        <div className="grid gap-3 sm:grid-cols-2">
          <Field label={t('storeLock.currentPin')}><Input type="password" inputMode="numeric" pattern="[0-9]*" maxLength={4} autoComplete="off" value={cur} onChange={(e) => setCur(e.target.value.replace(/\D/g, ''))} /></Field>
          <Field label={t('storeLock.newPin')}><Input type="password" inputMode="numeric" pattern="[0-9]*" maxLength={4} autoComplete="off" value={next} onChange={(e) => setNext(e.target.value.replace(/\D/g, ''))} /></Field>
        </div>
        {msg && <Alert tone={msg.tone}>{msg.text}</Alert>}
        <div className="flex justify-end"><Button variant="outline" loading={busy} disabled={cur.length !== 4 || next.length !== 4} onClick={change}>{t('storeLock.change')}</Button></div>
        <p className="text-xs text-ink-muted">{t('storeLock.note')}</p>
      </div>
    </Card>
  );
}
