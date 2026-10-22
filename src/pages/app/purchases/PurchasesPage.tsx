import { useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { useQuery } from '@tanstack/react-query';
import { Download, Plus, ShoppingBag } from 'lucide-react';
import { useI18n } from '../../../i18n';
import { useBiz } from '../../../lib/business';
import { supabase } from '../../../lib/supabase';
import { unwrap } from '../../../lib/api';
import { useSuppliers } from '../../../lib/hooks';
import { formatDate } from '../../../lib/format';
import { downloadCsv } from '../../../lib/csv';
import { Badge, Button, Card, DataTable, EmptyState, ErrorState, Input, LinkButton, PageHeader, PageLoader, Pagination, Select, Tabs, Tone, UpgradeNotice, useMoney } from '../../../components/ui';

const PAGE = 25;
export const purchaseTone: Record<string, Tone> = { draft: 'gray', ordered: 'blue', partially_received: 'amber', received: 'green', cancelled: 'gray' };

export function outstanding(p: { total: number; credited_total: number; paid_total: number; status: string }) {
  if (['draft', 'cancelled'].includes(p.status)) return 0;
  return Math.max(0, Number(p.total) - Number(p.credited_total) - Number(p.paid_total));
}

export default function PurchasesPage() {
  const { t, lang } = useI18n();
  const { id, has } = useBiz();
  const money = useMoney();
  const nav = useNavigate();
  const [status, setStatus] = useState('all');
  const [sup, setSup] = useState('');
  const [q, setQ] = useState('');
  const [page, setPage] = useState(0);
  const sups = useSuppliers(id, has('suppliers'));
  const build = () => {
    let query = supabase.from('purchases').select('*, suppliers(name)', { count: 'exact' }).eq('business_id', id).order('purchase_date', { ascending: false }).order('created_at', { ascending: false });
    if (status === 'open') query = query.in('status', ['ordered', 'partially_received']);
    else if (status === 'unpaid') query = query.in('status', ['ordered', 'partially_received', 'received']);
    else if (status !== 'all') query = query.eq('status', status);
    if (sup) query = query.eq('supplier_id', sup);
    if (q.trim()) query = query.or(`number.ilike.%${q.trim()}%,invoice_number.ilike.%${q.trim()}%`);
    return query;
  };
  const { data, isLoading, error, refetch } = useQuery({
    queryKey: ['purchases', id, status, sup, q, page],
    enabled: has('purchases'),
    queryFn: async () => {
      if (status === 'unpaid') {
        const all = (unwrap(await build().limit(2000)) as any[]).filter((p) => outstanding(p) > 0);
        return { rows: all.slice(page * PAGE, page * PAGE + PAGE), count: all.length };
      }
      const r = await build().range(page * PAGE, page * PAGE + PAGE - 1);
      return { rows: unwrap(r) as any[], count: r.count ?? 0 };
    },
  });
  if (!has('purchases')) return <div><PageHeader title={t('purchases.title')} /><UpgradeNotice feature="purchases" /></div>;
  const exportCsv = async () => {
    const rows = unwrap(await build().limit(5000)) as any[];
    downloadCsv('bizpilot-purchases.csv', rows.map((p) => ({ number: p.number, date: p.purchase_date, supplier: p.suppliers?.name, invoice: p.invoice_number,
      status: p.status, subtotal: p.subtotal, transport: p.transport_cost, other_costs: p.other_costs, discount: p.discount_amount, total: p.total,
      credited: p.credited_total, paid: p.paid_total, outstanding: outstanding(p), due_date: p.due_date })));
  };
  return (
    <div>
      <PageHeader title={t('purchases.title')} subtitle={t('purchases.subtitle')} actions={<>
        <Button variant="outline" icon={<Download className="h-4 w-4" />} onClick={exportCsv}>{t('common.exportCsv')}</Button>
        <LinkButton to="/app/purchases/new" icon={<Plus className="h-4 w-4" />}>{t('nav.newPurchase')}</LinkButton></>} />
      <Card>
        <div className="mb-3 flex flex-col gap-3 md:flex-row">
          <Input className="md:w-64" placeholder={t('purchases.searchPlaceholder')} value={q} onChange={(e) => { setQ(e.target.value); setPage(0); }} />
          <Select className="md:w-56" value={sup} onChange={(e) => { setSup(e.target.value); setPage(0); }}><option value="">{t('purchases.allSuppliers')}</option>{(sups.data ?? []).map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}</Select>
        </div>
        <Tabs className="mb-3" value={status} onChange={(v) => { setStatus(v); setPage(0); }} items={[
          { value: 'all', label: t('common.all') }, { value: 'open', label: t('purchases.awaitingDelivery') }, { value: 'unpaid', label: t('purchases.unpaid') },
          { value: 'draft', label: t('purchaseStatus.draft') }, { value: 'received', label: t('purchaseStatus.received') }, { value: 'cancelled', label: t('purchaseStatus.cancelled') }]} />
        {isLoading ? <PageLoader /> : error ? <ErrorState error={error} onRetry={() => refetch()} /> : (
          <>
            <DataTable rows={data!.rows} rowKey={(r) => r.id} onRowClick={(r) => nav(`/app/purchases/${r.id}`)}
              empty={<EmptyState icon={<ShoppingBag className="h-6 w-6" />} title={t('purchases.emptyTitle')} body={t('purchases.emptyBody')} action={<LinkButton to="/app/purchases/new" size="sm">{t('nav.newPurchase')}</LinkButton>} />}
              columns={[
                { key: 'n', header: t('purchases.number'), render: (p) => <div><p className="font-semibold">{p.number}</p><p className="text-xs text-ink-muted">{p.invoice_number ?? ''}</p></div> },
                { key: 'd', header: t('common.date'), render: (p) => formatDate(p.purchase_date, lang) },
                { key: 's', header: t('purchases.supplier'), render: (p) => p.suppliers?.name },
                { key: 'st', header: t('common.status'), render: (p) => <Badge tone={purchaseTone[p.status]}>{t(`purchaseStatus.${p.status}`)}</Badge> },
                { key: 't', header: t('common.total'), align: 'right', render: (p) => money(p.total) },
                { key: 'o', header: t('purchases.outstanding'), align: 'right', hideOnMobile: true, render: (p) => { const o = outstanding(p); return o > 0 ? <span className="font-semibold text-red-600">{money(o)}</span> : '—'; } },
                { key: 'due', header: t('common.dueDate'), hideOnMobile: true, render: (p) => outstanding(p) > 0 && p.due_date ? formatDate(p.due_date, lang) : '' },
              ]} />
            <Pagination page={page} pageSize={PAGE} total={data!.count} onPage={setPage} />
          </>
        )}
      </Card>
    </div>
  );
}
