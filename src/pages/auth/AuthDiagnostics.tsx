import { useEffect, useState } from 'react';
import { useQuery } from '@tanstack/react-query';
import { Card } from '../../components/ui';
import { fetchAuthProviders, supabaseConfigured } from '../../lib/supabase';
import { GIS_SRC, googleConfig, loadGoogleIdentity, maskClientId } from '../../lib/googleIdentity';

// Technical page for checking a deployment's Google sign-in setup. Shows public facts only:
// no keys, tokens or secrets. Not linked from the app; open /auth/diagnostics directly.
export function AuthDiagnosticsPage() {
  const providers = useQuery({ queryKey: ['auth-providers'], queryFn: fetchAuthProviders, staleTime: 0 });
  const [gis, setGis] = useState<{ state: 'loading' | 'loaded' | 'failed'; detail?: string }>({ state: 'loading' });
  const [copied, setCopied] = useState(false);
  useEffect(() => {
    if (googleConfig.status !== 'ok') { setGis({ state: 'failed', detail: 'not attempted (no valid client ID)' }); return; }
    const t0 = performance.now();
    loadGoogleIdentity().then(
      () => setGis({ state: 'loaded', detail: `${Math.round(performance.now() - t0)} ms` }),
      (e) => setGis({ state: 'failed', detail: e instanceof Error ? e.message : String(e) }),
    );
  }, []);

  const b = __BUILD_INFO__;
  const supabaseHost = (() => { try { return new URL(import.meta.env.VITE_SUPABASE_URL as string).host; } catch { return 'not set'; } })();
  const google = providers.data?.google;
  const decision = !supabaseConfigured ? 'No Google button (Supabase not configured in this build)'
    : providers.isLoading ? '…'
    : !google ? 'No Google button (Google provider is off in Supabase)'
    : googleConfig.status === 'missing' ? 'Supabase redirect sign-in — VITE_GOOGLE_CLIENT_ID was not set when this deployment was built'
    : googleConfig.status === 'invalid' ? `Supabase redirect sign-in — VITE_GOOGLE_CLIENT_ID is not a valid web client ID (${googleConfig.reason})`
    : gis.state === 'failed' ? `Google Identity Services wanted, but Google's script failed (${gis.detail}); the page asks the user what to do`
    : gis.state === 'loaded' ? 'Google Identity Services (Google’s own button + signInWithIdToken)'
    : 'Google Identity Services (loading Google’s script…)';

  const rows: [string, string][] = [
    ['Google sign-in used on this deployment', decision],
    ['Page origin (must be an Authorized JavaScript origin in Google Cloud)', window.location.origin],
    ['Google Client ID in this build', googleConfig.status === 'ok' ? `configured: ${maskClientId(googleConfig.clientId)}` : googleConfig.status === 'missing' ? 'MISSING' : `INVALID (${googleConfig.reason})`],
    ['Google provider enabled in Supabase', providers.isLoading ? '…' : google ? 'yes' : 'no'],
    ['Google script', `${gis.state}${gis.detail ? ` (${gis.detail})` : ''} — ${GIS_SRC}`],
    ['Browser supports FedCM', 'IdentityCredential' in window ? 'yes' : 'no'],
    ['Served by an app cache (service worker)', navigator.serviceWorker?.controller ? 'yes — may be an older copy' : 'no'],
    ['Supabase project', supabaseHost],
    ['Vercel environment', b.env],
    ['Branch / commit', `${b.branch || '—'} / ${b.commit || '—'}`],
    ['Built at', b.builtAt],
    ['Vercel project production domain', b.projectDomain || '—'],
    ['Deployment URL', b.deploymentUrl || '—'],
  ];
  const report = rows.map(([k, v]) => `${k}: ${v}`).join('\n');

  return (
    <div className="mx-auto max-w-3xl px-4 py-10">
      <h1 className="text-2xl font-extrabold">Sign-in diagnostics</h1>
      <p className="mt-1 text-sm text-ink-muted">Public build and configuration facts for this deployment. Contains no keys or secrets.</p>
      <Card className="mt-6">
        <dl className="divide-y divide-gray-100 text-sm dark:divide-gray-800" data-testid="diagnostics">
          {rows.map(([k, v]) => (
            <div key={k} className="grid gap-1 py-2.5 sm:grid-cols-[minmax(0,2fr)_minmax(0,3fr)] sm:gap-4">
              <dt className="text-ink-muted">{k}</dt><dd className="break-words font-medium">{v}</dd>
            </div>
          ))}
        </dl>
      </Card>
      <button type="button" className="mt-4 rounded-lg border border-gray-300 px-4 py-2 text-sm font-semibold"
        onClick={async () => { try { await navigator.clipboard.writeText(report); setCopied(true); } catch { setCopied(false); } }}>
        {copied ? 'Copied' : 'Copy report'}
      </button>
    </div>
  );
}
