import { useState } from 'react';
import { useNavigate, useSearchParams } from 'react-router-dom';
import { Download, Plus, Users } from 'lucide-react';
import { useI18n } from '../../../i18n';
import { useBiz } from '../../../lib/business';
import { useRpc } from '../../../lib/api';
import { formatDate } from '../../../lib/format';
import { downloadCsv } from '../../../lib/csv';
import { Badge, Button, Card, DataTable, EmptyState, ErrorState, Input, PageHeader, PageLoader, Tabs, useMoney } from '../../../components/ui';
import { PartyFormModal } from './PartyForm';

export default function CustomersPage() {
  const { t, lang } = useI18n();
  const { id } = useBiz();
  const money = useMoney();
  const nav = useNavigate();
  const [params, setParams] = useSearchParams();
  const filter = params.get('filter') ?? 'all';
  const [q, setQ] = useState('');
  const { data, isLoading, error, refetch } = useRpc<any[]>('customer_balances', { p_business: id });
  const rows = (data ?? []).filter((c) => (!q || c.name.toLowerCase().includes(q.toLowerCase()) || (c.phone ?? '').includes(q))
    && (filter === 'owing' ? Number(c.balance) > 0 : filter === 'overdue' ? Number(c.overdue) > 0 : true));
  const totalOwed = (data ?? []).reduce((a, c) => a + Math.max(0, Number(c.balance)), 0);
  return (
    <div>
      <PageHeader title={t('nav.customers')} subtitle={t('parties.customersSubtitle')} actions={<>
        <Button variant="outline" icon={<Download className="h-4 w-4" />} onClick={() => downloadCsv('bizpilot-customer-balances.csv', rows.map((c) => ({ name: c.name, phone: c.phone, lifetime_sales: c.lifetime_sales, balance: c.balance, overdue: c.overdue, oldest_due: c.oldest_due, last_sale: c.last_sale })))}>{t('common.exportCsv')}</Button>
        <Button icon={<Plus className="h-4 w-4" />} onClick={() => setParams({ new: '1' })}>{t('parties.new_customer')}</Button></>} />
      <Card>
        <div className="mb-3 flex flex-col justify-between gap-3 sm:flex-row sm:items-center">
          <Input className="sm:w-72" placeholder={t('common.search')} value={q} onChange={(e) => setQ(e.target.value)} />
          <p className="text-sm">{t('parties.totalOwedByCustomers')}: <b className="text-amber-700">{money(totalOwed)}</b></p>
        </div>
        <Tabs className="mb-3" value={filter} onChange={(v) => setParams(v === 'all' ? {} : { filter: v })} items={[
          { value: 'all', label: t('common.all') }, { value: 'owing', label: t('parties.owing') }, { value: 'overdue', label: t('parties.overdue') }]} />
        {isLoading ? <PageLoader /> : error ? <ErrorState error={error} onRetry={() => refetch()} /> : (
          <DataTable rows={rows} rowKey={(r) => r.id} onRowClick={(r) => nav(`/app/customers/${r.id}`)}
            empty={<EmptyState icon={<Users className="h-6 w-6" />} title={t('parties.noCustomers')} body={t('parties.noCustomersBody')} />}
            columns={[
              { key: 'n', header: t('common.name'), render: (c) => <div><p className="font-semibold">{c.name}</p><p className="text-xs text-ink-muted">{c.phone ?? ''}</p></div> },
              { key: 'ls', header: t('parties.lifetimeSales'), align: 'right', hideOnMobile: true, render: (c) => money(c.lifetime_sales) },
              { key: 'b', header: t('parties.owesUs'), align: 'right', render: (c) => Number(c.balance) > 0 ? <span className="font-semibold text-amber-700">{money(c.balance)}</span> : Number(c.balance) < 0 ? <span className="text-brand-700">{t('parties.customerCredit', { amount: money(-c.balance) })}</span> : '—' },
              { key: 'o', header: t('parties.overdue'), align: 'right', render: (c) => Number(c.overdue) > 0 ? <Badge tone="red">{money(c.overdue)}</Badge> : '' },
              { key: 'l', header: t('parties.lastSale'), hideOnMobile: true, render: (c) => c.last_sale ? formatDate(c.last_sale, lang) : '' },
            ]} />
        )}
      </Card>
      <PartyFormModal kind="customer" open={params.get('new') === '1'} onClose={() => setParams({})} onSaved={(cid) => nav(`/app/customers/${cid}`)} />
    </div>
  );
}
