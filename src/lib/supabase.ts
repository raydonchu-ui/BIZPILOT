import { createClient } from '@supabase/supabase-js';

const url = import.meta.env.VITE_SUPABASE_URL as string | undefined;
const key = import.meta.env.VITE_SUPABASE_ANON_KEY as string | undefined;

export const supabaseConfigured = Boolean(url && key);

// The anon key is public by design; every query is filtered by Row Level Security
// and every write goes through server-side validated RPCs.
export const supabase = createClient(url ?? 'http://localhost:54321', key ?? 'missing-key', {
  auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: true },
});

export const FILES_BUCKET = 'business-files';

// Which sign-in providers are switched on in Supabase (Authentication → Sign In / Providers).
// Public endpoint; lets the app show "Continue with Google" only once Google is enabled.
export async function fetchAuthProviders(): Promise<Record<string, boolean>> {
  if (!supabaseConfigured) return {};
  const res = await fetch(`${url}/auth/v1/settings`, { headers: { apikey: key! } });
  if (!res.ok) return {};
  return ((await res.json()) as { external?: Record<string, boolean> }).external ?? {};
}
