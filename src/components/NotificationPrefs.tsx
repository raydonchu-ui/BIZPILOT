// Which personal notices this account receives. Turning a kind off stops it being stored at all (the database checks).
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { useI18n } from '../i18n';
import { rpc } from '../lib/api';
import { useAction } from '../lib/useAction';
import { Card, CardHeader, Checkbox } from './ui';

const CATEGORIES = ['messages', 'orders', 'creator', 'support', 'billing'] as const;

export function NotificationPrefs() {
  const { t } = useI18n();
  const { run, busy } = useAction();
  const qc = useQueryClient();
  const q = useQuery({ queryKey: ['notification-prefs'], queryFn: () => rpc<Record<string, boolean>>('my_notification_preferences') });
  const set = async (category: string, enabled: boolean) => {
    const r = await run(() => rpc('set_notification_preference', { p_category: category, p_enabled: enabled }), t('common.saved'));
    if (r !== undefined) qc.invalidateQueries({ queryKey: ['notification-prefs'] });
  };
  return (
    <Card>
      <CardHeader title={t('notifPrefs.title')} subtitle={t('notifPrefs.subtitle')} />
      <div className="grid gap-3 sm:grid-cols-2">
        {CATEGORIES.map((c) => (
          <Checkbox key={c} label={t(`notifPrefs.${c}`)} hint={t(`notifPrefs.${c}Hint`)} checked={q.data?.[c] ?? true} disabled={busy || q.isLoading}
            onChange={(v) => set(c, v)} />
        ))}
      </div>
      <p className="mt-4 text-xs text-ink-muted">{t('notifPrefs.lockScreen')}</p>
    </Card>
  );
}
