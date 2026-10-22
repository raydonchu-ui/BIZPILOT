import { useI18n } from '../../i18n';
import { formatDate } from '../../lib/format';

const UPDATED = '2026-10-22';

export function LegalPage({ doc }: { doc: 'privacy' | 'terms' | 'billing' }) {
  const { t, tv, lang } = useI18n();
  const sections = tv<{ h: string; p: string[] }[]>(`site.legal.${doc}.sections`);
  return (
    <article className="mx-auto max-w-3xl px-4 py-14 sm:px-6">
      <h1 className="text-4xl font-extrabold tracking-tight">{t(`site.legal.${doc}.title`)}</h1>
      <p className="mt-2 text-sm text-ink-muted">{t('site.legal.updated', { date: formatDate(UPDATED, lang) })}</p>
      <div className="mt-8 space-y-8">
        {sections.map((s, i) => (
          <section key={s.h}>
            <h2 className="text-xl font-bold">{i + 1}. {s.h}</h2>
            <div className="mt-2 space-y-2 text-ink-soft dark:text-gray-300">{s.p.map((p) => <p key={p}>{p}</p>)}</div>
          </section>
        ))}
      </div>
    </article>
  );
}
