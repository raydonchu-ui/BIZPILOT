import { Link, useParams } from 'react-router-dom';
import { useQuery } from '@tanstack/react-query';
import { useI18n } from '../../../i18n';
import { supabase } from '../../../lib/supabase';
import { unwrap } from '../../../lib/api';
import { formatDate } from '../../../lib/format';
import { Badge, Card, CardHeader, DataTable, LinkButton, useMoney } from '../../../components/ui';
import { PartyDetail } from './PartyDetail';
import { outstanding, purchaseTone } from '../purchases/PurchasesPage';

export default function SupplierDetail() {
  const { id } = useParams();
  return <PartyDetail kind="supplier" partyId={id!} extra={() => <SupplierPurchases supplierId={id!} />} />;
}

function SupplierPurchases({ supplierId }: { supplierId: string }) {
  const { t, lang } = useI18n();
  const money = useMoney();
  const { data } = useQuery({
    queryKey: ['supplier-purchases', supplierId],
    queryFn: async () => unwrap(await supabase.from('purchases').select('*').eq('supplier_id', supplierId).order('purchase_date', { ascending: false }).limit(100)) as any[],
  });
  return (
    <Card className="mt-4">
      <CardHeader title={t('nav.purchases')} action={<LinkButton size="sm" to="/app/purchases/new">{t('nav.newPurchase')}</LinkButton>} />
      <DataTable rows={data ?? []} rowKey={(r) => r.id} empty={<p className="py-6 text-center text-sm text-ink-muted">{t('common.noData')}</p>} columns={[
        { key: 'n', header: t('purchases.number'), render: (p) => <Link className="font-semibold hover:underline" to={`/app/purchases/${p.id}`}>{p.number}</Link> },
        { key: 'd', header: t('common.date'), render: (p) => formatDate(p.purchase_date, lang) },
        { key: 's', header: t('common.status'), render: (p) => <Badge tone={purchaseTone[p.status]}>{t(`purchaseStatus.${p.status}`)}</Badge> },
        { key: 't', header: t('common.total'), align: 'right', render: (p) => money(p.total) },
        { key: 'o', header: t('purchases.outstanding'), align: 'right', render: (p) => outstanding(p) > 0 ? <span className="text-red-600">{money(outstanding(p))}</span> : '—' },
        { key: 'due', header: t('common.dueDate'), hideOnMobile: true, render: (p) => p.due_date ? formatDate(p.due_date, lang) : '' },
      ]} />
    </Card>
  );
}
