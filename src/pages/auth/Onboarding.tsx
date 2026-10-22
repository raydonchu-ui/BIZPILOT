import { FormEvent, useState } from 'react';
import { Navigate, useNavigate } from 'react-router-dom';
import { useI18n } from '../../i18n';
import { useAuth } from '../../lib/auth';
import { rpc } from '../../lib/api';
import { errorMessage } from '../../lib/errors';
import { localToday } from '../../lib/dates';
import { Alert, Button, Card, Field, Input, Select } from '../../components/ui';
import { Logo } from '../../components/Logo';
import { LanguageSwitch } from '../../components/LanguageSwitch';

const CATEGORIES = ['grocery', 'general', 'drinks', 'hardware', 'electronics', 'fashion', 'cosmetics', 'other'];

export function OnboardingPage({ addAnother }: { addAnother?: boolean }) {
  const { t, lang, has } = useI18n();
  const { context, session, refreshContext } = useAuth();
  const nav = useNavigate();
  const [f, setF] = useState({
    name: '', owner_name: context?.profile?.full_name ?? '', phone: context?.profile?.phone ?? '', email: context?.email ?? '',
    category: 'grocery', city: '', address: '', language: lang, reporting_start_date: localToday(),
  });
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  if (!session) return <Navigate to="/login" replace />;
  if (!addAnother && context && context.businesses.length > 0) return <Navigate to="/app" replace />;
  const set = (k: keyof typeof f) => (e: { target: { value: string } }) => setF((x) => ({ ...x, [k]: e.target.value }));
  const submit = async (e: FormEvent) => {
    e.preventDefault();
    setError(null); setLoading(true);
    try {
      const id = await rpc<string>('create_business', { p: { ...f, country_code: 'CM' } });
      try { localStorage.setItem('bizpilot.business', id); } catch { /* ignore */ }
      await refreshContext();
      nav('/app/setup', { replace: true });
    } catch (err) {
      setError(errorMessage(err, t, has));
    } finally {
      setLoading(false);
    }
  };
  return (
    <div className="min-h-screen bg-gray-50 dark:bg-gray-950">
      <div className="mx-auto flex max-w-3xl items-center justify-between px-4 py-5"><Logo size="sm" /><LanguageSwitch persist /></div>
      <div className="mx-auto max-w-3xl px-4 pb-16">
        <h1 className="text-2xl font-extrabold tracking-tight sm:text-3xl">{t('onboarding.title')}</h1>
        <p className="mt-1 text-sm text-ink-muted dark:text-gray-400">{t('onboarding.subtitle')}</p>
        <Card className="mt-6">
          <form onSubmit={submit} className="grid gap-4 sm:grid-cols-2">
            <Field label={t('onboarding.businessName')} required className="sm:col-span-2"><Input required minLength={2} maxLength={120} value={f.name} onChange={set('name')} placeholder="Boutique Ma Bonne Étoile" /></Field>
            <Field label={t('onboarding.ownerName')} required><Input required value={f.owner_name} onChange={set('owner_name')} /></Field>
            <Field label={t('onboarding.category')} required>
              <Select value={f.category} onChange={set('category')}>{CATEGORIES.map((c) => <option key={c} value={c}>{t(`businessCategories.${c}`)}</option>)}</Select>
            </Field>
            <Field label={t('onboarding.businessPhone')}><Input type="tel" value={f.phone} onChange={set('phone')} placeholder="+237 6XX XX XX XX" /></Field>
            <Field label={t('onboarding.businessEmail')}><Input type="email" value={f.email} onChange={set('email')} /></Field>
            <Field label={t('onboarding.city')}><Input value={f.city} onChange={set('city')} placeholder="Douala, Yaoundé…" /></Field>
            <Field label={t('onboarding.address')}><Input value={f.address} onChange={set('address')} /></Field>
            <Field label={t('onboarding.country')} hint={t('onboarding.countryNote')}><Select disabled value="CM"><option value="CM">Cameroun / Cameroon</option></Select></Field>
            <Field label={t('onboarding.currency')}><Select disabled value="XAF"><option value="XAF">FCFA (XAF)</option></Select></Field>
            <Field label={t('onboarding.language')}>
              <Select value={f.language} onChange={set('language')}><option value="fr">Français</option><option value="en">English</option></Select>
            </Field>
            <Field label={t('onboarding.reportingStart')} hint={t('onboarding.reportingStartHint')}><Input type="date" value={f.reporting_start_date} onChange={set('reporting_start_date')} /></Field>
            {error && <div className="sm:col-span-2"><Alert tone="red">{error}</Alert></div>}
            <div className="sm:col-span-2"><Button type="submit" size="lg" loading={loading} block>{t('onboarding.create')}</Button></div>
          </form>
        </Card>
      </div>
    </div>
  );
}
