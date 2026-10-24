import { QueryClient, useQuery, UseQueryOptions } from '@tanstack/react-query';
import { supabase } from './supabase';

export const queryClient = new QueryClient({
  defaultOptions: {
    queries: { staleTime: 30_000, retry: (n, err: any) => n < 2 && !String(err?.message ?? '').match(/permission|feature|not_found|store_locked/), refetchOnWindowFocus: false },
  },
});

export class ApiError extends Error {
  details?: string | null;
  code?: string;
  constructor(e: { message: string; details?: string | null; code?: string }) {
    super(e.message);
    this.details = e.details;
    this.code = e.code;
    // The server locked this session (Store Lock): let the app show the PIN screen.
    if (e.message === 'store_locked' && typeof window !== 'undefined') window.dispatchEvent(new Event('bizpilot:store-locked'));
  }
}

export async function rpc<T = any>(fn: string, args: Record<string, unknown> = {}): Promise<T> {
  const { data, error } = await supabase.rpc(fn, args);
  if (error) throw new ApiError(error);
  return data as T;
}

/** Throws ApiError for Supabase query builder results. */
export function unwrap<T>(res: { data: T | null; error: any }): T {
  if (res.error) throw new ApiError(res.error);
  return res.data as T;
}

export function useRpc<T = any>(fn: string, args: Record<string, unknown>,
  opts: Omit<UseQueryOptions<T>, 'queryKey' | 'queryFn'> = {}) {
  return useQuery<T>({ queryKey: [fn, args], queryFn: () => rpc<T>(fn, args), ...opts });
}

export function invalidateBusinessData() {
  return queryClient.invalidateQueries();
}
