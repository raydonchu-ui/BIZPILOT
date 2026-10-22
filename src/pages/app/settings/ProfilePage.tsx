import { useEffect, useState } from 'react';
import { useI18n } from '../../../i18n';
import { useAuth } from '../../../lib/auth';
import { supabase } from '../../../lib/supabase';
import { unwrap } from '../../../lib/api';
import { useAction } from '../../../lib/useAction';
import { applyTheme, getTheme, Theme } from '../../../lib/theme';
import { Button, Card, CardHeader, Field, Input, PageHeader, Select } from '../../../components/ui';

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
      </div>
    </div>
  );
}
