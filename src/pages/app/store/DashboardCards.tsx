import { Link } from 'react-router-dom';
import clsx from 'clsx';
import { AlertTriangle, Clock, PackageCheck, Truck } from 'lucide-react';
import { useI18n } from '../../../i18n';
import { useBiz } from '../../../lib/business';
import { formatMoney, formatRelative } from '../../../lib/format';
import { useSellerSummary } from '../../../components/layout/AppLayout';
import { OrderStatusBadge } from '../../../components/market';
import { Card, CardHeader } from '../../../components/ui';
import { StoreSetupCard } from './MyStorePage';

/** Dashboard: online orders that need attention, and the store setup prompt until the store is live. */
export function OnlineOrdersCard() {
  const { t, lang } = useI18n();
  const { can } = useBiz();
  const q = useSellerSummary();
  if (!can('orders.manage') || !q.data) return null;
  const s = q.data;
  if (!s.readiness?.published) return <div className="mb-4"><StoreSetupCard /></div>;
  const tiles = [
    { key: 'to_confirm', n: s.to_confirm, icon: PackageCheck, tone: 'text-amber-700 bg-amber-50 dark:bg-amber-900/30', to: '/app/orders?f=to_confirm' },
    { key: 'to_deliver', n: s.to_deliver, icon: Truck, tone: 'text-blue-700 bg-blue-50 dark:bg-blue-900/30', to: '/app/orders?f=active' },
    { key: 'awaiting_payment', n: s.awaiting_payment, icon: Clock, tone: 'text-gray-700 bg-gray-100 dark:bg-gray-800', to: '/app/orders?f=awaiting_payment' },
    { key: 'disputes', n: s.disputes, icon: AlertTriangle, tone: 'text-red-700 bg-red-50 dark:bg-red-900/30', to: '/app/orders?f=all' },
  ];
  return (
    <Card className="mb-4">
      <CardHeader title={t('seller.dash.title')} subtitle={t('seller.dash.sub', { n: s.today_orders, amount: formatMoney(s.today_delivered_total, lang) })}
        action={<Link to="/app/orders" className="text-sm font-semibold text-brand-700 dark:text-brand-400">{t('common.viewAll')}</Link>} />
      <div className="grid grid-cols-2 gap-2 sm:grid-cols-4">
        {tiles.map((x) => (
          <Link key={x.key} to={x.to} className={clsx('flex items-center gap-3 rounded-xl border border-gray-100 p-3 hover:bg-gray-50 dark:border-gray-800 dark:hover:bg-gray-800', Number(x.n) > 0 && x.key !== 'awaiting_payment' && 'ring-1 ring-amber-300')}>
            <span className={clsx('flex h-9 w-9 items-center justify-center rounded-lg', x.tone)}><x.icon className="h-4 w-4" /></span>
            <span><span className="block text-lg font-extrabold leading-none">{x.n}</span><span className="text-xs text-ink-muted">{t(`seller.dash.${x.key}`)}</span></span>
          </Link>
        ))}
      </div>
      {s.recent.length > 0 && (
        <ul className="mt-4 divide-y divide-gray-100 dark:divide-gray-800">
          {s.recent.slice(0, 4).map((o: any) => (
            <li key={o.id}><Link to={`/app/orders/${o.id}`} className="flex items-center justify-between gap-3 py-2 text-sm hover:underline">
              <span className="min-w-0 truncate"><b>{o.number}</b> · {o.customer_name} <span className="text-xs text-ink-muted">{formatRelative(o.created_at, lang)}</span></span>
              <span className="flex shrink-0 items-center gap-2"><OrderStatusBadge status={o.status} /><b>{formatMoney(o.total, lang)}</b></span>
            </Link></li>
          ))}
        </ul>
      )}
    </Card>
  );
}
