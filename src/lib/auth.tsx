import { createContext, ReactNode, useContext, useEffect, useMemo, useState } from 'react';
import type { Session } from '@supabase/supabase-js';
import { useQuery } from '@tanstack/react-query';
import { supabase, supabaseConfigured } from './supabase';
import { queryClient, rpc } from './api';
import { clearCachedCatalogs } from './offline';

export interface BusinessCtx {
  id: string; name: string; role: 'owner' | 'manager' | 'cashier'; status: string; currency: string;
  currency_decimals: number; language: 'en' | 'fr'; timezone: string; category: string; logo_path: string | null;
  country_code: string; permissions: string[];
  subscription: { plan_code: string; effective_plan: string; state: string; current_period_end?: string; trial_ends_at?: string;
    grace_ends_at?: string; payment_pending: boolean; billing_period?: string; cancel_at_period_end?: boolean };
  plan: { code: string; name_en: string; name_fr: string; features: string[]; limits: Record<string, number | null> };
}

export interface MyContext {
  user_id: string; email: string; email_confirmed: boolean; is_platform_admin: boolean; pending_invites: number;
  profile: { full_name: string | null; phone: string | null; language: 'en' | 'fr'; theme: string } | null;
  businesses: BusinessCtx[];
}

interface AuthState {
  session: Session | null;
  ready: boolean;
  context: MyContext | null | undefined;
  contextLoading: boolean;
  refreshContext: () => Promise<unknown>;
  signOut: () => Promise<void>;
}

const Ctx = createContext<AuthState | null>(null);

export function AuthProvider({ children }: { children: ReactNode }) {
  const [session, setSession] = useState<Session | null>(null);
  const [ready, setReady] = useState(!supabaseConfigured);

  useEffect(() => {
    if (!supabaseConfigured) return;
    supabase.auth.getSession().then(({ data }) => { setSession(data.session); setReady(true); });
    const { data: sub } = supabase.auth.onAuthStateChange((_evt, s) => {
      setSession(s);
      if (!s) queryClient.clear();
    });
    return () => sub.subscription.unsubscribe();
  }, []);

  const userId = session?.user.id;
  const ctxQuery = useQuery({
    queryKey: ['my_context', userId],
    enabled: Boolean(userId),
    staleTime: 60_000,
    queryFn: async () => {
      // Claim any staff invitations addressed to this (verified) email first.
      try { await rpc('accept_invites'); } catch { /* not fatal */ }
      return rpc<MyContext>('get_my_context');
    },
  });

  const value = useMemo<AuthState>(() => ({
    session,
    ready,
    context: userId ? ctxQuery.data : null,
    contextLoading: Boolean(userId) && ctxQuery.isLoading,
    refreshContext: () => ctxQuery.refetch(),
    signOut: async () => {
      await supabase.auth.signOut();
      clearCachedCatalogs();
      queryClient.clear();
    },
  }), [session, ready, userId, ctxQuery.data, ctxQuery.isLoading, ctxQuery]);

  return <Ctx.Provider value={value}>{children}</Ctx.Provider>;
}

export function useAuth() {
  const c = useContext(Ctx);
  if (!c) throw new Error('useAuth outside provider');
  return c;
}
