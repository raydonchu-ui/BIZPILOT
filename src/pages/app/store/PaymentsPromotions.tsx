import { FormEvent, useState } from 'react';
import { Link } from 'react-router-dom';
import { useQuery } from '@tanstack/react-query';
import { BadgePercent, Copy, Info, Plus, Wallet } from 'lucide-react';
import { useI18n } from '../../../i18n';
import { useBiz } from '../../../lib/business';
import { rpc, unwrap, useRpc } from '../../../lib/api';
import { supabase } from '../../../lib/supabase';
import { useAction } from '../../../lib/useAction';
import { useToast } from '../../../lib/toast';
import { formatDate, formatDateTime, formatMoney } from '../../../lib/format';
import { useMarketConfig } from '../../../lib/market';
import { Alert, Badge, Button, Card, Checkbox, DataTable, EmptyState, ErrorState, Field, Input, Modal, PageHeader, PageLoader, Select, StatCard, Tabs, UpgradeNotice } from '../../../components/ui';

function NeedsUpgrade({ title }: { title: string }) {
  const { t } = useI18n();
  return <div className="mx-auto max-w-3xl"><PageHeader title={title} /><Alert tone="blue" title={t('seller.store.upgradeTitle')}>{t('seller.store.upgradeBody')}</Alert></div>;
}

export default function PaymentsPage() {
  const { t, lang } = useI18n();
  const { id, can } = useBiz();
  const cfg = useMarketConfig();
  const [tab, setTab] = useState<'ledger' | 'online'>('ledger');
  const summary = useRpc<any>('seller_payments_summary', { p_business: id }, { enabled: Boolean(cfg.data) && can('cash.manage') });
  const ledger = useQuery({
    queryKey: ['ledger', id], enabled: Boolean(cfg.data) && can('cash.manage'),
    queryFn: async () => unwrap(await supabase.from('market_ledger').select('*, market_orders(number)').eq('business_id', id).order('created_at', { ascending: false }).limit(200)) as any[],
  });
  const online = useQuery({
    queryKey: ['online-payments', id], enabled: Boolean(cfg.data) && can('cash.manage') && tab === 'online',
    queryFn: async () => unwrap(await supabase.from('online_payments').select('id,status,amount,medium,payer_name,verified_at,created_at,needs_refund,refunded_at,market_orders(id,number)')
      .eq('business_id', id).eq('kind', 'order').order('created_at', { ascending: false }).limit(200)) as any[],
  });
  if (cfg.isLoading) return <PageLoader />;
  if (!cfg.data) return <NeedsUpgrade title={t('nav.payments')} />;
  if (!can('cash.manage')) return <ErrorState error={{ message: 'permission_denied' }} />;
  if (summary.isLoading) return <PageLoader />;
  if (summary.error) return <ErrorState error={summary.error} onRetry={() => summary.refetch()} />;
  const s = summary.data;
  const bal = Number(s.balance);
  return (
    <div>
      <PageHeader title={t('nav.payments')} subtitle={t('seller.pay.subtitle')} />
      <div className="grid grid-cols-2 gap-3 lg:grid-cols-4">
        <StatCard label={bal >= 0 ? t('seller.pay.owedToYou') : t('seller.pay.youOwe')} value={formatMoney(Math.abs(bal), lang)} icon={<Wallet className="h-5 w-5" />} tone={bal >= 0 ? 'green' : 'red'} hint={t('seller.pay.owedHint')} />
        <StatCard label={t('seller.pay.held')} value={formatMoney(s.held_undelivered, lang)} tone="amber" hint={t('seller.pay.heldHint')} />
        <StatCard label={t('seller.pay.paidOut')} value={formatMoney(s.paid_out_total, lang)} tone="blue" />
        <StatCard label={t('seller.pay.codCollected')} value={formatMoney(s.cod_collected_30d, lang)} tone="purple" hint={t('seller.pay.last30')} />
      </div>
      <Card className="mt-4">
        <div className="flex gap-3 text-sm">
          <Info className="mt-0.5 h-5 w-5 shrink-0 text-brand-600" />
          <div className="space-y-1">
            <p className="font-semibold">{t('seller.pay.howTitle')}</p>
            <p className="text-ink-soft dark:text-gray-300">{t('seller.pay.how1')}</p>
            <p className="text-ink-soft dark:text-gray-300">{t('seller.pay.how2')}</p>
            <p className="font-semibold">{t('seller.store.fees', { commission: s.config.commission_pct, fee: s.config.online_fee_pct })}</p>
            <p className="text-xs text-ink-muted">{t('seller.pay.deliveryFees', { amount: formatMoney(s.delivery_fees_30d, lang), fees: formatMoney(s.commission_30d, lang) })}</p>
          </div>
        </div>
      </Card>
      {Number(s.refund_pending) > 0 && <div className="mt-4"><Alert tone="amber">{t('seller.pay.refundPending', { n: s.refund_pending })}</Alert></div>}
      <Card className="mt-4">
        <Tabs className="mb-3" value={tab} onChange={setTab} items={[{ value: 'ledger', label: t('seller.pay.ledger') }, { value: 'online', label: t('seller.pay.onlinePayments') }]} />
        {tab === 'ledger' ? (
          ledger.isLoading ? <PageLoader /> : (
            <DataTable rows={ledger.data ?? []} rowKey={(r) => String(r.id)} empty={<EmptyState title={t('seller.pay.ledgerEmpty')} body={t('seller.pay.ledgerEmptyBody')} />} columns={[
              { key: 'd', header: t('common.date'), render: (r) => formatDate(r.created_at, lang) },
              { key: 'k', header: t('seller.pay.entry'), render: (r) => <div><p className="font-medium">{t(`seller.pay.kinds.${r.kind}`)}</p><p className="text-xs text-ink-muted">{r.market_orders?.number ?? r.reference ?? ''}{r.note && r.kind === 'adjustment' ? ` · ${r.note}` : ''}</p></div> },
              { key: 'a', header: t('seller.pay.amount'), align: 'right', render: (r) => <span className={Number(r.amount) < 0 ? 'text-red-600' : 'text-brand-700'}>{Number(r.amount) > 0 ? '+' : ''}{formatMoney(r.amount, lang)}</span> },
            ]} />
          )
        ) : online.isLoading ? <PageLoader /> : (
          <DataTable rows={online.data ?? []} rowKey={(r) => r.id} empty={<EmptyState title={t('seller.pay.onlineEmpty')} />} columns={[
            { key: 'd', header: t('common.date'), render: (r) => formatDateTime(r.created_at, lang) },
            { key: 'o', header: t('orders.order'), render: (r) => r.market_orders ? <Link to={`/app/orders/${r.market_orders.id}`} className="font-semibold text-brand-700 hover:underline">{r.market_orders.number}</Link> : '—' },
            { key: 's', header: t('common.status'), render: (r) => <Badge tone={r.status === 'successful' ? 'green' : ['failed', 'expired'].includes(r.status) ? 'gray' : 'amber'}>{t(`orders.onlineStatus.${r.status}`)}</Badge> },
            { key: 'm', header: t('seller.pay.medium'), hideOnMobile: true, render: (r) => r.medium ?? '—' },
            { key: 'a', header: t('seller.pay.amount'), align: 'right', render: (r) => formatMoney(r.amount, lang) },
          ]} />
        )}
      </Card>
    </div>
  );
}

const blankPromo = { id: '', code: '', description: '', kind: 'percent', value: '', min_order: '', starts_at: '', ends_at: '', max_uses: '', active: true };

export function PromotionsPage() {
  const { t, lang } = useI18n();
  const { id, has, can } = useBiz();
  const cfg = useMarketConfig();
  const toast = useToast();
  const { run, busy } = useAction();
  const [edit, setEdit] = useState<typeof blankPromo | null>(null);
  const list = useQuery({
    queryKey: ['promos', id], enabled: Boolean(cfg.data) && has('promotions'),
    queryFn: async () => unwrap(await supabase.from('market_promotions').select('*').eq('business_id', id).order('created_at', { ascending: false })) as any[],
  });
  if (cfg.isLoading) return <PageLoader />;
  if (!cfg.data) return <NeedsUpgrade title={t('nav.promotions')} />;
  if (!can('store.manage')) return <ErrorState error={{ message: 'permission_denied' }} />;
  const save = async (e: FormEvent) => {
    e.preventDefault();
    if (!edit) return;
    const r = await run(() => rpc('promo_save', { p_business: id, p: { ...edit, id: edit.id || null,
      starts_at: edit.starts_at ? new Date(edit.starts_at).toISOString() : null, ends_at: edit.ends_at ? new Date(edit.ends_at).toISOString() : null } }), t('common.saved'));
    if (r) setEdit(null);
  };
  const toggle = (p: any) => run(() => rpc('promo_save', { p_business: id, p: { ...p, active: !p.active } }), t('common.saved'));
  const set = (k: keyof typeof blankPromo) => (e: { target: { value: string } }) => setEdit((x) => (x ? { ...x, [k]: e.target.value } : x));
  const status = (p: any) => !p.active ? 'inactive' : p.ends_at && new Date(p.ends_at) < new Date() ? 'ended'
    : p.starts_at && new Date(p.starts_at) > new Date() ? 'scheduled' : p.max_uses && p.used_count >= p.max_uses ? 'used_up' : 'active';
  return (
    <div>
      <PageHeader title={t('nav.promotions')} subtitle={t('seller.promo.subtitle')}
        actions={has('promotions') && <Button icon={<Plus className="h-4 w-4" />} onClick={() => setEdit({ ...blankPromo })}>{t('seller.promo.new')}</Button>} />
      {!has('promotions') ? <UpgradeNotice feature="promotions" /> : (
        <Card>
          {list.isLoading ? <PageLoader /> : (
            <DataTable rows={list.data ?? []} rowKey={(r) => r.id}
              empty={<EmptyState icon={<BadgePercent className="h-6 w-6" />} title={t('seller.promo.emptyTitle')} body={t('seller.promo.emptyBody')}
                action={<Button onClick={() => setEdit({ ...blankPromo })}>{t('seller.promo.new')}</Button>} />}
              columns={[
                { key: 'c', header: t('seller.promo.code'), render: (p) => <div className="flex items-center gap-2"><code className="rounded bg-gray-100 px-2 py-0.5 font-bold dark:bg-gray-800">{p.code}</code>
                  <button aria-label={t('seller.promo.copy')} onClick={async () => { try { await navigator.clipboard.writeText(p.code); toast(t('market.linkCopied'), 'success'); } catch { /* ignore */ } }}><Copy className="h-4 w-4 text-ink-muted" /></button></div> },
                { key: 'v', header: t('seller.promo.discount'), render: (p) => p.kind === 'percent' ? `${Number(p.value)} %` : formatMoney(p.value, lang) },
                { key: 'm', header: t('seller.promo.minOrder'), hideOnMobile: true, render: (p) => Number(p.min_order) ? formatMoney(p.min_order, lang) : '—' },
                { key: 'u', header: t('seller.promo.uses'), hideOnMobile: true, render: (p) => `${p.used_count}${p.max_uses ? ` / ${p.max_uses}` : ''}` },
                { key: 's', header: t('common.status'), render: (p) => <Badge tone={status(p) === 'active' ? 'green' : 'gray'}>{t(`seller.promo.status.${status(p)}`)}</Badge> },
                { key: 'a', header: '', align: 'right', render: (p) => <div className="flex justify-end gap-1">
                  <Button size="sm" variant="ghost" onClick={() => setEdit({ ...blankPromo, ...p, value: String(p.value), min_order: String(p.min_order ?? ''), max_uses: p.max_uses?.toString() ?? '',
                    starts_at: p.starts_at ? p.starts_at.slice(0, 16) : '', ends_at: p.ends_at ? p.ends_at.slice(0, 16) : '', description: p.description ?? '' })}>{t('common.edit')}</Button>
                  <Button size="sm" variant="ghost" onClick={() => toggle(p)}>{p.active ? t('seller.promo.pause') : t('seller.promo.resume')}</Button></div> },
              ]} />
          )}
        </Card>
      )}
      <Modal open={Boolean(edit)} onClose={() => setEdit(null)} title={edit?.id ? t('seller.promo.edit') : t('seller.promo.new')}
        footer={<><Button variant="outline" onClick={() => setEdit(null)}>{t('common.cancel')}</Button><Button type="submit" form="promo-form" loading={busy}>{t('common.save')}</Button></>}>
        {edit && (
          <form id="promo-form" onSubmit={save} className="grid gap-4 sm:grid-cols-2">
            <Field label={t('seller.promo.code')} required hint={t('seller.promo.codeHint')}><Input required pattern="[A-Za-z0-9_-]{3,20}" disabled={Boolean(edit.id)} value={edit.code} onChange={(e) => setEdit({ ...edit, code: e.target.value.toUpperCase() })} placeholder="TABASKI10" /></Field>
            <Field label={t('seller.promo.type')}>
              <Select value={edit.kind} onChange={set('kind')}><option value="percent">{t('seller.promo.percent')}</option><option value="fixed">{t('seller.promo.fixed')}</option></Select>
            </Field>
            <Field label={edit.kind === 'percent' ? t('seller.promo.percentValue') : t('seller.promo.fixedValue')} required><Input required type="number" min="1" max={edit.kind === 'percent' ? 90 : undefined} value={edit.value} onChange={set('value')} suffix={edit.kind === 'percent' ? '%' : 'FCFA'} /></Field>
            <Field label={t('seller.promo.minOrder')} optional><Input type="number" min="0" value={edit.min_order} onChange={set('min_order')} suffix="FCFA" /></Field>
            <Field label={t('seller.promo.starts')} optional><Input type="datetime-local" value={edit.starts_at} onChange={set('starts_at')} /></Field>
            <Field label={t('seller.promo.ends')} optional><Input type="datetime-local" value={edit.ends_at} onChange={set('ends_at')} /></Field>
            <Field label={t('seller.promo.maxUses')} optional><Input type="number" min="1" value={edit.max_uses} onChange={set('max_uses')} /></Field>
            <Field label={t('common.description')} optional><Input maxLength={200} value={edit.description} onChange={set('description')} /></Field>
            <div className="sm:col-span-2"><Checkbox label={t('common.active')} checked={edit.active} onChange={(v) => setEdit({ ...edit, active: v })} /></div>
          </form>
        )}
      </Modal>
    </div>
  );
}

