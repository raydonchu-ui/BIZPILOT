// The roles this one login holds. Each role comes from the record that grants it; the card only shows them.
import { Link } from 'react-router-dom';
import { useQuery } from '@tanstack/react-query';
import { useI18n } from '../i18n';
import { rpc } from '../lib/api';
import { Badge, Card, CardHeader, PageLoader } from './ui';

export function RolesCard() {
  const { t } = useI18n();
  const q = useQuery({ queryKey: ['my-roles'], queryFn: () => rpc<any>('my_roles') });
  if (q.isLoading) return <PageLoader />;
  const r = q.data;
  if (!r) return null;
  return (
    <Card>
      <CardHeader title={t('roles.title')} subtitle={t('roles.subtitle')} />
      <div className="flex flex-wrap gap-2">
        <Badge tone="gray">{t('roles.buyer')}</Badge>
        {(r.sellers ?? []).map((s: any) => (
          <Link key={s.business_id} to="/app">
            <Badge tone="green">{t('roles.seller', { name: s.name, role: t(`roles.${s.role}`) })}</Badge>
          </Link>
        ))}
        {(r.sellers ?? []).some((s: any) => s.premium) && <Badge tone="blue">{t('roles.premium')}</Badge>}
        {(r.sellers ?? []).some((s: any) => s.blue_tick) && <Badge tone="blue">{t('roles.blueTick')}</Badge>}
        {r.creator && <Link to="/creator"><Badge tone="green">{t('roles.creator')}</Badge></Link>}
        {!r.creator && r.creator_pending && <Link to="/creator"><Badge tone="amber">{t('roles.creatorPending')}</Badge></Link>}
        {r.admin && <Link to="/admin"><Badge tone="red">{t('roles.admin')}</Badge></Link>}
      </div>
      {(r.sellers ?? []).length === 0 && <p className="mt-3 text-sm text-ink-muted">{t('roles.noSeller')}</p>}
    </Card>
  );
}
