import { FormEvent, ReactNode, useEffect, useRef, useState } from 'react';
import { Link, Navigate, useNavigate, useSearchParams } from 'react-router-dom';
import { useQuery } from '@tanstack/react-query';
import { MailCheck } from 'lucide-react';
import { useI18n } from '../../i18n';
import { fetchAuthProviders, supabase, supabaseConfigured } from '../../lib/supabase';
import { errorMessage } from '../../lib/errors';
import { useAuth } from '../../lib/auth';
import { createNonce, googleConfig, loadGoogleIdentity, recordGoogleMode, type GoogleCredentialResponse } from '../../lib/googleIdentity';
import { Alert, Button, Checkbox, Field, Input, PasswordInput, Spinner } from '../../components/ui';
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

function GoogleIcon() {
  return (
    <svg viewBox="0 0 48 48" className="h-5 w-5" aria-hidden="true">
      <path fill="#FFC107" d="M43.6 20.5H42V20H24v8h11.3C33.7 32.7 29.2 36 24 36c-6.6 0-12-5.4-12-12s5.4-12 12-12c3.1 0 5.8 1.2 7.9 3.1l5.7-5.7C34 6.1 29.3 4 24 4 12.9 4 4 12.9 4 24s8.9 20 20 20 20-8.9 20-20c0-1.3-.1-2.4-.4-3.5z" />
      <path fill="#FF3D00" d="M6.3 14.7l6.6 4.8C14.7 15.1 19 12 24 12c3.1 0 5.8 1.2 7.9 3.1l5.7-5.7C34 6.1 29.3 4 24 4 16.3 4 9.7 8.3 6.3 14.7z" />
      <path fill="#4CAF50" d="M24 44c5.2 0 9.9-2 13.4-5.2l-6.2-5.2C29.2 35.1 26.7 36 24 36c-5.2 0-9.6-3.3-11.3-8l-6.5 5C9.5 39.6 16.2 44 24 44z" />
      <path fill="#1976D2" d="M43.6 20.5H42V20H24v8h11.3c-.8 2.2-2.2 4.2-4.1 5.6l6.2 5.2C37 39.2 44 34 44 24c0-1.3-.1-2.4-.4-3.5z" />
    </svg>
  );
}

// Google's own button (Google Identity Services). Google shows our site in its window; the ID
// token is exchanged for a Supabase session. Reports load failures to the parent (never redirects).
function GoogleIdentityButton({ clientId, context, onLoadFailed, onError }:
  { clientId: string; context: 'signin' | 'signup'; onLoadFailed: (reason: string) => void; onError: (msg: string) => void }) {
  const { t, lang, has } = useI18n();
  const box = useRef<HTMLDivElement>(null);
  const nonce = useRef('');
  const inFlight = useRef(false);
  const [busy, setBusy] = useState(false);
  const [attempt, setAttempt] = useState(0);
  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        const [gis, n] = await Promise.all([loadGoogleIdentity(), createNonce()]);
        if (cancelled || !box.current) return;
        nonce.current = n.raw;
        gis.initialize({
          client_id: clientId, nonce: n.hashed, ux_mode: 'popup', auto_select: false, itp_support: true,
          use_fedcm_for_button: true, context,
          callback: async (res: GoogleCredentialResponse) => {
            if (inFlight.current || !res?.credential) return; // ignore double callbacks
            inFlight.current = true; setBusy(true);
            const { error } = await supabase.auth.signInWithIdToken({ provider: 'google', token: res.credential, nonce: nonce.current });
            inFlight.current = false; setBusy(false);
            if (error) {
              onError(has(`errors.auth_${error.code}`) || has(`errors.${error.message}`) ? errorMessage(error, t, has) : t('errors.google_unavailable'));
              setAttempt((a) => a + 1); // fresh nonce for the next try
            }
            // On success the auth listener receives the session and the page redirects to /app.
          },
        });
        box.current.replaceChildren();
        gis.renderButton(box.current, {
          type: 'standard', theme: 'outline', size: 'large', shape: 'rectangular', logo_alignment: 'center',
          text: context === 'signup' ? 'signup_with' : 'continue_with', width: Math.min(400, box.current.clientWidth || 400),
          locale: lang,
        });
        recordGoogleMode('gis', 'ok');
      } catch (e) {
        if (!cancelled) onLoadFailed(e instanceof Error ? e.message : 'gis_unavailable');
      }
    })();
    return () => { cancelled = true; };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [clientId, lang, context, attempt]);
  return (
    <div className="relative flex min-h-[44px] justify-center" aria-busy={busy}>
      <div ref={box} className="w-full max-w-[400px] [&>div]:mx-auto" data-testid="gis-button" />
      {busy && <div className="absolute inset-0 flex items-center justify-center rounded-lg bg-white/80 dark:bg-gray-950/80"><Spinner /></div>}
    </div>
  );
}

// "Continue with Google", shown only when Google is enabled in Supabase.
// - Valid VITE_GOOGLE_CLIENT_ID: Google's own button (signInWithIdToken). If Google's script cannot
//   load, the user is told why and chooses: retry, or the standard (redirect) Google sign-in.
// - Missing/invalid client ID: the redirect flow, with the reason logged and shown on /auth/diagnostics.
function GoogleSignIn({ note, context = 'signin' }: { note?: ReactNode; context?: 'signin' | 'signup' }) {
  const { t, has } = useI18n();
  const providers = useQuery({ queryKey: ['auth-providers'], queryFn: fetchAuthProviders, staleTime: 5 * 60_000 });
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [loadFailed, setLoadFailed] = useState<string | null>(null);
  const [retryKey, setRetryKey] = useState(0);
  const gisReady = googleConfig.status === 'ok';
  useEffect(() => {
    if (!providers.data?.google) return;
    if (googleConfig.status === 'missing') recordGoogleMode('redirect', 'client_id_missing');
    else if (googleConfig.status === 'invalid') recordGoogleMode('redirect', `client_id_invalid:${googleConfig.reason}`);
    else if (loadFailed) recordGoogleMode('redirect', `${loadFailed} (user choice required)`);
  }, [providers.data?.google, loadFailed]);
  if (!providers.data?.google) return null;
  const redirect = async () => {
    setLoading(true); setError(null);
    const { error: err } = await supabase.auth.signInWithOAuth({
      provider: 'google',
      options: { redirectTo: `${window.location.origin}/auth/callback`, queryParams: { prompt: 'select_account' } },
    });
    if (err) { setLoading(false); setError(has(`errors.${err.message}`) ? errorMessage(err, t, has) : t('errors.google_unavailable')); }
  };
  const mode = !gisReady ? 'redirect' : loadFailed ? 'failed' : 'gis';
  return (
    <div className="mb-6 space-y-3" data-google-mode={mode} data-google-reason={googleConfig.status === 'ok' ? loadFailed ?? 'ok' : googleConfig.status}>
      {mode === 'redirect' && <Button variant="outline" block size="lg" loading={loading} icon={<GoogleIcon />} onClick={redirect}>{t('auth.continueWithGoogle')}</Button>}
      {mode === 'gis' && googleConfig.status === 'ok' && (
        <GoogleIdentityButton key={retryKey} clientId={googleConfig.clientId} context={context}
          onLoadFailed={(r) => setLoadFailed(r)} onError={(m) => setError(m)} />
      )}
      {mode === 'failed' && (
        <div className="space-y-2">
          <Alert tone="amber">{t('auth.googleLoadFailed')}</Alert>
          <div className="grid gap-2 sm:grid-cols-2">
            <Button variant="outline" onClick={() => { setLoadFailed(null); setRetryKey((k) => k + 1); }}>{t('common.retry')}</Button>
            <Button variant="outline" loading={loading} icon={<GoogleIcon />} onClick={redirect}>{t('auth.googleStandard')}</Button>
          </div>
        </div>
      )}
      {note && <p className="text-center text-xs text-ink-muted dark:text-gray-400">{note}</p>}
      {error && <Alert tone="red">{error}</Alert>}
      {mode === 'gis' && error && (
        <p className="text-center text-xs"><button type="button" onClick={redirect} className="font-semibold text-brand-700 underline dark:text-brand-400">{t('auth.googleOtherWay')}</button></p>
      )}
      <div className="flex items-center gap-3 text-xs text-ink-muted dark:text-gray-400">
        <span className="h-px flex-1 bg-gray-200 dark:bg-gray-800" />{t('auth.orEmail')}<span className="h-px flex-1 bg-gray-200 dark:bg-gray-800" />
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
      {params.get('verified') && <div className="mb-4"><Alert tone="green">{t('auth.verified')}</Alert></div>}
      <GoogleSignIn />
      <form onSubmit={submit} className="space-y-4">
        <Field label={t('auth.email')} htmlFor="email"><Input id="email" type="email" autoComplete="email" required value={email} onChange={(e) => setEmail(e.target.value)} /></Field>
        <Field label={t('auth.password')} htmlFor="password"><PasswordInput id="password" autoComplete="current-password" required value={password} onChange={(e) => setPassword(e.target.value)} /></Field>
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
  const [gBefore, gRest] = t('auth.googleTerms').split('{terms}');
  const [gMiddle, gAfter] = (gRest ?? '').split('{privacy}');
  return (
    <AuthShell title={t('auth.signupTitle')} subtitle={t('auth.signupSubtitle')}
      footer={<>{t('auth.haveAccount')} <Link to="/login" className="font-semibold text-brand-700 hover:underline dark:text-brand-400">{t('auth.login')}</Link></>}>
      <GoogleSignIn context="signup" note={<>{gBefore}{termsLink}{gMiddle}{privacyLink}{gAfter}</>} />
      <form onSubmit={submit} className="space-y-4">
        <Field label={t('auth.fullName')} htmlFor="fn" required><Input id="fn" required autoComplete="name" value={f.full_name} onChange={set('full_name')} /></Field>
        <div className="grid gap-4 sm:grid-cols-2">
          <Field label={t('auth.email')} htmlFor="em" required><Input id="em" type="email" required autoComplete="email" value={f.email} onChange={set('email')} /></Field>
          <Field label={t('auth.phone')} htmlFor="ph"><Input id="ph" type="tel" autoComplete="tel" placeholder="+237 6XX XX XX XX" value={f.phone} onChange={set('phone')} /></Field>
        </div>
        <Field label={t('auth.password')} htmlFor="pw" hint={t('auth.passwordHint')} required><PasswordInput id="pw" required minLength={8} autoComplete="new-password" value={f.password} onChange={set('password')} /></Field>
        <Field label={t('auth.confirmPassword')} htmlFor="pw2" required><PasswordInput id="pw2" required autoComplete="new-password" value={f.confirm} onChange={set('confirm')} /></Field>
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
          <Field label={t('auth.newPassword')} hint={t('auth.passwordHint')}><PasswordInput required minLength={8} autoComplete="new-password" value={pw} onChange={(e) => setPw(e.target.value)} /></Field>
          <Field label={t('auth.confirmPassword')}><PasswordInput required autoComplete="new-password" value={pw2} onChange={(e) => setPw2(e.target.value)} /></Field>
          {error && <Alert tone="red">{error}</Alert>}
          <Button type="submit" block size="lg" loading={loading} disabled={!session}>{t('auth.updatePassword')}</Button>
        </form>
      )}
    </AuthShell>
  );
}

// Landing page after Google sign-in: Supabase puts the session in the URL and the client picks it up.
export function AuthCallbackPage() {
  const { t } = useI18n();
  const { session, ready } = useAuth();
  const [params] = useSearchParams();
  const [timedOut, setTimedOut] = useState(false);
  const hash = new URLSearchParams(window.location.hash.slice(1));
  const failed = params.get('error') || hash.get('error');
  useEffect(() => { const id = setTimeout(() => setTimedOut(true), 8000); return () => clearTimeout(id); }, []);
  if (session) return <Navigate to="/app" replace />;
  return (
    <AuthShell title={failed || (ready && timedOut) ? t('auth.loginTitle') : t('auth.completingSignIn')}>
      {failed || (ready && timedOut) ? (
        <div className="space-y-4">
          <Alert tone="red">{t('auth.oauthFailed')}</Alert>
          <Link to="/login" className="font-semibold text-brand-700 hover:underline">{t('auth.backToLogin')}</Link>
        </div>
      ) : <div className="flex justify-center py-8"><Spinner /></div>}
    </AuthShell>
  );
}
