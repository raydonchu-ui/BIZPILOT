import clsx from 'clsx';
import { Globe } from 'lucide-react';
import { useI18n } from '../i18n';
import { supabase } from '../lib/supabase';

export function LanguageSwitch({ className, persist }: { className?: string; persist?: boolean }) {
  const { lang, setLang } = useI18n();
  const choose = async (l: 'en' | 'fr') => {
    setLang(l);
    if (persist) {
      const { data } = await supabase.auth.getUser();
      if (data.user) await supabase.from('profiles').update({ language: l }).eq('id', data.user.id);
    }
  };
  return (
    <div className={clsx('inline-flex items-center gap-1 rounded-lg bg-gray-100 p-0.5 text-xs font-semibold dark:bg-gray-800', className)} role="group" aria-label="Language">
      <Globe className="ml-1.5 h-3.5 w-3.5 text-gray-500" aria-hidden />
      {(['fr', 'en'] as const).map((l) => (
        <button key={l} onClick={() => choose(l)} aria-pressed={lang === l}
          className={clsx('rounded-md px-2 py-1 uppercase', lang === l ? 'bg-white text-brand-800 shadow-sm dark:bg-gray-900 dark:text-brand-300' : 'text-gray-500 hover:text-ink dark:hover:text-white')}>
          {l}
        </button>
      ))}
    </div>
  );
}
