import { useQuery } from '@tanstack/react-query';
import { useSearchParams } from 'react-router-dom';
import { useI18n } from '../../i18n';
import { useBiz } from '../../lib/business';
import { useAuth } from '../../lib/auth';
import { supabase } from '../../lib/supabase';
import { unwrap } from '../../lib/api';
import { formatDateTime } from '../../lib/format';
import { Badge, Card, CardHeader, PageHeader } from '../../components/ui';
import { SupportForm } from '../public/Contact';

export default function HelpPage() {
  const { t, tv, lang } = useI18n();
  const { id } = useBiz();
  const { session } = useAuth();
  const [params] = useSearchParams();
  const guides = tv<{ q: string; a: string }[]>('help.guides');
  const mine = useQuery({
    queryKey: ['my-support', session?.user.id],
    queryFn: async () => unwrap(await supabase.from('support_requests').select('*').eq('user_id', session!.user.id).order('created_at', { ascending: false }).limit(20)) as any[],
  });
  return (
    <div>
      <PageHeader title={t('nav.help')} subtitle={t('help.subtitle')} />
      <div className="grid gap-4 lg:grid-cols-5">
        <Card className="lg:col-span-3">
          <CardHeader title={t('help.guidesTitle')} />
          <div className="divide-y divide-gray-100 dark:divide-gray-800">
            {guides.map((g) => (
              <details key={g.q} className="group py-3" open={params.get('topic') === g.q}>
                <summary className="flex cursor-pointer list-none items-center justify-between gap-3 font-semibold">{g.q}<span className="text-brand-700 transition group-open:rotate-45">+</span></summary>
                <p className="mt-2 whitespace-pre-line text-sm text-ink-soft dark:text-gray-300">{g.a}</p>
              </details>
            ))}
          </div>
        </Card>
        <div className="space-y-4 lg:col-span-2">
          <Card>
            <CardHeader title={params.get('feedback') ? t('nav.feedback') : t('help.contactTitle')} subtitle={t('help.contactSub')} />
            <SupportFormWithDefault businessId={id} />
          </Card>
          <Card>
            <CardHeader title={t('help.myRequests')} />
            {(mine.data ?? []).length === 0 ? <p className="text-sm text-ink-muted">{t('common.noData')}</p> : (
              <ul className="space-y-3 text-sm">{mine.data!.map((r) => (
                <li key={r.id}><p className="font-semibold">{r.subject} <Badge tone={r.status === 'resolved' || r.status === 'closed' ? 'green' : 'amber'}>{t(`help.status.${r.status}`)}</Badge></p>
                  <p className="text-xs text-ink-muted">{formatDateTime(r.created_at, lang)}</p>
                  {r.admin_response && <p className="mt-1 rounded-lg bg-brand-50 p-2 text-brand-900 dark:bg-brand-950/40 dark:text-brand-100">{r.admin_response}</p>}</li>))}</ul>
            )}
          </Card>
        </div>
      </div>
    </div>
  );
}

function SupportFormWithDefault({ businessId }: { businessId: string }) {
  return <SupportForm businessId={businessId} compact />;
}
