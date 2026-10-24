// Google Identity Services (GIS): Google's own sign-in button, rendered on our page.
// Google shows our site (not the Supabase project domain) in its sign-in window, and the
// ID token it returns is exchanged for a Supabase session with signInWithIdToken.
// Optional: without a valid VITE_GOOGLE_CLIENT_ID the app keeps using the redirect flow.

export type GoogleConfig =
  | { status: 'ok'; clientId: string }
  | { status: 'missing' }
  | { status: 'invalid'; reason: 'looks_like_secret' | 'bad_format' };

// Web OAuth client IDs look like 1234567890-abc123.apps.googleusercontent.com.
const CLIENT_ID_RE = /^[0-9]+-[a-z0-9]+\.apps\.googleusercontent\.com$/;

export function parseGoogleClientId(value: string | undefined): GoogleConfig {
  const v = (value ?? '').trim().replace(/^["']|["']$/g, '');
  if (!v) return { status: 'missing' };
  if (/^GOCSPX-/i.test(v)) return { status: 'invalid', reason: 'looks_like_secret' };
  if (!CLIENT_ID_RE.test(v)) return { status: 'invalid', reason: 'bad_format' };
  return { status: 'ok', clientId: v };
}

// Public OAuth *client ID* (not the secret), read at build time. Must equal the Client ID
// configured for the Google provider in Supabase, otherwise Supabase rejects the token audience.
export const googleConfig = parseGoogleClientId(import.meta.env.VITE_GOOGLE_CLIENT_ID as string | undefined);

// For diagnostics screens: enough to recognise the ID, without printing it in full.
export function maskClientId(id: string): string {
  const [num, rest] = id.split('-');
  return `${num.slice(0, 4)}…${num.slice(-4)}-${rest.slice(0, 4)}….apps.googleusercontent.com`;
}

// Which Google sign-in the page is using and why; shown on /auth/diagnostics and logged once.
export type GoogleMode = 'gis' | 'redirect';
export const googleStatus: { mode: GoogleMode | null; reason: string } = { mode: null, reason: '' };
export function recordGoogleMode(mode: GoogleMode, reason: string) {
  if (googleStatus.mode === mode && googleStatus.reason === reason) return;
  googleStatus.mode = mode; googleStatus.reason = reason;
  const msg = mode === 'gis'
    ? '[BizPilot] Google sign-in: Google Identity Services (signInWithIdToken)'
    : `[BizPilot] Google sign-in: Supabase redirect flow (${reason})`;
  if (mode === 'gis' || reason === 'client_id_missing') console.info(msg); else console.warn(msg);
}

export interface GoogleCredentialResponse { credential: string; select_by?: string }

interface GoogleAccountsId {
  initialize(config: {
    client_id: string; callback: (r: GoogleCredentialResponse) => void; nonce?: string;
    ux_mode?: 'popup' | 'redirect'; auto_select?: boolean; itp_support?: boolean; use_fedcm_for_button?: boolean;
    cancel_on_tap_outside?: boolean; context?: 'signin' | 'signup' | 'use';
  }): void;
  renderButton(parent: HTMLElement, options: {
    type?: 'standard' | 'icon'; theme?: 'outline' | 'filled_blue' | 'filled_black'; size?: 'large' | 'medium' | 'small';
    text?: 'signin_with' | 'signup_with' | 'continue_with' | 'signin'; shape?: 'rectangular' | 'pill'; logo_alignment?: 'left' | 'center';
    width?: number; locale?: string;
  }): void;
  cancel(): void;
}

declare global {
  interface Window { google?: { accounts?: { id?: GoogleAccountsId } } }
}

export const GIS_SRC = 'https://accounts.google.com/gsi/client';
export type GisLoadError = 'gis_blocked' | 'gis_timeout' | 'gis_unavailable';
let loading: Promise<GoogleAccountsId> | null = null;

function loadOnce(timeoutMs: number): Promise<GoogleAccountsId> {
  return new Promise<GoogleAccountsId>((resolve, reject) => {
    if (window.google?.accounts?.id) return resolve(window.google.accounts.id);
    document.querySelectorAll(`script[src="${GIS_SRC}"]`).forEach((s) => s.remove()); // drop a failed earlier tag
    const script = Object.assign(document.createElement('script'), { src: GIS_SRC, async: true });
    const timer = window.setTimeout(() => reject(new Error('gis_timeout')), timeoutMs);
    script.addEventListener('load', () => {
      window.clearTimeout(timer);
      const id = window.google?.accounts?.id;
      if (id) resolve(id); else reject(new Error('gis_unavailable'));
    }, { once: true });
    script.addEventListener('error', () => { window.clearTimeout(timer); reject(new Error('gis_blocked')); }, { once: true });
    document.head.appendChild(script);
  });
}

// Loads the GIS script once per page (shared by every button), with one retry for slow or
// flaky mobile connections. Rejects with a GisLoadError code; callers decide what to show.
export function loadGoogleIdentity({ timeoutMs = 15000, retries = 1 } = {}): Promise<GoogleAccountsId> {
  if (window.google?.accounts?.id) return Promise.resolve(window.google.accounts.id);
  if (loading) return loading;
  loading = (async () => {
    let last: unknown;
    for (let i = 0; i <= retries; i++) {
      try { return await loadOnce(timeoutMs); } catch (e) { last = e; }
    }
    throw last;
  })().catch((e) => { loading = null; throw e; });
  return loading;
}

// Replay protection: Google embeds the SHA-256 of the nonce in the ID token; Supabase receives
// the raw nonce, hashes it and checks it matches. A new nonce is used for every attempt.
export async function createNonce(): Promise<{ raw: string; hashed: string }> {
  const bytes = crypto.getRandomValues(new Uint8Array(32));
  const raw = btoa(String.fromCharCode(...bytes)).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(raw));
  const hashed = Array.from(new Uint8Array(digest), (b) => b.toString(16).padStart(2, '0')).join('');
  return { raw, hashed };
}
