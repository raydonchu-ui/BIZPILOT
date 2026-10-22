import { Link, useParams } from 'react-router-dom';
import { useQuery } from '@tanstack/react-query';
import { useI18n } from '../../../i18n';
import { supabase } from '../../../lib/supabase';
import { unwrap } from '../../../lib/api';
import { formatDate, formatDateTime } from '../../../lib/format';
import { Badge, Card, CardHeader, DataTable, useMoney } from '../../../components/ui';
import { PartyDetail } from './PartyDetail';

export default function CustomerDetail() {
  const { id } = useParams();
  return <PartyDetail kind="customer" partyId={id!} extra={() => <CustomerSales customerId={id!} />} />;
}

function CustomerSales({ customerId }: { customerId: string }) {
  const { t, lang } = useI18n();
  const money = useMoney();
  const { data } = useQuery({
    queryKey: ['customer-sales', customerId],
    queryFn: async () => unwrap(await supabase.from('sales').select('*').eq('customer_id', customerId).order('sold_at', { ascending: false }).limit(100)) as any[],
  });
  return (
    <Card className="mt-4">
      <CardHeader title={t('nav.sales')} />
      <DataTable rows={data ?? []} rowKey={(r) => r.id} empty={<p className="py-6 text-center text-sm text-ink-muted">{t('common.noData')}</p>} columns={[
        { key: 'n', header: t('sales.number'), render: (s) => <Link className="font-semibold hover:underline" to={`/app/sales/${s.id}`}>{s.number}</Link> },
        { key: 'd', header: t('common.date'), render: (s) => formatDateTime(s.sold_at, lang) },
        { key: 't', header: t('common.total'), align: 'right', render: (s) => money(Number(s.total) - Number(s.returned_total)) },
        { key: 'o', header: t('sales.outstanding'), align: 'right', render: (s) => { const o = Number(s.total) - Number(s.returned_total) + Number(s.refunded_total) - Number(s.paid_total); return o > 0 ? <span className="text-amber-700">{money(o)}</span> : '—'; } },
        { key: 'due', header: t('common.dueDate'), render: (s) => { const o = Number(s.total) - Number(s.returned_total) + Number(s.refunded_total) - Number(s.paid_total); return o > 0 && s.due_date ? <Badge tone={new Date(s.due_date) < new Date() ? 'red' : 'gray'}>{formatDate(s.due_date, lang)}</Badge> : ''; } },
      ]} />
    </Card>
  );
}
