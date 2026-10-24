import { Link, useNavigate } from 'react-router-dom';
import { Bell, ChevronRight, CreditCard, HelpCircle, ListChecks, LogOut, Upload, UserCog } from 'lucide-react';
import { useI18n } from '../../i18n';
import { useAuth } from '../../lib/auth';
import { useBiz } from '../../lib/business';
import { Badge, Card } from '../../components/ui';
import { LanguageSwitch } from '../../components/LanguageSwitch';
import { useVisibleNav } from '../../components/layout/AppLayout';

export default function MorePage() {
  const { t } = useI18n();
  const { context, signOut } = useAuth();
  const { biz, can } = useBiz();
  const nav = useNavigate();
  const nav_ = useVisibleNav();
  const items = [
    ...nav_.filter((n) => n.to !== '/app').map((n) => ({ to: n.to, icon: n.icon, label: t(`nav.${n.key}`) })),
    { to: '/app/setup', icon: ListChecks, label: t('nav.setup') },
    ...(can('imports.manage') ? [{ to: '/app/import', icon: Upload, label: t('nav.import') }] : []),
    { to: '/app/notifications', icon: Bell, label: t('nav.notifications') },
    ...(can('billing.manage') ? [{ to: '/app/billing', icon: CreditCard, label: t('nav.billing') }] : []),
    { to: '/app/profile', icon: UserCog, label: t('nav.profile') },
    { to: '/app/help', icon: HelpCircle, label: t('nav.help') },
  ];
  return (
    <div className="mx-auto max-w-xl">
      <h1 className="mb-4 text-2xl font-extrabold tracking-tight">{t('nav.more')}</h1>
      <Card className="mb-4">
        <div className="flex items-center gap-3">
          <span className="flex h-12 w-12 items-center justify-center rounded-full bg-brand-700 text-lg font-bold text-white">{(context?.profile?.full_name ?? '?').slice(0, 1)}</span>
          <div className="min-w-0 flex-1"><p className="truncate font-bold">{context?.profile?.full_name}</p><p className="truncate text-sm text-ink-muted">{biz.name}</p></div>
          <Badge tone="green">{t(`roles.${biz.role}`)}</Badge>
        </div>
      </Card>
      <Card padded={false}>
        <ul className="divide-y divide-gray-100 dark:divide-gray-800">
          {items.map((i) => (
            <li key={i.to}><Link to={i.to} className="flex items-center gap-3 px-5 py-3.5 hover:bg-gray-50 dark:hover:bg-gray-800"><i.icon className="h-5 w-5 text-ink-soft" /><span className="flex-1 font-medium">{i.label}</span>
              {i.to === '/app/billing' && <Badge tone="green">{t(`subscriptionState.${biz.subscription.state}`)}</Badge>}<ChevronRight className="h-4 w-4 text-gray-400" /></Link></li>
          ))}
          <li className="flex items-center justify-between px-5 py-3.5"><span className="font-medium">{t('common.language')}</span><LanguageSwitch persist /></li>
          <li><button onClick={async () => { await signOut(); nav('/login'); }} className="flex w-full items-center gap-3 px-5 py-3.5 text-red-600"><LogOut className="h-5 w-5" /><span className="font-medium">{t('nav.logout')}</span></button></li>
        </ul>
      </Card>
    </div>
  );
}
