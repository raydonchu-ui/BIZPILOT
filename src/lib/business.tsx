import { createContext, ReactNode, useContext, useMemo, useState } from 'react';
import { BusinessCtx, useAuth } from './auth';

const KEY = 'bizpilot.business';

interface BizState {
  biz: BusinessCtx;
  id: string;
  can: (perm: string) => boolean;
  has: (feature: string) => boolean;
  limit: (key: string) => number | null;
  select: (id: string) => void;
}

const Ctx = createContext<BizState | null>(null);

export function storedBusinessId(): string | null {
  try { return localStorage.getItem(KEY); } catch { return null; }
}

export function BusinessProvider({ children, fallback }: { children: ReactNode; fallback: ReactNode }) {
  const { context } = useAuth();
  const [selected, setSelected] = useState<string | null>(storedBusinessId);
  const list = context?.businesses ?? [];
  const biz = list.find((b) => b.id === selected) ?? list[0];

  const value = useMemo<BizState | null>(() => {
    if (!biz) return null;
    return {
      biz,
      id: biz.id,
      can: (p) => biz.permissions.includes(p),
      has: (f) => biz.plan.features.includes(f),
      limit: (k) => (biz.plan.limits[k] ?? null) as number | null,
      select: (id) => {
        try { localStorage.setItem(KEY, id); } catch { /* ignore */ }
        setSelected(id);
      },
    };
  }, [biz]);

  if (!value) return <>{fallback}</>;
  return <Ctx.Provider value={value}>{children}</Ctx.Provider>;
}

export function useBiz() {
  const c = useContext(Ctx);
  if (!c) throw new Error('useBiz outside BusinessProvider');
  return c;
}
