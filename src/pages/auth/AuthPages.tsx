import { FormEvent, ReactNode, useEffect, useState } from 'react';
import { Link, Navigate, useNavigate, useSearchParams } from 'react-router-dom';
import { MailCheck } from 'lucide-react';
import { useI18n } from '../../i18n';
import { supabase, supabaseConfigured } from '../../lib/supabase';
import { errorMessage } from '../../lib/errors';
import { useAuth } from '../../lib/auth';
import { Alert, Button, Checkbox, Field, Input } from '../../components/ui';
import { Logo } from '../../components/Logo';
import { LanguageSwitch } from '../../components/LanguageSwitch';

function AuthShell({ title, subtitle, children, footer }: { title: string; subtitle?: string; children: ReactNode; footer?: ReactNode }) {
  const { t } = useI18n();
  return (
    <div className="flex min-h-screen bg-gray-50 dark:bg-gray-950">
      <div className="relative hidden w-[44%] flex-col justify-between bg-gradient-to-br from-brand-800 via-brand-900 to-brand-950 p-10 text-white lg:flex">
        <Logo inverse />
        <div>
          <p className="text-3xl font-extrabold leading-tight">{t('brand.promise')}</p>
          <p className="mt-4 max-w-md text-brand-100">{t('site.home.heroBody')}</p>
        </div>
        <p className="text-xs text-brand-200">{t('site.footer.madeFor')}</p>
      </div>
      <div className="flex flex-1 flex-col">
        <div className="flex items-center justify-between p-4 sm:p-6">
          <div className="lg:invisible"><Logo size="sm" /></div>
          <LanguageSwitch />
        </div>
        <div className="flex flex-1 items-center justify-center px-4 pb-12">
          <div className="w-full max-w-md">
            <h1 className="text-2xl font-extrabold tracking-tight">{title}</h1>
            {subtitle && <p className="mt-1 text-sm text-ink-muted dark:text-gray-400">{subtitle}</p>}
            {!supabaseConfigured && <div className="mt-4"><Alert tone="red">{t('errors.supabase_not_configured')}</Alert></div>}
            <div className="mt-6">{children}</div>
            {footer && <div className="mt-6 text-center text-sm text-ink-muted dark:text-gray-400">{footer}</div>}
          </div>
        </div>
      </div>
    </div>
  );
}

export function LoginPage() {
  const { t, has } = useI18n();
  const { session } = useAuth();
  const [params] = useSearchParams();
  const nav = useNavigate();
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  if (session) return <Navigate to={params.get('next') ?? '/app'} replace />;
  const submit = async (e: FormEvent) => {
    e.preventDefault();
    setLoading(true); setError(null);
    const { error: err } = await supabase.auth.signInWithPassword({ email: email.trim(), password });
    setLoading(false);
    if (err) setError(errorMessage(err, t, has));
    else nav(params.get('next') ?? '/app', { replace: true });
  };
  return (
    <AuthShell title={t('auth.loginTitle')} subtitle={t('auth.loginSubtitle')}
      footer={<>{t('auth.noAccount')} <Link to="/signup" className="font-semibold text-brand-700 hover:underline dark:text-brand-400">{t('auth.createAccount')}</Link></>}>
      <form onSubmit={submit} className="space-y-4">
        {params.get('verified') && <Alert tone="green">{t('auth.verified')}</Alert>}
        <Field label={t('auth.email')} htmlFor="email"><Input id="email" type="email" autoComplete="email" required value={email} onChange={(e) => setEmail(e.target.value)} /></Field>
        <Field label={t('auth.password')} htmlFor="password"><Input id="password" type="password" autoComplete="current-password" required value={password} onChange={(e) => setPassword(e.target.value)} /></Field>
        <div className="text-right"><Link to="/forgot-password" className="text-sm font-semibold text-brand-700 hover:underline dark:text-brand-400">{t('auth.forgot')}</Link></div>
        {error && <Alert tone="red">{error}</Alert>}
        <Button type="submit" block size="lg" loading={loading}>{t('auth.login')}</Button>
      </form>
    </AuthShell>
  );
}

export function SignupPage() {
  const { t, lang, has } = useI18n();
  const { session } = useAuth();
  const nav = useNavigate();
  const [f, setF] = useState({ full_name: '', email: '', phone: '', password: '', confirm: '' });
  const [accept, setAccept] = useState(false);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [sentTo, setSentTo] = useState<string | null>(null);
  if (session) return <Navigate to="/app" replace />;
  const set = (k: keyof typeof f) => (e: { target: { value: string } }) => setF((x) => ({ ...x, [k]: e.target.value }));
  const submit = async (e: FormEvent) => {
    e.preventDefault();
    setError(null);
    if (f.password.length < 8) return setError(t('auth.passwordTooShort'));
    if (f.password !== f.confirm) return setError(t('auth.passwordMismatch'));
    if (!accept) return setError(t('auth.mustAccept'));
    setLoading(true);
    const { data, error: err } = await supabase.auth.signUp({
      email: f.email.trim(), password: f.password,
      options: { data: { full_name: f.full_name.trim(), phone: f.phone.trim(), language: lang }, emailRedirectTo: `${window.location.origin}/login?verified=1` },
    });
    setLoading(false);
    if (err) return setError(errorMessage(err, t, has));
    if (data.session) nav('/onboarding', { replace: true });
    else setSentTo(f.email.trim());
  };
  if (sentTo) {
    return (
      <AuthShell title={t('auth.checkEmailTitle')}>
        <div className="flex flex-col items-center gap-4 text-center">
          <MailCheck className="h-12 w-12 text-brand-600" />
          <p className="text-ink-soft dark:text-gray-300">{t('auth.checkEmailBody', { email: sentTo })}</p>
          <Link to="/login" className="font-semibold text-brand-700 hover:underline">{t('auth.backToLogin')}</Link>
        </div>
      </AuthShell>
    );
  }
  const termsLink = <Link to="/terms" target="_blank" className="font-semibold text-brand-700 underline">{t('auth.terms')}</Link>;
  const privacyLink = <Link to="/privacy" target="_blank" className="font-semibold text-brand-700 underline">{t('auth.privacy')}</Link>;
  const [before, rest] = t('auth.acceptTerms').split('{terms}');
  const [middle, after] = (rest ?? '').split('{privacy}');
  return (
    <AuthShell title={t('auth.signupTitle')} subtitle={t('auth.signupSubtitle')}
      footer={<>{t('auth.haveAccount')} <Link to="/login" className="font-semibold text-brand-700 hover:underline dark:text-brand-400">{t('auth.login')}</Link></>}>
      <form onSubmit={submit} className="space-y-4">
        <Field label={t('auth.fullName')} htmlFor="fn" required><Input id="fn" required autoComplete="name" value={f.full_name} onChange={set('full_name')} /></Field>
        <div className="grid gap-4 sm:grid-cols-2">
          <Field label={t('auth.email')} htmlFor="em" required><Input id="em" type="email" required autoComplete="email" value={f.email} onChange={set('email')} /></Field>
          <Field label={t('auth.phone')} htmlFor="ph"><Input id="ph" type="tel" autoComplete="tel" placeholder="+237 6XX XX XX XX" value={f.phone} onChange={set('phone')} /></Field>
        </div>
        <Field label={t('auth.password')} htmlFor="pw" hint={t('auth.passwordHint')} required><Input id="pw" type="password" required minLength={8} autoComplete="new-password" value={f.password} onChange={set('password')} /></Field>
        <Field label={t('auth.confirmPassword')} htmlFor="pw2" required><Input id="pw2" type="password" required autoComplete="new-password" value={f.confirm} onChange={set('confirm')} /></Field>
        <Checkbox checked={accept} onChange={setAccept} label={<>{before}{termsLink}{middle}{privacyLink}{after}</>} />
        {error && <Alert tone="red">{error}</Alert>}
        <Button type="submit" block size="lg" loading={loading}>{t('auth.signup')}</Button>
      </form>
    </AuthShell>
  );
}

export function ForgotPasswordPage() {
  const { t, has } = useI18n();
  const [email, setEmail] = useState('');
  const [sent, setSent] = useState(false);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const submit = async (e: FormEvent) => {
    e.preventDefault();
    setLoading(true); setError(null);
    const { error: err } = await supabase.auth.resetPasswordForEmail(email.trim(), { redirectTo: `${window.location.origin}/reset-password` });
    setLoading(false);
    if (err && !/rate/i.test(err.message)) setError(errorMessage(err, t, has)); else setSent(true);
  };
  return (
    <AuthShell title={t('auth.forgotTitle')} subtitle={t('auth.forgotSubtitle')}
      footer={<Link to="/login" className="font-semibold text-brand-700 hover:underline">{t('auth.backToLogin')}</Link>}>
      {sent ? <Alert tone="green">{t('auth.linkSent', { email })}</Alert> : (
        <form onSubmit={submit} className="space-y-4">
          <Field label={t('auth.email')} htmlFor="em"><Input id="em" type="email" required value={email} onChange={(e) => setEmail(e.target.value)} /></Field>
          {error && <Alert tone="red">{error}</Alert>}
          <Button type="submit" block size="lg" loading={loading}>{t('auth.sendLink')}</Button>
        </form>
      )}
    </AuthShell>
  );
}

export function ResetPasswordPage() {
  const { t, has } = useI18n();
  const { session, ready } = useAuth();
  const nav = useNavigate();
  const [pw, setPw] = useState('');
  const [pw2, setPw2] = useState('');
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [waited, setWaited] = useState(false);
  useEffect(() => { const id = setTimeout(() => setWaited(true), 2500); return () => clearTimeout(id); }, []);
  const submit = async (e: FormEvent) => {
    e.preventDefault();
    setError(null);
    if (pw.length < 8) return setError(t('auth.passwordTooShort'));
    if (pw !== pw2) return setError(t('auth.passwordMismatch'));
    setLoading(true);
    const { error: err } = await supabase.auth.updateUser({ password: pw });
    setLoading(false);
    if (err) setError(errorMessage(err, t, has)); else nav('/app', { replace: true, state: { toast: t('auth.passwordUpdated') } });
  };
  return (
    <AuthShell title={t('auth.resetTitle')} footer={<Link to="/login" className="font-semibold text-brand-700 hover:underline">{t('auth.backToLogin')}</Link>}>
      {!session && ready && waited ? <Alert tone="red">{t('auth.resetInvalid')}</Alert> : (
        <form onSubmit={submit} className="space-y-4">
          <Field label={t('auth.newPassword')} hint={t('auth.passwordHint')}><Input type="password" required minLength={8} autoComplete="new-password" value={pw} onChange={(e) => setPw(e.target.value)} /></Field>
          <Field label={t('auth.confirmPassword')}><Input type="password" required autoComplete="new-password" value={pw2} onChange={(e) => setPw2(e.target.value)} /></Field>
          {error && <Alert tone="red">{error}</Alert>}
          <Button type="submit" block size="lg" loading={loading} disabled={!session}>{t('auth.updatePassword')}</Button>
        </form>
      )}
    </AuthShell>
  );
}
