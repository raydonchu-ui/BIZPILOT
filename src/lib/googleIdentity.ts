// Google Identity Services (GIS): Google's own sign-in button, rendered on our page.
// Google shows our site (not the Supabase project domain) in its sign-in window, and the
// ID token it returns is exchanged for a Supabase session with signInWithIdToken.
// Optional: without VITE_GOOGLE_CLIENT_ID the app keeps using the redirect flow.

// Public OAuth *client ID* (not the secret). Must equal the Client ID configured for the
// Google provider in Supabase, otherwise Supabase rejects the token's audience.
export const googleClientId = (import.meta.env.VITE_GOOGLE_CLIENT_ID as string | undefined)?.trim() || undefined;

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

const GIS_SRC = 'https://accounts.google.com/gsi/client';
let loading: Promise<GoogleAccountsId> | null = null;

// Loads the GIS script once. Rejects (so callers fall back to the redirect flow) if it is
// blocked by an ad blocker, offline, or slow.
export function loadGoogleIdentity(timeoutMs = 8000): Promise<GoogleAccountsId> {
  if (window.google?.accounts?.id) return Promise.resolve(window.google.accounts.id);
  if (loading) return loading;
  loading = new Promise<GoogleAccountsId>((resolve, reject) => {
    const timer = window.setTimeout(() => reject(new Error('gis_timeout')), timeoutMs);
    const done = () => {
      window.clearTimeout(timer);
      const id = window.google?.accounts?.id;
      if (id) resolve(id); else reject(new Error('gis_unavailable'));
    };
    const existing = document.querySelector<HTMLScriptElement>(`script[src="${GIS_SRC}"]`);
    const script = existing ?? Object.assign(document.createElement('script'), { src: GIS_SRC, async: true, defer: true });
    script.addEventListener('load', done, { once: true });
    script.addEventListener('error', () => { window.clearTimeout(timer); reject(new Error('gis_blocked')); }, { once: true });
    if (!existing) document.head.appendChild(script);
  }).catch((e) => { loading = null; throw e; });
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
