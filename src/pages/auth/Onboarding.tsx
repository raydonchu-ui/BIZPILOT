import { FormEvent, useMemo, useState } from 'react';
import { Navigate, useNavigate } from 'react-router-dom';
import { useI18n } from '../../i18n';
import { useAuth } from '../../lib/auth';
import { rpc } from '../../lib/api';
import { errorMessage } from '../../lib/errors';
import { localToday } from '../../lib/dates';
import { Alert, Button, Card, Checkbox, Field, Input, Select } from '../../components/ui';
import { BUSINESS_TYPES, categoryTemplate } from '../../lib/catalogTemplates';
import { Logo } from '../../components/Logo';
import { LanguageSwitch } from '../../components/LanguageSwitch';


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
  const [created, setCreated] = useState(false);
  // Suggested categories for the chosen business type; all ticked, the owner unticks what they don't sell.
  const template = useMemo(() => categoryTemplate(f.category, f.language === 'fr' ? 'fr' : 'en'), [f.category, f.language]);
  const [off, setOff] = useState<Record<string, boolean>>({});
  const k = (top: string, sub?: string) => `${f.category}|${top}|${sub ?? ''}`;
  const chosen = template.filter((c) => !off[k(c.name)]).map((c) => ({ ...c, children: c.children.filter((s) => !off[k(c.name, s)]) }));
  if (!session) return <Navigate to="/login" replace />;
  if (!addAnother && !created && context && context.businesses.length > 0) return <Navigate to="/app" replace />;
  const set = (k: keyof typeof f) => (e: { target: { value: string } }) => setF((x) => ({ ...x, [k]: e.target.value }));
  const submit = async (e: FormEvent) => {
    e.preventDefault();
    setError(null); setLoading(true);
    try {
      const id = await rpc<string>('create_business', { p: { ...f, country_code: 'CM', categories: chosen } });
      try { localStorage.setItem('bizpilot.business', id); } catch { /* ignore */ }
      setCreated(true);
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
              <Select value={f.category} onChange={set('category')}>
                {[...BUSINESS_TYPES].sort((a, b) => (a === 'other' ? 1 : b === 'other' ? -1 : t(`businessCategories.${a}`).localeCompare(t(`businessCategories.${b}`), lang)))
                  .map((c) => <option key={c} value={c}>{t(`businessCategories.${c}`)}</option>)}
              </Select>
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
            <fieldset className="sm:col-span-2 rounded-xl border border-gray-200 p-4 dark:border-gray-800">
              <legend className="px-1 text-sm font-semibold">{t('catalog.onboardingCategories')} <span className="text-xs font-normal text-ink-muted">({t('catalog.optional')})</span></legend>
              <p className="mb-3 text-xs text-ink-muted dark:text-gray-400">{t('catalog.onboardingCategoriesSub')}</p>
              <div className="mb-3 flex gap-3 text-xs">
                <button type="button" className="font-semibold text-brand-700 underline" onClick={() => setOff({})}>{t('catalog.selectAll')}</button>
                <button type="button" className="font-semibold text-brand-700 underline" onClick={() => setOff(Object.fromEntries(template.flatMap((c) => [[k(c.name), true], ...c.children.map((s) => [k(c.name, s), true])])))}>{t('catalog.selectNone')}</button>
              </div>
              <div className="grid max-h-80 gap-3 overflow-y-auto pr-1 sm:grid-cols-2">
                {template.map((c) => (
                  <div key={c.name}>
                    <Checkbox checked={!off[k(c.name)]} onChange={(v) => setOff((o) => ({ ...o, [k(c.name)]: !v, ...Object.fromEntries(c.children.map((s) => [k(c.name, s), !v])) }))} label={c.name} />
                    {c.children.length > 0 && !off[k(c.name)] && (
                      <div className="ml-7 mt-1 space-y-1">
                        {c.children.map((s) => <Checkbox key={s} checked={!off[k(c.name, s)]} onChange={(v) => setOff((o) => ({ ...o, [k(c.name, s)]: !v }))} label={<span className="text-sm font-normal">{s}</span>} />)}
                      </div>
                    )}
                  </div>
                ))}
              </div>
            </fieldset>
            {error && <div className="sm:col-span-2"><Alert tone="red">{error}</Alert></div>}
            <div className="sm:col-span-2"><Button type="submit" size="lg" loading={loading} block>{t('onboarding.create')}</Button></div>
          </form>
        </Card>
      </div>
    </div>
  );
}
