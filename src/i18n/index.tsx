import { createContext, ReactNode, useCallback, useContext, useEffect, useMemo, useState } from 'react';
import type { Lang } from '../lib/format';
import * as common from './common';
import * as site from './site';
import * as auth from './auth';
import * as appText from './app';
import * as admin from './admin';

type Dict = { [k: string]: string | string[] | Dict | Dict[] };

const merge = (lang: Lang): Dict => ({
  ...(common[lang] as Dict),
  ...(site[lang] as Dict),
  ...(auth[lang] as Dict),
  ...(appText[lang] as Dict),
  ...(admin[lang] as Dict),
});

const dictionaries: Record<Lang, Dict> = { en: merge('en'), fr: merge('fr') };

function lookup(dict: Dict, key: string): unknown {
  return key.split('.').reduce<unknown>((o, k) => (o && typeof o === 'object' ? (o as Dict)[k] : undefined), dict);
}

export type TParams = Record<string, string | number | null | undefined>;

function interpolate(s: string, params?: TParams) {
  if (!params) return s;
  return s.replace(/\{(\w+)\}/g, (_, k) => (params[k] === undefined || params[k] === null ? '' : String(params[k])));
}

interface I18nCtx {
  lang: Lang;
  setLang: (l: Lang) => void;
  t: (key: string, params?: TParams) => string;
  /** Returns structured values (arrays/objects) from the dictionary. */
  tv: <T = unknown>(key: string) => T;
  has: (key: string) => boolean;
}

const Ctx = createContext<I18nCtx | null>(null);
const STORAGE_KEY = 'bizpilot.lang';

function initialLang(): Lang {
  try {
    const s = localStorage.getItem(STORAGE_KEY);
    if (s === 'en' || s === 'fr') return s;
  } catch { /* storage unavailable */ }
  return typeof navigator !== 'undefined' && navigator.language?.toLowerCase().startsWith('fr') ? 'fr' : 'en';
}

export function I18nProvider({ children }: { children: ReactNode }) {
  const [lang, setLangState] = useState<Lang>(initialLang);
  const setLang = useCallback((l: Lang) => {
    setLangState(l);
    try { localStorage.setItem(STORAGE_KEY, l); } catch { /* ignore */ }
  }, []);
  useEffect(() => { document.documentElement.lang = lang; }, [lang]);

  const value = useMemo<I18nCtx>(() => {
    const dict = dictionaries[lang];
    return {
      lang,
      setLang,
      t: (key, params) => {
        const v = lookup(dict, key) ?? lookup(dictionaries.en, key);
        if (typeof v !== 'string') {
          if (import.meta.env.DEV) console.warn('[i18n] missing key', key);
          return key;
        }
        return interpolate(v, params);
      },
      tv: <T,>(key: string) => (lookup(dict, key) ?? lookup(dictionaries.en, key)) as T,
      has: (key) => lookup(dict, key) !== undefined,
    };
  }, [lang, setLang]);

  return <Ctx.Provider value={value}>{children}</Ctx.Provider>;
}

export function useI18n() {
  const c = useContext(Ctx);
  if (!c) throw new Error('useI18n outside provider');
  return c;
}

export function useT() {
  return useI18n().t;
}
