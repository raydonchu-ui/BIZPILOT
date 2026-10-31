// Platform administration of BizPilot Market: stores, listings, reports and disputes, orders and
// payment issues, seller settlements and marketplace rules. Every action is audited on the server.
import { FormEvent, useEffect, useState } from 'react';
import { useQuery } from '@tanstack/react-query';
import { AlertTriangle, BadgeCheck, Ban, ExternalLink } from 'lucide-react';
import { useI18n } from '../../i18n';
import { rpc, unwrap, useRpc } from '../../lib/api';
import { supabase } from '../../lib/supabase';
import { useAction } from '../../lib/useAction';
import { formatDate, formatDateTime, formatMoney, formatNumber } from '../../lib/format';
import { OrderStatusBadge, PaymentStatusBadge, Stars } from '../../components/market';
import { Alert, Badge, Button, Card, CardHeader, Checkbox, DataTable, EmptyState, ErrorState, Field, Input, Modal, PageHeader, PageLoader, Select, StatCard, Tabs, Textarea } from '../../components/ui';

export function MarketOverview() {
  const { t, lang } = useI18n();
  const q = useRpc<any>('admin_market_overview', {});
  if (q.isLoading) return <PageLoader />;
  if (q.error) return <ErrorState error={q.error} onRetry={() => q.refetch()} />;
  const s = q.data;
  return (
    <div>
      <PageHeader title={t('admin.nav.market')} subtitle={t('madmin.overviewSub')} />
      <div className="grid grid-cols-2 gap-3 lg:grid-cols-4">
        <StatCard label={t('madmin.storesPublished')} value={formatNumber(s.stores_published, lang)} hint={t('madmin.ofTotal', { n: s.stores_total })} to="/admin/stores" />
        <StatCard label={t('madmin.pendingVerification')} value={s.stores_pending_verification} tone="amber" to="/admin/stores?status=pending_verification" />
        <StatCard label={t('madmin.listings')} value={formatNumber(s.listings, lang)} hint={t('madmin.hiddenN', { n: s.listings_hidden })} tone="blue" to="/admin/listings" />
        <StatCard label={t('madmin.gmv30')} value={formatMoney(s.gmv_30d, lang)} hint={t('madmin.orders30', { n: s.orders_30d })} tone="purple" />
        <StatCard label={t('madmin.openReports')} value={s.open_reports} tone="red" to="/admin/reports" />
        <StatCard label={t('madmin.openDisputes')} value={s.open_disputes} tone="red" to="/admin/reports" />
        <StatCard label={t('madmin.attention')} value={Number(s.refund_pending) + Number(s.flagged_orders) + Number(s.payment_issues)} tone="amber" to="/admin/orders"
          hint={t('madmin.attentionHint', { r: s.refund_pending, f: s.flagged_orders, p: s.payment_issues })} />
        <StatCard label={t('madmin.owedToSellers')} value={formatMoney(s.owed_to_sellers, lang)} hint={t('madmin.owedBySellers', { amount: formatMoney(s.owed_by_sellers, lang) })} to="/admin/settlements" />
      </div>
      <MarketSettings />
    </div>
  );
}

function MarketSettings() {
  const { t } = useI18n();
  const { run, busy } = useAction();
  const q = useQuery({ queryKey: ['admin-market-config'], queryFn: async () => (unwrap(await supabase.from('app_config').select('value').eq('key', 'marketplace').maybeSingle()) as any)?.value ?? {} });
  const [f, setF] = useState<any>(null);
  useEffect(() => { if (q.data) setF({ enabled: true, online_payments_enabled: false, commission_pct: 0, online_fee_pct: 0, unpaid_order_minutes: 30, confirm_hours: 48, max_open_cod_per_phone: 3, policies_en: '', policies_fr: '', ...q.data }); }, [q.data]);
  if (!f) return null;
  const num = (k: string) => (e: { target: { value: string } }) => setF({ ...f, [k]: Number(e.target.value) });
  const save = (e: FormEvent) => { e.preventDefault(); run(() => rpc('admin_set_config', { p_key: 'marketplace', p_value: f }), t('common.saved')); };
  return (
    <Card className="mt-4">
      <CardHeader title={t('madmin.settings')} subtitle={t('madmin.settingsSub')} />
      <form onSubmit={save} className="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
        <div className="space-y-3 sm:col-span-2 lg:col-span-3">
          <Checkbox label={t('madmin.enabled')} hint={t('madmin.enabledHint')} checked={f.enabled} onChange={(v) => setF({ ...f, enabled: v })} />
          <Checkbox label={t('madmin.onlineEnabled')} hint={t('madmin.onlineEnabledHint')} checked={f.online_payments_enabled} onChange={(v) => setF({ ...f, online_payments_enabled: v })} />
        </div>
        <Field label={t('madmin.commission')} hint={t('madmin.commissionHint')}><Input type="number" min="0" max="50" step="0.1" value={f.commission_pct} onChange={num('commission_pct')} suffix="%" /></Field>
        <Field label={t('madmin.onlineFee')} hint={t('madmin.onlineFeeHint')}><Input type="number" min="0" max="20" step="0.1" value={f.online_fee_pct} onChange={num('online_fee_pct')} suffix="%" /></Field>
        <Field label={t('madmin.unpaidMinutes')}><Input type="number" min="10" max="1440" value={f.unpaid_order_minutes} onChange={num('unpaid_order_minutes')} suffix="min" /></Field>
        <Field label={t('madmin.confirmHours')}><Input type="number" min="1" max="240" value={f.confirm_hours} onChange={num('confirm_hours')} suffix="h" /></Field>
        <Field label={t('madmin.maxOpenCod')} hint={t('madmin.maxOpenCodHint')}><Input type="number" min="1" max="50" value={f.max_open_cod_per_phone} onChange={num('max_open_cod_per_phone')} /></Field>
        <Field label={t('madmin.policiesEn')} className="sm:col-span-2 lg:col-span-3"><Textarea rows={3} value={f.policies_en ?? ''} onChange={(e) => setF({ ...f, policies_en: e.target.value })} /></Field>
        <Field label={t('madmin.policiesFr')} className="sm:col-span-2 lg:col-span-3"><Textarea rows={3} value={f.policies_fr ?? ''} onChange={(e) => setF({ ...f, policies_fr: e.target.value })} /></Field>
        <div className="sm:col-span-2 lg:col-span-3 flex justify-end"><Button type="submit" loading={busy}>{t('common.save')}</Button></div>
      </form>
    </Card>
  );
}

export function StoresAdmin() {
  const { t, lang } = useI18n();
  const [status, setStatus] = useState(new URLSearchParams(window.location.search).get('status') ?? '');
  const [q, setQ] = useState('');
  const [search, setSearch] = useState('');
  const [edit, setEdit] = useState<any | null>(null);
  const list = useRpc<any[]>('admin_market_stores', { p_search: search || null, p_status: status || null });
  return (
    <div>
      <PageHeader title={t('admin.nav.stores')} subtitle={t('madmin.storesSub')} />
      <Card>
        <form className="mb-4 flex flex-col gap-2 sm:flex-row" onSubmit={(e) => { e.preventDefault(); setSearch(q.trim()); }}>
          <Input className="sm:max-w-sm" placeholder={t('madmin.searchStores')} value={q} onChange={(e) => setQ(e.target.value)} />
          <Select className="sm:w-56" value={status} onChange={(e) => setStatus(e.target.value)} aria-label={t('common.status')}>
            <option value="">{t('common.all')}</option>
            {['published', 'pending_verification', 'draft', 'suspended'].map((s) => <option key={s} value={s}>{t(`madmin.storeFilter.${s}`)}</option>)}
          </Select>
          <Button type="submit">{t('common.search')}</Button>
        </form>
        {list.isLoading ? <PageLoader /> : (
          <DataTable rows={list.data ?? []} rowKey={(r) => r.business_id} empty={<EmptyState title={t('madmin.noStores')} />} columns={[
            { key: 'n', header: t('madmin.store'), render: (s) => <div><p className="flex items-center gap-1 font-semibold">{s.name}{s.verification === 'verified' && <BadgeCheck className="h-4 w-4 text-brand-600" />}</p>
              <p className="text-xs text-ink-muted">{s.owner_email} · {s.city ?? ''}</p></div> },
            { key: 's', header: t('common.status'), render: (s) => <div className="flex flex-wrap gap-1"><Badge tone={s.status === 'published' ? 'green' : s.status === 'suspended' ? 'red' : 'gray'}>{t(`seller.store.status.${s.status}`)}</Badge>
              {s.verification === 'pending' && <Badge tone="amber">{t('madmin.verificationRequested')}</Badge>}</div> },
            { key: 'u', header: t('madmin.activity'), hideOnMobile: true, render: (s) => <span className="text-xs">{t('madmin.activityLine', { l: s.listings, o: s.orders_30d, r: s.open_reports })}</span> },
            { key: 'b', header: t('madmin.balance'), hideOnMobile: true, align: 'right', render: (s) => formatMoney(s.balance, lang) },
            { key: 'a', header: '', align: 'right', render: (s) => <div className="flex justify-end gap-1">
              <a href={`/s/${s.slug}`} target="_blank" rel="noopener noreferrer" className="inline-flex h-8 items-center px-2 text-ink-muted" aria-label={t('seller.store.preview')}><ExternalLink className="h-4 w-4" /></a>
              <Button size="sm" variant="ghost" onClick={() => setEdit(s)}>{t('madmin.manage')}</Button></div> },
          ]} />
        )}
      </Card>
      {edit && <StoreModal store={edit} onClose={() => setEdit(null)} />}
    </div>
  );
}

function StoreModal({ store, onClose }: { store: any; onClose: () => void }) {
  const { t, lang } = useI18n();
  const { run, busy } = useAction();
  const [reason, setReason] = useState('');
  const act = async (p: Record<string, unknown>) => { const ok = await run(() => rpc('admin_market_store_update', { p_business: store.business_id, p: { ...p, reason } }), t('common.saved')); if (ok !== undefined) onClose(); };
  return (
    <Modal open onClose={onClose} title={store.name} footer={<Button variant="outline" onClick={onClose}>{t('common.close')}</Button>}>
      <div className="space-y-4 text-sm">
        <p>{t('madmin.storeInfo', { business: store.business_name, email: store.owner_email ?? '—', date: formatDate(store.created_at, lang) })}</p>
        {store.verification_note && <Alert tone="blue">{t('madmin.sellerNote')}: {store.verification_note}</Alert>}
        <Field label={t('madmin.reason')} hint={t('madmin.reasonHint')}><Textarea rows={2} value={reason} onChange={(e) => setReason(e.target.value)} /></Field>
        {store.verification !== 'verified' && <p className="text-xs text-ink-muted">{t('madmin.verifyPlanHint')}</p>}
        <div className="flex flex-wrap gap-2">
          {store.verification !== 'verified' && <Button loading={busy} icon={<BadgeCheck className="h-4 w-4" />} onClick={() => act({ verification: 'verified' })}>{t('madmin.verify')}</Button>}
          {store.verification === 'pending' && <Button variant="outline" loading={busy} disabled={!reason.trim()} onClick={() => act({ verification: 'rejected' })}>{t('madmin.rejectVerification')}</Button>}
          {store.verification === 'verified' && <Button variant="outline" loading={busy} onClick={() => act({ verification: 'unverified' })}>{t('madmin.removeVerification')}</Button>}
          {store.status !== 'suspended' ? <Button variant="danger" loading={busy} disabled={!reason.trim()} icon={<Ban className="h-4 w-4" />} onClick={() => act({ status: 'suspended' })}>{t('madmin.suspend')}</Button>
            : <Button variant="secondary" loading={busy} onClick={() => act({ status: 'published' })}>{t('madmin.restore')}</Button>}
        </div>
        <SellerLedger businessId={store.business_id} />
      </div>
    </Modal>
  );
}

function SellerLedger({ businessId }: { businessId: string }) {
  const { t, lang } = useI18n();
  const q = useRpc<any[]>('admin_market_ledger', { p_business: businessId });
  if (q.isLoading) return <PageLoader />;
  if (!q.data?.length) return <p className="text-xs text-ink-muted">{t('seller.pay.ledgerEmpty')}</p>;
  return (
    <div className="max-h-64 overflow-y-auto rounded-xl border border-gray-200 dark:border-gray-800">
      <table className="w-full text-xs">
        <tbody className="divide-y divide-gray-100 dark:divide-gray-800">
          {q.data.map((l) => (
            <tr key={l.id}><td className="px-2 py-1.5">{formatDate(l.created_at, lang)}</td><td className="px-2">{t(`seller.pay.kinds.${l.kind}`)} {l.order_number ?? l.reference ?? ''}</td>
              <td className={`px-2 text-right ${Number(l.amount) < 0 ? 'text-red-600' : 'text-brand-700'}`}>{formatMoney(l.amount, lang)}</td></tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

export function ListingsAdmin() {
  const { t, lang } = useI18n();
  const { run, busy } = useAction();
  const [q, setQ] = useState('');
  const [search, setSearch] = useState('');
  const [hiddenOnly, setHiddenOnly] = useState(false);
  const [hide, setHide] = useState<any | null>(null);
  const [reason, setReason] = useState('');
  const list = useRpc<any[]>('admin_market_listings', { p_search: search || null, p_hidden_only: hiddenOnly, p_limit: 100, p_offset: 0 });
  return (
    <div>
      <PageHeader title={t('admin.nav.listings')} subtitle={t('madmin.listingsSub')} />
      <Card>
        <form className="mb-4 flex flex-col gap-2 sm:flex-row sm:items-center" onSubmit={(e) => { e.preventDefault(); setSearch(q.trim()); }}>
          <Input className="sm:max-w-sm" placeholder={t('madmin.searchListings')} value={q} onChange={(e) => setQ(e.target.value)} />
          <Button type="submit">{t('common.search')}</Button>
          <Checkbox label={t('madmin.hiddenOnly')} checked={hiddenOnly} onChange={setHiddenOnly} />
        </form>
        {list.isLoading ? <PageLoader /> : (
          <DataTable rows={list.data ?? []} rowKey={(r) => r.id} empty={<EmptyState title={t('madmin.noListings')} />} columns={[
            { key: 'n', header: t('common.name'), render: (p) => <div><a href={`/s/${p.store_slug}/p/${p.id}`} target="_blank" rel="noopener noreferrer" className="font-semibold hover:underline">{p.name}</a>
              <p className="text-xs text-ink-muted">{p.store_name}{p.brand ? ` · ${p.brand}` : ''}</p></div> },
            { key: 'p', header: t('products.sellingPrice'), align: 'right', render: (p) => formatMoney(p.selling_price, lang) },
            { key: 'r', header: t('madmin.reports'), align: 'center', render: (p) => Number(p.open_reports) > 0 ? <Badge tone="red">{p.open_reports}</Badge> : '—' },
            { key: 's', header: t('common.status'), render: (p) => p.admin_hidden ? <div><Badge tone="red">{t('seller.product.hiddenByAdmin')}</Badge><p className="text-xs text-ink-muted">{p.admin_hidden_reason}</p></div> : <Badge tone="green">{t('seller.product.online')}</Badge> },
            { key: 'a', header: '', align: 'right', render: (p) => p.admin_hidden
              ? <Button size="sm" variant="ghost" loading={busy} onClick={() => run(() => rpc('admin_market_hide_product', { p_product: p.id, p_hidden: false, p_reason: null }), t('common.saved'))}>{t('madmin.restore')}</Button>
              : <Button size="sm" variant="ghost" className="text-red-600" onClick={() => { setHide(p); setReason(''); }}>{t('madmin.hide')}</Button> },
          ]} />
        )}
      </Card>
      <Modal open={Boolean(hide)} onClose={() => setHide(null)} title={t('madmin.hideTitle', { name: hide?.name ?? '' })} size="sm"
        footer={<><Button variant="outline" onClick={() => setHide(null)}>{t('common.cancel')}</Button><Button variant="danger" loading={busy} disabled={!reason.trim()}
          onClick={async () => { const ok = await run(() => rpc('admin_market_hide_product', { p_product: hide.id, p_hidden: true, p_reason: reason }), t('common.saved')); if (ok !== undefined) setHide(null); }}>{t('madmin.hide')}</Button></>}>
        <Field label={t('madmin.reasonToSeller')} required><Textarea rows={3} value={reason} onChange={(e) => setReason(e.target.value)} /></Field>
      </Modal>
    </div>
  );
}

export function ReportsAdmin() {
  const { t, lang } = useI18n();
  const { run, busy } = useAction();
  const [tab, setTab] = useState<'reports' | 'reviews' | 'blocked'>('reports');
  const [status, setStatus] = useState('open');
  const [open, setOpen] = useState<any | null>(null);
  const [resolution, setResolution] = useState('');
  const list = useRpc<any[]>('admin_market_reports', { p_status: status || null }, { enabled: tab === 'reports' });
  const update = async (s: string) => { const ok = await run(() => rpc('admin_market_report_update', { p_report: open.id, p_status: s, p_resolution: resolution }), t('common.saved')); if (ok !== undefined) setOpen(null); };
  const targetLink = (r: any) => r.target_type === 'product' ? `/s/${r.store_slug}/p/${r.target_id}` : r.target_type === 'store' ? `/s/${r.store_slug}` : null;
  return (
    <div>
      <PageHeader title={t('admin.nav.reports')} subtitle={t('madmin.reportsSub')} />
      <Tabs className="mb-4" value={tab} onChange={setTab} items={[{ value: 'reports', label: t('madmin.reportsTab') }, { value: 'reviews', label: t('madmin.reviewsTab') }, { value: 'blocked', label: t('madmin.blockedTab') }]} />
      {tab === 'reports' && (
        <Card>
          <div className="mb-3 w-56"><Select value={status} onChange={(e) => setStatus(e.target.value)} aria-label={t('common.status')}>
            <option value="open">{t('madmin.reportStatus.open')}</option><option value="resolved">{t('madmin.reportStatus.resolved')}</option>
            <option value="dismissed">{t('madmin.reportStatus.dismissed')}</option><option value="">{t('common.all')}</option></Select></div>
          {list.isLoading ? <PageLoader /> : (
            <DataTable rows={list.data ?? []} rowKey={(r) => r.id} onRowClick={(r) => { setOpen(r); setResolution(r.resolution ?? ''); }} empty={<EmptyState title={t('madmin.noReports')} />} columns={[
              { key: 'd', header: t('common.date'), render: (r) => formatDateTime(r.created_at, lang) },
              { key: 'k', header: t('madmin.type'), render: (r) => <Badge tone={r.kind === 'dispute' ? 'red' : 'amber'}>{t(`madmin.kind.${r.kind}`)}</Badge> },
              { key: 't', header: t('madmin.target'), render: (r) => <div><p className="font-semibold">{r.target_name ?? '—'}</p><p className="text-xs text-ink-muted">{t(`madmin.targetType.${r.target_type}`)} · {r.store_name}</p></div> },
              { key: 'r', header: t('market.reason'), render: (r) => t(`market.reasons.${r.reason}`) },
              { key: 's', header: t('common.status'), render: (r) => <Badge tone={r.status === 'resolved' ? 'green' : r.status === 'dismissed' ? 'gray' : 'amber'}>{t(`madmin.reportStatus.${r.status}`)}</Badge> },
            ]} />
          )}
        </Card>
      )}
      {tab === 'reviews' && <ReviewsModeration />}
      {tab === 'blocked' && <Blocklist />}
      <Modal open={Boolean(open)} onClose={() => setOpen(null)} title={open ? `${t(`madmin.kind.${open.kind}`)} · ${open.target_name ?? ''}` : ''}
        footer={<><Button variant="outline" onClick={() => setOpen(null)}>{t('common.close')}</Button>
          <Button variant="ghost" loading={busy} onClick={() => update('dismissed')}>{t('madmin.dismiss')}</Button>
          <Button variant="secondary" loading={busy} onClick={() => update('reviewing')}>{t('madmin.markReviewing')}</Button>
          <Button loading={busy} disabled={!resolution.trim()} onClick={() => update('resolved')}>{t('madmin.resolve')}</Button></>}>
        {open && (
          <div className="space-y-3 text-sm">
            <p><b>{t('market.reason')}:</b> {t(`market.reasons.${open.reason}`)}</p>
            {open.details && <p className="whitespace-pre-line rounded-lg bg-gray-50 p-3 dark:bg-gray-800">{open.details}</p>}
            <p className="text-xs text-ink-muted">{t('madmin.reportedBy', { who: open.reporter_email ?? open.reporter_contact ?? t('madmin.anonymous') })}</p>
            {targetLink(open) && <a href={targetLink(open)!} target="_blank" rel="noopener noreferrer" className="inline-flex items-center gap-1 font-semibold text-brand-700 hover:underline">{t('madmin.openTarget')}<ExternalLink className="h-3.5 w-3.5" /></a>}
            {open.target_type === 'order' && <p className="text-xs text-ink-muted">{t('madmin.orderInOrders')}</p>}
            <Field label={t('madmin.resolution')} hint={t('madmin.resolutionHint')}><Textarea rows={3} value={resolution} onChange={(e) => setResolution(e.target.value)} /></Field>
          </div>
        )}
      </Modal>
    </div>
  );
}

function ReviewsModeration() {
  const { t, lang } = useI18n();
  const { run, busy } = useAction();
  const q = useRpc<any[]>('admin_market_reviews', { p_search: null });
  if (q.isLoading) return <PageLoader />;
  return (
    <Card>
      <DataTable rows={q.data ?? []} rowKey={(r) => r.id} empty={<EmptyState title={t('market.noReviews')} />} columns={[
        { key: 'r', header: t('market.rating'), render: (r) => <Stars value={r.rating} /> },
        { key: 'c', header: t('market.reviewComment'), render: (r) => <div><p className="text-sm">{r.comment ?? '—'}</p><p className="text-xs text-ink-muted">{r.author_name} · {r.product_name} · {r.store_name} · {formatDate(r.created_at, lang)}</p></div> },
        { key: 'a', header: '', align: 'right', render: (r) => r.status === 'hidden'
          ? <Button size="sm" variant="ghost" loading={busy} onClick={() => run(() => rpc('admin_market_hide_review', { p_review: r.id, p_hidden: false, p_reason: null }), t('common.saved'))}>{t('madmin.restore')}</Button>
          : <Button size="sm" variant="ghost" className="text-red-600" loading={busy} onClick={() => run(() => rpc('admin_market_hide_review', { p_review: r.id, p_hidden: true, p_reason: 'moderation' }), t('common.saved'))}>{t('madmin.hide')}</Button> },
      ]} />
    </Card>
  );
}

function Blocklist() {
  const { t, lang } = useI18n();
  const { run, busy } = useAction();
  const [f, setF] = useState({ kind: 'phone', value: '', reason: '' });
  const q = useQuery({ queryKey: ['blocklist'], queryFn: async () => unwrap(await supabase.from('market_blocklist').select('*').order('created_at', { ascending: false })) as any[] });
  return (
    <Card>
      <CardHeader title={t('madmin.blockedTitle')} subtitle={t('madmin.blockedSub')} />
      <form className="mb-4 grid gap-2 sm:grid-cols-[140px_1fr_1fr_auto]" onSubmit={async (e) => { e.preventDefault(); const ok = await run(() => rpc('admin_market_block', { p_kind: f.kind, p_value: f.value, p_reason: f.reason }), t('common.saved')); if (ok) setF({ ...f, value: '', reason: '' }); }}>
        <Select aria-label={t('madmin.type')} value={f.kind} onChange={(e) => setF({ ...f, kind: e.target.value })}><option value="phone">{t('market.phone')}</option><option value="email">{t('market.email')}</option></Select>
        <Input required aria-label={t('madmin.value')} placeholder={t('madmin.value')} value={f.value} onChange={(e) => setF({ ...f, value: e.target.value })} />
        <Input required aria-label={t('madmin.reason')} placeholder={t('madmin.reason')} value={f.reason} onChange={(e) => setF({ ...f, reason: e.target.value })} />
        <Button type="submit" variant="danger" loading={busy}>{t('madmin.block')}</Button>
      </form>
      <DataTable rows={q.data ?? []} rowKey={(r) => r.id} empty={<p className="py-4 text-center text-sm text-ink-muted">{t('madmin.noBlocked')}</p>} columns={[
        { key: 'v', header: t('madmin.value'), render: (r) => <span className="font-mono text-sm">{r.value}</span> },
        { key: 'r', header: t('madmin.reason'), render: (r) => r.reason },
        { key: 'd', header: t('common.date'), render: (r) => formatDate(r.created_at, lang) },
        { key: 'a', header: '', align: 'right', render: (r) => <Button size="sm" variant="ghost" onClick={() => run(() => rpc('admin_market_unblock', { p_id: r.id }), t('common.saved'))}>{t('madmin.unblock')}</Button> },
      ]} />
    </Card>
  );
}

export function OrdersAdmin() {
  const { t, lang } = useI18n();
  const [tab, setTab] = useState<'orders' | 'payments'>('orders');
  const [filter, setFilter] = useState('attention');
  const [q, setQ] = useState('');
  const [search, setSearch] = useState('');
  const [open, setOpen] = useState<string | null>(null);
  const list = useRpc<any[]>('admin_market_orders', { p_filter: filter, p_search: search || null, p_limit: 100, p_offset: 0 }, { enabled: tab === 'orders' });
  return (
    <div>
      <PageHeader title={t('admin.nav.orders')} subtitle={t('madmin.ordersSub')} />
      <Tabs className="mb-4" value={tab} onChange={setTab} items={[{ value: 'orders', label: t('madmin.ordersTab') }, { value: 'payments', label: t('madmin.paymentIssues') }]} />
      {tab === 'payments' ? <PaymentIssues /> : (
        <Card>
          <form className="mb-4 flex flex-col gap-2 sm:flex-row" onSubmit={(e) => { e.preventDefault(); setSearch(q.trim()); }}>
            <Select className="sm:w-56" value={filter} onChange={(e) => setFilter(e.target.value)} aria-label={t('market.filters')}>
              {['attention', 'refund_pending', 'online', 'all'].map((f) => <option key={f} value={f}>{t(`madmin.orderFilter.${f}`)}</option>)}
            </Select>
            <Input className="sm:max-w-sm" placeholder={t('madmin.searchOrders')} value={q} onChange={(e) => setQ(e.target.value)} />
            <Button type="submit">{t('common.search')}</Button>
          </form>
          {list.isLoading ? <PageLoader /> : (
            <DataTable rows={list.data ?? []} rowKey={(r) => r.id} onRowClick={(r) => setOpen(r.id)} empty={<EmptyState title={t('madmin.noOrders')} />} columns={[
              { key: 'n', header: t('orders.order'), render: (o) => <div><p className="flex items-center gap-1 font-semibold">{(o.flagged || o.open_dispute) && <AlertTriangle className="h-4 w-4 text-red-600" />}{o.number}</p><p className="text-xs text-ink-muted">{o.store_name} · {formatDate(o.created_at, lang)}</p></div> },
              { key: 'c', header: t('orders.customer'), hideOnMobile: true, render: (o) => <div><p>{o.customer_name}</p><p className="text-xs text-ink-muted">{o.customer_phone}</p></div> },
              { key: 'p', header: t('orders.paymentCol'), render: (o) => <PaymentStatusBadge status={o.payment_status} /> },
              { key: 's', header: t('common.status'), render: (o) => <OrderStatusBadge status={o.status} /> },
              { key: 't', header: t('market.total'), align: 'right', render: (o) => formatMoney(o.total, lang) },
            ]} />
          )}
        </Card>
      )}
      {open && <AdminOrderModal orderId={open} onClose={() => setOpen(null)} />}
    </div>
  );
}

function AdminOrderModal({ orderId, onClose }: { orderId: string; onClose: () => void }) {
  const { t, lang } = useI18n();
  const { run, busy } = useAction();
  const q = useRpc<any>('admin_market_order', { p_order: orderId });
  const [f, setF] = useState({ message: '', visible: true, reference: '' });
  const act = (action: string, p: Record<string, unknown>) => run(() => rpc('admin_market_order_action', { p_order: orderId, p_action: action, p }), t('common.saved')).then(() => q.refetch());
  return (
    <Modal open onClose={onClose} size="xl" title={q.data ? `${q.data.number} · ${q.data.store?.name ?? ''}` : t('common.loading')} footer={<Button variant="outline" onClick={onClose}>{t('common.close')}</Button>}>
      {q.isLoading || !q.data ? <PageLoader /> : (() => {
        const o = q.data;
        return (
          <div className="space-y-4 text-sm">
            <div className="flex flex-wrap items-center gap-2"><OrderStatusBadge status={o.status} /><PaymentStatusBadge status={o.payment_status} />
              {o.flagged && <Badge tone="red">{t(`orders.flags.${o.flag_reason}`, { reason: o.flag_reason })}</Badge>}<span className="text-ink-muted">{formatDateTime(o.created_at, lang)}</span></div>
            <div className="grid gap-4 md:grid-cols-2">
              <div>
                <p className="font-semibold">{o.customer_name} · {o.customer_phone}</p>
                <p className="text-ink-muted">{o.delivery_method === 'pickup' ? t('market.pickupInStore') : [o.address?.line, o.address?.area, o.address?.city].filter(Boolean).join(', ')}</p>
                <ul className="mt-2 space-y-1">{o.lines.map((l: any) => <li key={l.id}>{Number(l.quantity)} × {l.name}{l.variant_label ? ` (${l.variant_label})` : ''} — {formatMoney(l.line_total, lang)}</li>)}</ul>
                <p className="mt-2 font-bold">{t('market.total')}: {formatMoney(o.total, lang)} · {o.payment_method === 'cod' ? t('market.cod') : t('market.payOnline')}</p>
                {o.payments.map((p: any) => <p key={p.id} className="text-xs text-ink-muted">{t(`orders.onlineStatus.${p.status}`)} · {formatMoney(p.amount, lang)} · {p.trans_id ?? '—'}{p.mismatch ? ` · ${t('madmin.mismatch')}` : ''}{p.needs_refund ? ` · ${t('madmin.needsRefund')}` : ''}</p>)}
              </div>
              <div className="max-h-72 space-y-1 overflow-y-auto rounded-xl bg-gray-50 p-3 dark:bg-gray-800/60">
                {o.events.map((e: any) => <p key={e.id} className="text-xs"><b>{t(`market.actor.${e.actor}`)}</b> · {formatDateTime(e.created_at, lang)} · {e.status ?? e.kind}{e.message ? ` — ${e.message}` : ''}{!e.visible_to_customer ? ` (${t('orders.internal')})` : ''}</p>)}
                {o.reports.map((r: any) => <p key={r.id} className="text-xs text-red-700"><b>{t(`madmin.kind.${r.kind}`)}</b>: {t(`market.reasons.${r.reason}`)} — {r.details ?? ''} ({t(`madmin.reportStatus.${r.status}`)})</p>)}
              </div>
            </div>
            <div className="grid gap-3 md:grid-cols-2">
              <Card>
                <Field label={t('madmin.noteOrMessage')}><Textarea rows={2} value={f.message} onChange={(e) => setF({ ...f, message: e.target.value })} /></Field>
                <div className="mt-2 flex flex-wrap items-center gap-2">
                  <Checkbox label={t('madmin.visibleToCustomer')} checked={f.visible} onChange={(v) => setF({ ...f, visible: v })} />
                  <Button size="sm" loading={busy} disabled={!f.message.trim()} onClick={() => act('note', { message: f.message, visible: f.visible })}>{t('madmin.addNote')}</Button>
                  {['pending', 'confirmed', 'processing', 'dispatched'].includes(o.status) && <Button size="sm" variant="danger" loading={busy} disabled={!f.message.trim()} onClick={() => act('cancel', { message: f.message })}>{t('madmin.cancelOrder')}</Button>}
                </div>
              </Card>
              <Card>
                {o.payment_status === 'refund_pending' ? (
                  <>
                    <p className="font-semibold">{t('madmin.refundTitle', { amount: formatMoney(o.refund_amount ?? o.total, lang) })}</p>
                    <p className="mt-1 text-xs text-ink-muted">{t('madmin.refundHelp')}</p>
                    <Field label={t('madmin.refundRef')} className="mt-2"><Input value={f.reference} onChange={(e) => setF({ ...f, reference: e.target.value })} /></Field>
                    <Button size="sm" className="mt-2" loading={busy} disabled={!f.reference.trim()} onClick={() => act('refund_done', { reference: f.reference })}>{t('madmin.refundDone')}</Button>
                  </>
                ) : o.flagged ? <Button size="sm" variant="outline" loading={busy} onClick={() => act('clear_flag', {})}>{t('madmin.clearFlag')}</Button>
                  : <p className="text-xs text-ink-muted">{t('madmin.noPaymentAction')}</p>}
              </Card>
            </div>
          </div>
        );
      })()}
    </Modal>
  );
}

function PaymentIssues() {
  const { t, lang } = useI18n();
  const { run, busy } = useAction();
  const [filter, setFilter] = useState('attention');
  const [open, setOpen] = useState<any | null>(null);
  const [f, setF] = useState({ note: '', reference: '' });
  const q = useRpc<any[]>('admin_market_payments', { p_filter: filter });
  const resolve = async (action: string) => { const ok = await run(() => rpc('admin_market_payment_resolve', { p_payment: open.id, p_action: action, p_note: f.note, p_reference: f.reference || null }), t('common.saved')); if (ok !== undefined) setOpen(null); };
  return (
    <Card>
      <div className="mb-3 w-56"><Select value={filter} onChange={(e) => setFilter(e.target.value)} aria-label={t('market.filters')}><option value="attention">{t('madmin.orderFilter.attention')}</option><option value="all">{t('common.all')}</option></Select></div>
      {q.isLoading ? <PageLoader /> : (
        <DataTable rows={q.data ?? []} rowKey={(r) => r.id} onRowClick={(r) => { if ((r.mismatch || r.needs_refund) && !r.refunded_at) { setOpen(r); setF({ note: '', reference: '' }); } }}
          empty={<EmptyState title={t('madmin.noPaymentIssues')} />} columns={[
            { key: 'd', header: t('common.date'), render: (p) => formatDateTime(p.created_at, lang) },
            { key: 'w', header: t('madmin.forWhat'), render: (p) => <div><p className="font-semibold">{p.kind === 'order' ? p.order_number : `${p.plan_code} · ${p.billing_period}`}</p><p className="text-xs text-ink-muted">{p.business_name}</p></div> },
            { key: 's', header: t('common.status'), render: (p) => <div className="flex flex-wrap gap-1"><Badge tone={p.status === 'successful' ? 'green' : 'gray'}>{t(`orders.onlineStatus.${p.status}`)}</Badge>
              {p.mismatch && <Badge tone="red">{t('madmin.mismatch')}</Badge>}{p.needs_refund && !p.refunded_at && <Badge tone="amber">{t('madmin.needsRefund')}</Badge>}</div> },
            { key: 'a', header: t('seller.pay.amount'), align: 'right', render: (p) => <div><p>{formatMoney(p.amount, lang)}</p>{p.amount_received !== null && Number(p.amount_received) !== Number(p.amount) && <p className="text-xs text-red-600">{t('madmin.received', { amount: formatMoney(p.amount_received, lang) })}</p>}</div> },
            { key: 't', header: 'Fapshi', hideOnMobile: true, render: (p) => <span className="font-mono text-xs">{p.trans_id ?? '—'}</span> },
          ]} />
      )}
      <Modal open={Boolean(open)} onClose={() => setOpen(null)} title={t('madmin.resolvePayment')} size="sm"
        footer={<><Button variant="outline" onClick={() => setOpen(null)}>{t('common.cancel')}</Button>
          {open?.mismatch && <Button variant="secondary" loading={busy} disabled={!f.note.trim()} onClick={() => resolve('accept')}>{t('madmin.acceptPayment')}</Button>}
          <Button loading={busy} disabled={!f.note.trim() || !f.reference.trim()} onClick={() => resolve('refunded')}>{t('madmin.markRefunded')}</Button></>}>
        <div className="space-y-3">
          <p className="text-sm">{open?.mismatch ? t('madmin.mismatchHelp') : t('madmin.duplicateHelp')}</p>
          <Field label={t('madmin.note')} required><Textarea rows={2} value={f.note} onChange={(e) => setF({ ...f, note: e.target.value })} /></Field>
          <Field label={t('madmin.refundRef')} hint={t('madmin.refundRefHint')}><Input value={f.reference} onChange={(e) => setF({ ...f, reference: e.target.value })} /></Field>
        </div>
      </Modal>
    </Card>
  );
}

export function SettlementsAdmin() {
  const { t, lang } = useI18n();
  const { run, busy } = useAction();
  const q = useRpc<any[]>('admin_market_balances', {});
  const [pay, setPay] = useState<any | null>(null);
  const [f, setF] = useState({ kind: 'payout', amount: '', method: 'mtn_momo', reference: '', note: '' });
  const submit = async (e: FormEvent) => {
    e.preventDefault();
    const ok = await run(() => rpc('admin_market_record_payout', { p_business: pay.business_id, p_amount: Number(f.amount), p_method: f.method, p_reference: f.reference, p_note: f.note || null, p_kind: f.kind }), t('common.saved'));
    if (ok !== undefined) setPay(null);
  };
  return (
    <div>
      <PageHeader title={t('admin.nav.settlements')} subtitle={t('madmin.settlementsSub')} />
      <Alert tone="blue">{t('madmin.settlementsNote')}</Alert>
      <Card className="mt-4">
        {q.isLoading ? <PageLoader /> : (
          <DataTable rows={q.data ?? []} rowKey={(r) => r.business_id} empty={<EmptyState title={t('madmin.noBalances')} />} columns={[
            { key: 'n', header: t('madmin.store'), render: (s) => <div><p className="font-semibold">{s.store_name}</p><p className="text-xs text-ink-muted">{s.whatsapp ?? s.phone ?? ''}</p></div> },
            { key: 'b', header: t('madmin.balance'), align: 'right', render: (s) => <span className={Number(s.balance) < 0 ? 'text-red-600' : 'font-bold text-brand-700'}>{formatMoney(s.balance, lang)}</span> },
            { key: 'h', header: t('seller.pay.held'), align: 'right', hideOnMobile: true, render: (s) => formatMoney(s.held_undelivered, lang) },
            { key: 'l', header: t('madmin.lastPayout'), hideOnMobile: true, render: (s) => s.last_payout_at ? formatDate(s.last_payout_at, lang) : '—' },
            { key: 'a', header: '', align: 'right', render: (s) => <Button size="sm" variant="ghost" onClick={() => { setPay(s); setF({ kind: 'payout', amount: Number(s.balance) > 0 ? String(Number(s.balance)) : '', method: 'mtn_momo', reference: '', note: '' }); }}>{t('madmin.recordPayout')}</Button> },
          ]} />
        )}
      </Card>
      <Modal open={Boolean(pay)} onClose={() => setPay(null)} title={pay ? t('madmin.payoutTitle', { store: pay.store_name }) : ''}
        footer={<><Button variant="outline" onClick={() => setPay(null)}>{t('common.cancel')}</Button><Button type="submit" form="payout-form" loading={busy}>{t('common.save')}</Button></>}>
        {pay && (
          <form id="payout-form" onSubmit={submit} className="grid gap-4 sm:grid-cols-2">
            <Field label={t('madmin.entryType')}><Select value={f.kind} onChange={(e) => setF({ ...f, kind: e.target.value })}><option value="payout">{t('seller.pay.kinds.payout')}</option><option value="adjustment">{t('seller.pay.kinds.adjustment')}</option></Select></Field>
            <Field label={t('seller.pay.amount')} required hint={f.kind === 'adjustment' ? t('madmin.adjustmentHint') : t('madmin.payoutHint')}><Input required type="number" step="1" value={f.amount} onChange={(e) => setF({ ...f, amount: e.target.value })} suffix="FCFA" /></Field>
            <Field label={t('common.method')}><Select value={f.method} onChange={(e) => setF({ ...f, method: e.target.value })}>{['mtn_momo', 'orange_money', 'bank_transfer', 'cash', 'other'].map((m) => <option key={m} value={m}>{t(`methods.${m}`)}</option>)}</Select></Field>
            <Field label={t('madmin.reference')} required><Input required value={f.reference} onChange={(e) => setF({ ...f, reference: e.target.value })} /></Field>
            <Field label={t('madmin.note')} optional={f.kind !== 'adjustment'} required={f.kind === 'adjustment'} className="sm:col-span-2"><Input value={f.note} onChange={(e) => setF({ ...f, note: e.target.value })} /></Field>
            <div className="sm:col-span-2"><SellerLedger businessId={pay.business_id} /></div>
          </form>
        )}
      </Modal>
    </div>
  );
}

