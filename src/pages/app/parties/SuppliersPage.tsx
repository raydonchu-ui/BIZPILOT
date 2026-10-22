import { useState } from 'react';
import { useNavigate, useSearchParams } from 'react-router-dom';
import { Download, Plus, Truck } from 'lucide-react';
import { useI18n } from '../../../i18n';
import { useBiz } from '../../../lib/business';
import { useRpc } from '../../../lib/api';
import { formatDate } from '../../../lib/format';
import { downloadCsv } from '../../../lib/csv';
import { Badge, Button, Card, DataTable, EmptyState, ErrorState, Input, PageHeader, PageLoader, UpgradeNotice, useMoney } from '../../../components/ui';
import { PartyFormModal } from './PartyForm';

export default function SuppliersPage() {
  const { t, lang } = useI18n();
  const { id, has, can } = useBiz();
  const money = useMoney();
  const nav = useNavigate();
  const [params, setParams] = useSearchParams();
  const [q, setQ] = useState('');
  const { data, isLoading, error, refetch } = useRpc<any[]>('supplier_balances', { p_business: id }, { enabled: has('suppliers') });
  if (!has('suppliers')) return <div><PageHeader title={t('nav.suppliers')} /><UpgradeNotice feature="suppliers" /></div>;
  const rows = (data ?? []).filter((s) => !q || s.name.toLowerCase().includes(q.toLowerCase()) || (s.phone ?? '').includes(q));
  const totalOwed = rows.reduce((a, s) => a + Math.max(0, Number(s.balance)), 0);
  return (
    <div>
      <PageHeader title={t('nav.suppliers')} subtitle={t('parties.suppliersSubtitle')} actions={<>
        <Button variant="outline" icon={<Download className="h-4 w-4" />} onClick={() => downloadCsv('bizpilot-supplier-balances.csv', rows.map((s) => ({ name: s.name, phone: s.phone, total_purchased: s.total_purchased, balance: s.balance, overdue: s.overdue, next_due: s.next_due, last_purchase: s.last_purchase })))}>{t('common.exportCsv')}</Button>
        {can('suppliers.manage') && <Button icon={<Plus className="h-4 w-4" />} onClick={() => setParams({ new: '1' })}>{t('nav.addSupplier')}</Button>}</>} />
      <Card>
        <div className="mb-4 flex flex-col justify-between gap-3 sm:flex-row sm:items-center">
          <Input className="sm:w-72" placeholder={t('common.search')} value={q} onChange={(e) => setQ(e.target.value)} />
          <p className="text-sm">{t('parties.totalOwedSuppliers')}: <b className="text-red-600">{money(totalOwed)}</b></p>
        </div>
        {isLoading ? <PageLoader /> : error ? <ErrorState error={error} onRetry={() => refetch()} /> : (
          <DataTable rows={rows} rowKey={(r) => r.id} onRowClick={(r) => nav(`/app/suppliers/${r.id}`)}
            empty={<EmptyState icon={<Truck className="h-6 w-6" />} title={t('parties.noSuppliers')} body={t('parties.noSuppliersBody')} action={can('suppliers.manage') && <Button size="sm" onClick={() => setParams({ new: '1' })}>{t('nav.addSupplier')}</Button>} />}
            columns={[
              { key: 'n', header: t('common.name'), render: (s) => <div><p className="font-semibold">{s.name}</p><p className="text-xs text-ink-muted">{s.phone ?? ''}</p></div> },
              { key: 'tp', header: t('parties.totalPurchased'), align: 'right', hideOnMobile: true, render: (s) => money(s.total_purchased) },
              { key: 'b', header: t('parties.weOwe'), align: 'right', render: (s) => Number(s.balance) > 0 ? <span className="font-semibold text-red-600">{money(s.balance)}</span> : Number(s.balance) < 0 ? <span className="text-brand-700">{t('parties.creditWithSupplier', { amount: money(-s.balance) })}</span> : '—' },
              { key: 'o', header: t('parties.overdue'), align: 'right', render: (s) => Number(s.overdue) > 0 ? <Badge tone="red">{money(s.overdue)}</Badge> : '' },
              { key: 'd', header: t('parties.nextDue'), hideOnMobile: true, render: (s) => s.next_due ? formatDate(s.next_due, lang) : '' },
              { key: 'l', header: t('parties.lastPurchase'), hideOnMobile: true, render: (s) => s.last_purchase ? formatDate(s.last_purchase, lang) : '' },
            ]} />
        )}
      </Card>
      <PartyFormModal kind="supplier" open={params.get('new') === '1'} onClose={() => setParams({})} onSaved={(sid) => nav(`/app/suppliers/${sid}`)} />
    </div>
  );
}
