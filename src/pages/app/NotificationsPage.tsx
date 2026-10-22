import { Link } from 'react-router-dom';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import clsx from 'clsx';
import { useI18n } from '../../i18n';
import { useBiz } from '../../lib/business';
import { useAuth } from '../../lib/auth';
import { supabase } from '../../lib/supabase';
import { rpc, unwrap } from '../../lib/api';
import { formatDateTime } from '../../lib/format';
import { Badge, Button, Card, EmptyState, PageHeader, PageLoader } from '../../components/ui';
import { notificationText } from './notificationsText';

export default function NotificationsPage() {
  const { t, lang } = useI18n();
  const { id } = useBiz();
  const { session } = useAuth();
  const qc = useQueryClient();
  const { data, isLoading } = useQuery({
    queryKey: ['notifications-all', id],
    queryFn: async () => {
      const list = unwrap(await supabase.from('notifications').select('*').eq('business_id', id).order('created_at', { ascending: false }).limit(200)) as any[];
      const reads = unwrap(await supabase.from('notification_reads').select('notification_id').eq('user_id', session!.user.id)) as any[];
      const s = new Set(reads.map((r) => r.notification_id));
      return list.map((n) => ({ ...n, read: s.has(n.id) }));
    },
  });
  const markAll = async () => { await rpc('mark_notifications_read', { p_business: id, p_ids: null }); qc.invalidateQueries(); };
  const refresh = async () => { await rpc('generate_alerts', { p_business: id }); qc.invalidateQueries(); };
  return (
    <div className="mx-auto max-w-3xl">
      <PageHeader title={t('nav.notifications')} subtitle={t('notifications.subtitle')} actions={<><Button variant="outline" onClick={refresh}>{t('notifications.check')}</Button><Button variant="outline" onClick={markAll}>{t('notifications.markAllRead')}</Button></>} />
      <Card padded={false}>
        {isLoading ? <PageLoader /> : (data ?? []).length === 0 ? <EmptyState title={t('notifications.empty')} body={t('notifications.emptyBody')} /> : (
          <ul className="divide-y divide-gray-100 dark:divide-gray-800">
            {data!.map((n) => {
              const txt = notificationText(n, t, lang);
              return (
                <li key={n.id}>
                  <Link to={n.link ?? '#'} className={clsx('flex gap-3 px-5 py-4 hover:bg-gray-50 dark:hover:bg-gray-800/50', !n.read && 'bg-brand-50/40 dark:bg-brand-950/20')}>
                    <span className={clsx('mt-1.5 h-2.5 w-2.5 shrink-0 rounded-full', n.severity === 'critical' ? 'bg-red-600' : n.severity === 'warning' ? 'bg-amber-500' : n.severity === 'success' ? 'bg-brand-600' : 'bg-blue-500')} />
                    <div className="flex-1"><p className="font-semibold">{txt.title}</p><p className="text-sm text-ink-muted">{txt.body}</p><p className="mt-1 text-xs text-gray-400">{formatDateTime(n.created_at, lang)}</p></div>
                    {!n.read && <Badge tone="green">{t('notifications.new')}</Badge>}
                  </Link>
                </li>
              );
            })}
          </ul>
        )}
      </Card>
      <p className="mt-3 text-xs text-ink-muted">{t('notifications.deliveryNote')}</p>
    </div>
  );
}
