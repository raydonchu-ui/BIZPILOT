import { useEffect, useState } from 'react';
import { Link, NavLink, Route, Routes } from 'react-router-dom';
import { useQuery } from '@tanstack/react-query';
import clsx from 'clsx';
import { ArrowLeft, Banknote, Bot, Building2, CreditCard, FileClock, Flag, Gauge, HandCoins, LifeBuoy, Megaphone, PackageCheck, Settings2, ShoppingBasket, Store, Tags } from 'lucide-react';
import { FapshiAdmin, FapshiTodayStat } from './FapshiAdmin';
import { ListingsAdmin, MarketOverview, OrdersAdmin, ReportsAdmin, SettlementsAdmin, StoresAdmin } from './MarketAdmin';
import { useMarketConfig } from '../../lib/market';
import { useI18n } from '../../i18n';
import { supabase } from '../../lib/supabase';
import { rpc, unwrap, useRpc } from '../../lib/api';
import { useAction } from '../../lib/useAction';
import { openFile } from '../../lib/hooks';
import { formatDate, formatDateTime, formatMoney, formatNumber, toNumber } from '../../lib/format';
import { Alert, Badge, Button, Card, CardHeader, Checkbox, DataTable, ErrorState, Field, Input, Modal, PageHeader, PageLoader, Select, StatCard, Textarea } from '../../components/ui';
import { LogoMark } from '../../components/Logo';
import { LanguageSwitch } from '../../components/LanguageSwitch';

const NAV = [
  { to: '/admin', key: 'overview', icon: Gauge, end: true }, { to: '/admin/businesses', key: 'businesses', icon: Building2 },
  { to: '/admin/payments', key: 'payments', icon: CreditCard }, { to: '/admin/plans', key: 'plans', icon: Tags },
  { to: '/admin/config', key: 'config', icon: Settings2 }, { to: '/admin/announcements', key: 'announcements', icon: Megaphone },
  { to: '/admin/support', key: 'support', icon: LifeBuoy }, { to: '/admin/ai', key: 'ai', icon: Bot }, { to: '/admin/audit', key: 'audit', icon: FileClock },
];
const MARKET_NAV: { to: string; key: string; icon: typeof Store; end?: boolean }[] = [
  { to: '/admin/fapshi', key: 'fapshi', icon: Banknote }, { to: '/admin/market', key: 'market', icon: ShoppingBasket }, { to: '/admin/stores', key: 'stores', icon: Store },
  { to: '/admin/listings', key: 'listings', icon: Tags }, { to: '/admin/reports', key: 'reports', icon: Flag },
  { to: '/admin/orders', key: 'orders', icon: PackageCheck }, { to: '/admin/settlements', key: 'settlements', icon: HandCoins },
];
const FEATURES = ['stocktaking', 'purchases', 'suppliers', 'expenses', 'customers_credit', 'staff', 'import', 'cash_reconciliation', 'basic_analytics', 'advanced_analytics', 'restock', 'reports_export', 'batch_tracking', 'ai_advisor', 'promotions', 'store_customization'];
const LIMITS = ['max_products', 'max_sales_per_month', 'max_staff', 'history_days', 'ai_queries_per_month', 'max_online_products'];

export default function AdminApp() {
  const { t } = useI18n();
  const market = Boolean(useMarketConfig().data);
  const nav = market ? [...NAV.slice(0, 1), ...MARKET_NAV, ...NAV.slice(1)] : NAV;
  return (
    <div className="min-h-screen bg-gray-50 dark:bg-gray-950">
      <header className="border-b border-gray-200 bg-white dark:border-gray-800 dark:bg-gray-900">
        <div className="mx-auto flex h-14 max-w-7xl items-center gap-3 px-4">
          <LogoMark className="h-8 w-8" /><span className="font-extrabold">BizPilot</span><Badge tone="red">{t('admin.badge')}</Badge>
          <div className="ml-auto flex items-center gap-3"><LanguageSwitch /><Link to="/app" className="flex items-center gap-1 text-sm font-semibold text-brand-700"><ArrowLeft className="h-4 w-4" />{t('admin.backToApp')}</Link></div>
        </div>
        <nav className="mx-auto flex max-w-7xl gap-1 overflow-x-auto px-4 pb-2">
          {nav.map((n) => <NavLink key={n.to} to={n.to} end={n.end} className={({ isActive }) => clsx('flex items-center gap-1.5 whitespace-nowrap rounded-lg px-3 py-1.5 text-sm font-semibold', isActive ? 'bg-brand-700 text-white' : 'text-ink-soft hover:bg-gray-100 dark:text-gray-300 dark:hover:bg-gray-800')}><n.icon className="h-4 w-4" />{t(`admin.nav.${n.key}`)}</NavLink>)}
        </nav>
      </header>
      <main className="mx-auto max-w-7xl px-4 py-6">
        <Alert tone="amber">{t('admin.privacyNote')}</Alert>
        <div className="mt-4">
          <Routes>
            <Route index element={<Overview />} />
            <Route path="businesses" element={<Businesses />} />
            <Route path="payments" element={<Payments />} />
            <Route path="plans" element={<Plans />} />
            <Route path="config" element={<Config />} />
            <Route path="announcements" element={<Announcements />} />
            <Route path="support" element={<Support />} />
            <Route path="ai" element={<AiUsage />} />
            <Route path="audit" element={<Audit />} />
            {market && <>
              <Route path="fapshi" element={<FapshiAdmin />} />
              <Route path="market" element={<MarketOverview />} />
              <Route path="stores" element={<StoresAdmin />} />
              <Route path="listings" element={<ListingsAdmin />} />
              <Route path="reports" element={<ReportsAdmin />} />
              <Route path="orders" element={<OrdersAdmin />} />
              <Route path="settlements" element={<SettlementsAdmin />} />
            </>}
          </Routes>
        </div>
      </main>
    </div>
  );
}

function Overview() {
  const { t, lang } = useI18n();
  const q = useRpc<any>('admin_stats', {}, { refetchInterval: 30_000 });
  const market = Boolean(useMarketConfig().data);
  if (q.isLoading) return <PageLoader />;
  if (q.error) return <ErrorState error={q.error} />;
  const s = q.data;
  return (
    <div>
      <PageHeader title={t('admin.nav.overview')} />
      <div className="grid grid-cols-2 gap-4 lg:grid-cols-4">
        <StatCard label={t('admin.stats.businesses')} value={formatNumber(s.businesses, lang)} hint={t('admin.stats.new30', { n: s.businesses_30d })} />
        <StatCard label={t('admin.stats.users')} value={formatNumber(s.users, lang)} />
        <StatCard label={t('admin.stats.paid')} value={formatNumber(s.active_paid, lang)} hint={t('admin.stats.trials', { n: s.trials })} />
        <StatCard label={t('admin.stats.revenue30')} value={formatMoney(s.verified_revenue_30d, lang)} tone="amber" />
        {market && <FapshiTodayStat />}
        <StatCard label={t('admin.stats.pending')} value={s.pending_payments} tone="red" to="/admin/payments" />
        <StatCard label={t('admin.stats.support')} value={s.open_support} tone="blue" to="/admin/support" />
        <StatCard label={t('admin.stats.ai30')} value={s.ai_queries_30d} hint={t('admin.stats.aiFail', { n: s.ai_failures_30d })} tone="purple" to="/admin/ai" />
        <StatCard label={t('admin.stats.sales30')} value={formatNumber(s.sales_30d, lang)} hint={t('admin.stats.usageOnly')} />
      </div>
      <Card className="mt-4"><CardHeader title={t('admin.stats.byPlan')} />
        <div className="flex flex-wrap gap-3">{Object.entries(s.plans ?? {}).map(([k, v]) => <Badge key={k} tone="gray">{k}: {String(v)}</Badge>)}</div></Card>
    </div>
  );
}

function Businesses() {
  const { t, lang } = useI18n();
  const [q, setQ] = useState('');
  const [search, setSearch] = useState('');
  const [edit, setEdit] = useState<any | null>(null);
  const { run } = useAction();
  const list = useRpc<any[]>('admin_list_businesses', { p_search: search || null, p_limit: 100, p_offset: 0 });
  return (
    <div>
      <PageHeader title={t('admin.nav.businesses')} subtitle={t('admin.businessesSub')} />
      <Card>
        <form className="mb-4 flex gap-2" onSubmit={(e) => { e.preventDefault(); setSearch(q.trim()); }}>
          <Input className="max-w-sm" placeholder={t('admin.searchBusinesses')} value={q} onChange={(e) => setQ(e.target.value)} /><Button type="submit">{t('common.search')}</Button>
        </form>
        {list.isLoading ? <PageLoader /> : (
          <DataTable rows={list.data ?? []} rowKey={(r) => r.id} columns={[
            { key: 'n', header: t('common.name'), render: (b) => <div><p className="font-semibold">{b.name}</p><p className="text-xs text-ink-muted">{b.owner_email} · {t(`businessCategories.${b.category}`)}</p></div> },
            { key: 's', header: t('admin.subscription'), render: (b) => <div><Badge tone={b.subscription.effective_plan === 'free' ? 'gray' : 'green'}>{b.subscription.plan_code} · {t(`subscriptionState.${b.subscription.state}`)}</Badge>
              {b.subscription.payment_pending && <Badge tone="amber" className="ml-1">{t('billing.paymentPending')}</Badge>}</div> },
            { key: 'u', header: t('admin.usage'), hideOnMobile: true, render: (b) => <span className="text-xs">{t('admin.usageLine', { m: b.members, p: b.products, s: b.sales_count })}</span> },
            { key: 'c', header: t('common.created'), hideOnMobile: true, render: (b) => formatDate(b.created_at, lang) },
            { key: 'a', header: '', align: 'right', render: (b) => <div className="flex justify-end gap-1">
              {b.support_access && <Button size="sm" variant="outline" onClick={() => run(() => rpc('admin_open_support_session', { p_business: b.id, p_reason: 'Support request' }), t('admin.sessionLogged'))}>{t('admin.openSupport')}</Button>}
              <Button size="sm" variant="ghost" onClick={() => setEdit(b)}>{t('admin.manageSub')}</Button></div> },
          ]} />
        )}
      </Card>
      {edit && <SubscriptionModal business={edit} onClose={() => setEdit(null)} />}
    </div>
  );
}

function SubscriptionModal({ business, onClose }: { business: any; onClose: () => void }) {
  const { t } = useI18n();
  const { run, busy } = useAction();
  const plans = useQuery({ queryKey: ['admin-plans'], queryFn: async () => unwrap(await supabase.from('plans').select('code,name_en').order('sort')) as any[] });
  const s = business.subscription;
  const [f, setF] = useState({ plan_code: s.plan_code, status: s.status ?? 'active', current_period_end: s.current_period_end?.slice(0, 10) ?? '', trial_ends_at: s.trial_ends_at?.slice(0, 10) ?? '', reason: '' });
  const submit = async () => {
    const ok = await run(() => rpc('admin_set_subscription', { p_business: business.id, p: { ...f, current_period_end: f.current_period_end ? `${f.current_period_end}T23:59:59+01:00` : '', trial_ends_at: f.trial_ends_at ? `${f.trial_ends_at}T23:59:59+01:00` : '' } }), t('common.saved'));
    if (ok !== undefined) onClose();
  };
  return (
    <Modal open onClose={onClose} title={`${t('admin.manageSub')} — ${business.name}`} footer={<><Button variant="outline" onClick={onClose}>{t('common.cancel')}</Button><Button loading={busy} disabled={!f.reason.trim()} onClick={submit}>{t('common.save')}</Button></>}>
      <div className="grid gap-3 sm:grid-cols-2">
        <Alert tone="amber">{t('admin.manualOverrideNote')}</Alert>
        <span />
        <Field label={t('billing.plan')}><Select value={f.plan_code} onChange={(e) => setF({ ...f, plan_code: e.target.value })}>{(plans.data ?? []).map((p) => <option key={p.code} value={p.code}>{p.name_en}</option>)}</Select></Field>
        <Field label={t('common.status')}><Select value={f.status} onChange={(e) => setF({ ...f, status: e.target.value })}>{['trialing', 'active', 'cancelled', 'suspended'].map((x) => <option key={x} value={x}>{x}</option>)}</Select></Field>
        <Field label={t('billing.periodEnds')}><Input type="date" value={f.current_period_end} onChange={(e) => setF({ ...f, current_period_end: e.target.value })} /></Field>
        <Field label={t('billing.trialEnds')}><Input type="date" value={f.trial_ends_at} onChange={(e) => setF({ ...f, trial_ends_at: e.target.value })} /></Field>
        <Field label={t('common.reason')} required className="sm:col-span-2"><Textarea rows={2} value={f.reason} onChange={(e) => setF({ ...f, reason: e.target.value })} /></Field>
      </div>
    </Modal>
  );
}

function Payments() {
  const { t, lang } = useI18n();
  const [status, setStatus] = useState('pending');
  const [review, setReview] = useState<{ p: any; approve: boolean } | null>(null);
  const q = useQuery({
    queryKey: ['admin-payments', status],
    queryFn: async () => unwrap(await supabase.from('billing_payments').select('*, businesses(name), plans(name_en, name_fr)').eq('status', status).order('submitted_at', { ascending: status === 'pending' }).limit(200)) as any[],
  });
  return (
    <div>
      <PageHeader title={t('admin.nav.payments')} subtitle={t('admin.paymentsSub')} actions={<Select value={status} onChange={(e) => setStatus(e.target.value)}>{['pending', 'verified', 'rejected'].map((s) => <option key={s} value={s}>{t(`billing.paymentStatus.${s}`)}</option>)}</Select>} />
      <Card>
        {q.isLoading ? <PageLoader /> : (
          <DataTable rows={q.data ?? []} rowKey={(r) => r.id} empty={<p className="py-8 text-center text-sm text-ink-muted">{t('common.noData')}</p>} columns={[
            { key: 'd', header: t('common.date'), render: (r) => formatDateTime(r.submitted_at, lang) },
            { key: 'b', header: t('admin.business'), render: (r) => <span className="font-semibold">{r.businesses?.name}</span> },
            { key: 'p', header: t('billing.plan'), render: (r) => `${(lang === 'fr' ? r.plans?.name_fr : r.plans?.name_en) ?? r.plan_code} · ${t(`site.pricing.${r.billing_period}`)}` },
            { key: 'm', header: t('common.method'), render: (r) => <div><p>{t(`methods.${r.method}`)}</p><p className="font-mono text-xs">{r.transaction_ref}</p><p className="text-xs text-ink-muted">{[r.payer_name, r.payer_phone].filter(Boolean).join(' · ')}</p></div> },
            { key: 'a', header: t('common.amount'), align: 'right', render: (r) => <div><p className="font-semibold">{formatMoney(r.amount, lang)}</p>{Number(r.amount) !== Number(r.expected_amount) && <Badge tone="red">{t('admin.expected', { amount: formatMoney(r.expected_amount, lang) })}</Badge>}</div> },
            { key: 'x', header: '', align: 'right', render: (r) => <div className="flex justify-end gap-1">
              {r.proof_path && <Button size="sm" variant="ghost" onClick={() => openFile(r.proof_path)}>{t('admin.proof')}</Button>}
              {r.status === 'pending' ? <><Button size="sm" variant="outline" onClick={() => setReview({ p: r, approve: false })}>{t('admin.reject')}</Button><Button size="sm" onClick={() => setReview({ p: r, approve: true })}>{t('admin.verify')}</Button></>
                : <span className="text-xs text-ink-muted">{r.review_note}</span>}</div> },
          ]} />
        )}
      </Card>
      {review && <ReviewModal {...review} onClose={() => setReview(null)} />}
    </div>
  );
}

function ReviewModal({ p, approve, onClose }: { p: any; approve: boolean; onClose: () => void }) {
  const { t, lang } = useI18n();
  const { run, busy } = useAction();
  const [note, setNote] = useState('');
  const [checked, setChecked] = useState(false);
  const submit = async () => {
    const ok = await run(() => rpc('admin_review_billing_payment', { p_payment: p.id, p_approve: approve, p_note: note || null }), t('common.saved'));
    if (ok) onClose();
  };
  return (
    <Modal open onClose={onClose} title={approve ? t('admin.verifyTitle') : t('admin.rejectTitle')} footer={<><Button variant="outline" onClick={onClose}>{t('common.cancel')}</Button>
      <Button variant={approve ? 'primary' : 'danger'} loading={busy} disabled={approve ? !checked : !note.trim()} onClick={submit}>{approve ? t('admin.verify') : t('admin.reject')}</Button></>}>
      <div className="space-y-3 text-sm">
        <p>{p.businesses?.name} · {formatMoney(p.amount, lang)} · {t(`methods.${p.method}`)} · <span className="font-mono">{p.transaction_ref}</span></p>
        {approve && <Checkbox checked={checked} onChange={setChecked} label={t('admin.verifyConfirm')} hint={t('admin.verifyHint')} />}
        <Field label={approve ? t('common.notes') : t('common.reason')} required={!approve}><Textarea rows={2} value={note} onChange={(e) => setNote(e.target.value)} /></Field>
      </div>
    </Modal>
  );
}

function Plans() {
  const { t } = useI18n();
  const { run, busy } = useAction();
  const q = useQuery({ queryKey: ['admin-plans-full'], queryFn: async () => unwrap(await supabase.from('plans').select('*').order('sort')) as any[] });
  const [edit, setEdit] = useState<any | null>(null);
  const save = async () => {
    const ok = await run(() => rpc('admin_upsert_plan', { p: { ...edit, price_monthly: toNumber(edit.price_monthly), price_annual: edit.price_annual === '' ? null : toNumber(edit.price_annual),
      limits: Object.fromEntries(LIMITS.map((k) => [k, edit.limits[k] === '' || edit.limits[k] == null ? null : toNumber(edit.limits[k])])) } }), t('common.saved'));
    if (ok !== undefined) setEdit(null);
  };
  return (
    <div>
      <PageHeader title={t('admin.nav.plans')} subtitle={t('admin.plansSub')} actions={<Button onClick={() => setEdit({ code: '', name_en: '', name_fr: '', description_en: '', description_fr: '', price_monthly: 0, price_annual: '', features: [], limits: {}, is_public: true, active: true, highlight: false, sort: 10 })}>{t('admin.newPlan')}</Button>} />
      {q.isLoading ? <PageLoader /> : (
        <div className="grid gap-4 md:grid-cols-3">
          {(q.data ?? []).map((p) => (
            <Card key={p.code}>
              <div className="flex items-start justify-between"><div><p className="text-lg font-extrabold">{p.name_en}</p><p className="text-xs text-ink-muted">{p.code}</p></div>{!p.active && <Badge>{t('common.archived')}</Badge>}</div>
              <p className="mt-2 text-xl font-bold">{formatMoney(p.price_monthly, 'en')} <span className="text-sm font-normal text-ink-muted">/ {formatMoney(p.price_annual, 'en')}</span></p>
              <p className="mt-2 text-xs text-ink-muted">{LIMITS.map((k) => `${k}: ${p.limits[k] ?? '∞'}`).join(' · ')}</p>
              <p className="mt-2 text-xs">{p.features.join(', ')}</p>
              <Button size="sm" variant="outline" className="mt-3" onClick={() => setEdit({ ...p, price_annual: p.price_annual ?? '' })}>{t('common.edit')}</Button>
            </Card>
          ))}
        </div>
      )}
      {edit && (
        <Modal open onClose={() => setEdit(null)} size="lg" title={edit.code || t('admin.newPlan')} footer={<><Button variant="outline" onClick={() => setEdit(null)}>{t('common.cancel')}</Button><Button loading={busy} onClick={save}>{t('common.save')}</Button></>}>
          <div className="grid gap-3 sm:grid-cols-2">
            <Field label="Code"><Input value={edit.code} onChange={(e) => setEdit({ ...edit, code: e.target.value })} /></Field>
            <Field label={t('admin.sort')}><Input type="number" value={edit.sort} onChange={(e) => setEdit({ ...edit, sort: toNumber(e.target.value) })} /></Field>
            <Field label="Name (EN)"><Input value={edit.name_en} onChange={(e) => setEdit({ ...edit, name_en: e.target.value })} /></Field>
            <Field label="Nom (FR)"><Input value={edit.name_fr} onChange={(e) => setEdit({ ...edit, name_fr: e.target.value })} /></Field>
            <Field label="Description (EN)"><Input value={edit.description_en ?? ''} onChange={(e) => setEdit({ ...edit, description_en: e.target.value })} /></Field>
            <Field label="Description (FR)"><Input value={edit.description_fr ?? ''} onChange={(e) => setEdit({ ...edit, description_fr: e.target.value })} /></Field>
            <Field label={t('admin.priceMonthly')}><Input type="number" value={edit.price_monthly} onChange={(e) => setEdit({ ...edit, price_monthly: e.target.value })} suffix="FCFA" /></Field>
            <Field label={t('admin.priceAnnual')}><Input type="number" value={edit.price_annual} onChange={(e) => setEdit({ ...edit, price_annual: e.target.value })} suffix="FCFA" /></Field>
            {LIMITS.map((k) => <Field key={k} label={k} hint={t('admin.emptyUnlimited')}><Input type="number" value={edit.limits[k] ?? ''} onChange={(e) => setEdit({ ...edit, limits: { ...edit.limits, [k]: e.target.value } })} /></Field>)}
            <div className="sm:col-span-2 grid grid-cols-2 gap-2">{FEATURES.map((f) => <Checkbox key={f} label={t(`features.${f}`)} checked={edit.features.includes(f)} onChange={(v) => setEdit({ ...edit, features: v ? [...edit.features, f] : edit.features.filter((x: string) => x !== f) })} />)}</div>
            <Checkbox label={t('admin.public')} checked={edit.is_public} onChange={(v) => setEdit({ ...edit, is_public: v })} />
            <Checkbox label={t('common.active')} checked={edit.active} onChange={(v) => setEdit({ ...edit, active: v })} />
            <Checkbox label={t('admin.highlight')} checked={edit.highlight} onChange={(v) => setEdit({ ...edit, highlight: v })} />
          </div>
        </Modal>
      )}
    </div>
  );
}

function Config() {
  const { t } = useI18n();
  const { run, busy } = useAction();
  const q = useQuery({ queryKey: ['admin-config'], queryFn: async () => unwrap(await supabase.from('app_config').select('*').neq('key', 'fapshi_direct_pay').order('key')) as any[] });
  const [vals, setVals] = useState<Record<string, string>>({});
  const [adminEmail, setAdminEmail] = useState('');
  useEffect(() => { if (q.data) setVals(Object.fromEntries(q.data.map((r) => [r.key, JSON.stringify(r.value, null, 2)]))); }, [q.data]);
  if (q.isLoading) return <PageLoader />;
  const save = async (key: string) => {
    let parsed: unknown;
    try { parsed = JSON.parse(vals[key]); } catch { return run(async () => { throw new Error('invalid_input'); }); }
    await run(() => rpc('admin_set_config', { p_key: key, p_value: parsed }), t('common.saved'));
  };
  return (
    <div>
      <PageHeader title={t('admin.nav.config')} subtitle={t('admin.configSub')} />
      <div className="grid gap-4 lg:grid-cols-2">
        {(q.data ?? []).map((r) => (
          <Card key={r.key}>
            <CardHeader title={r.key} subtitle={t(`admin.configHelp.${r.key}`)} action={<Button size="sm" loading={busy} onClick={() => save(r.key)}>{t('common.save')}</Button>} />
            <Textarea rows={6} className="font-mono text-xs" value={vals[r.key] ?? ''} onChange={(e) => setVals((v) => ({ ...v, [r.key]: e.target.value }))} />
          </Card>
        ))}
        <Card>
          <CardHeader title={t('admin.addAdmin')} subtitle={t('admin.addAdminSub')} />
          <div className="flex gap-2"><Input type="email" value={adminEmail} onChange={(e) => setAdminEmail(e.target.value)} /><Button loading={busy} onClick={() => run(() => rpc('admin_add_platform_admin', { p_email: adminEmail }), t('common.saved'))}>{t('common.add')}</Button></div>
        </Card>
      </div>
    </div>
  );
}

function Announcements() {
  const { t, lang } = useI18n();
  const { run, busy } = useAction();
  const q = useQuery({ queryKey: ['admin-ann'], queryFn: async () => unwrap(await supabase.from('announcements').select('*').order('created_at', { ascending: false })) as any[] });
  const empty = { title_en: '', title_fr: '', body_en: '', body_fr: '', level: 'info', ends_at: '', active: true };
  const [f, setF] = useState<any>(empty);
  const save = async () => { const ok = await run(() => rpc('admin_save_announcement', { p: f }), t('common.saved')); if (ok) setF(empty); };
  return (
    <div>
      <PageHeader title={t('admin.nav.announcements')} />
      <div className="grid gap-4 lg:grid-cols-2">
        <Card>
          <CardHeader title={f.id ? t('common.edit') : t('admin.newAnnouncement')} />
          <div className="grid gap-3 sm:grid-cols-2">
            <Field label="Title (EN)"><Input value={f.title_en} onChange={(e) => setF({ ...f, title_en: e.target.value })} /></Field>
            <Field label="Titre (FR)"><Input value={f.title_fr} onChange={(e) => setF({ ...f, title_fr: e.target.value })} /></Field>
            <Field label="Body (EN)"><Textarea rows={2} value={f.body_en ?? ''} onChange={(e) => setF({ ...f, body_en: e.target.value })} /></Field>
            <Field label="Texte (FR)"><Textarea rows={2} value={f.body_fr ?? ''} onChange={(e) => setF({ ...f, body_fr: e.target.value })} /></Field>
            <Field label={t('admin.level')}><Select value={f.level} onChange={(e) => setF({ ...f, level: e.target.value })}>{['info', 'warning', 'maintenance'].map((l) => <option key={l} value={l}>{l}</option>)}</Select></Field>
            <Field label={t('admin.endsAt')}><Input type="datetime-local" value={f.ends_at ?? ''} onChange={(e) => setF({ ...f, ends_at: e.target.value })} /></Field>
            <Checkbox label={t('common.active')} checked={f.active} onChange={(v) => setF({ ...f, active: v })} />
          </div>
          <div className="mt-4 flex justify-end"><Button loading={busy} disabled={!f.title_en || !f.title_fr} onClick={save}>{t('common.save')}</Button></div>
        </Card>
        <Card>
          <CardHeader title={t('admin.nav.announcements')} />
          <ul className="space-y-2 text-sm">{(q.data ?? []).map((a) => (
            <li key={a.id} className="flex items-start justify-between gap-2 rounded-lg border border-gray-100 p-2 dark:border-gray-800">
              <div><p className="font-semibold">{lang === 'fr' ? a.title_fr : a.title_en} <Badge tone={a.active ? 'green' : 'gray'}>{a.level}</Badge></p><p className="text-xs text-ink-muted">{formatDateTime(a.created_at, lang)}{a.ends_at ? ` → ${formatDateTime(a.ends_at, lang)}` : ''}</p></div>
              <Button size="sm" variant="ghost" onClick={() => setF({ ...a, ends_at: a.ends_at ? a.ends_at.slice(0, 16) : '' })}>{t('common.edit')}</Button>
            </li>))}</ul>
        </Card>
      </div>
    </div>
  );
}

function Support() {
  const { t, lang } = useI18n();
  const { run, busy } = useAction();
  const [status, setStatus] = useState('open');
  const [reply, setReply] = useState<Record<string, string>>({});
  const q = useQuery({ queryKey: ['admin-support', status], queryFn: async () => unwrap(await supabase.from('support_requests').select('*, businesses(name)').eq('status', status).order('created_at', { ascending: false }).limit(200)) as any[] });
  return (
    <div>
      <PageHeader title={t('admin.nav.support')} actions={<Select value={status} onChange={(e) => setStatus(e.target.value)}>{['open', 'in_progress', 'resolved', 'closed'].map((s) => <option key={s} value={s}>{t(`help.status.${s}`)}</option>)}</Select>} />
      <div className="space-y-3">
        {(q.data ?? []).length === 0 && <Card><p className="text-center text-sm text-ink-muted">{t('common.noData')}</p></Card>}
        {(q.data ?? []).map((r) => (
          <Card key={r.id}>
            <div className="flex flex-wrap items-start justify-between gap-2">
              <div><p className="font-bold">{r.subject} <Badge>{t(`site.contact.categories.${r.category}`)}</Badge></p>
                <p className="text-xs text-ink-muted">{formatDateTime(r.created_at, lang)} · {r.name ?? ''} {r.email ?? ''} {r.phone ?? ''}{r.businesses?.name ? ` · ${r.businesses.name}` : ''}</p></div>
            </div>
            <p className="mt-2 whitespace-pre-line text-sm">{r.message}</p>
            {r.admin_response && <p className="mt-2 rounded-lg bg-brand-50 p-2 text-sm dark:bg-brand-950/40">{r.admin_response}</p>}
            <div className="mt-3 flex flex-col gap-2 sm:flex-row">
              <Input className="flex-1" placeholder={t('admin.replyPlaceholder')} value={reply[r.id] ?? ''} onChange={(e) => setReply((x) => ({ ...x, [r.id]: e.target.value }))} />
              {['in_progress', 'resolved', 'closed'].map((s) => <Button key={s} size="sm" variant="outline" loading={busy} onClick={() => run(() => rpc('admin_respond_support', { p_request: r.id, p_status: s, p_response: reply[r.id] ?? null }), t('common.saved'))}>{t(`help.status.${s}`)}</Button>)}
            </div>
            <p className="mt-1 text-xs text-ink-muted">{t('admin.replyNote')}</p>
          </Card>
        ))}
      </div>
    </div>
  );
}

function AiUsage() {
  const { t } = useI18n();
  const q = useRpc<any[]>('admin_ai_usage', {});
  return (
    <div>
      <PageHeader title={t('admin.nav.ai')} subtitle={t('admin.aiSub')} />
      <Card>
        {q.isLoading ? <PageLoader /> : (
          <DataTable rows={q.data ?? []} rowKey={(r) => r.day} empty={<p className="py-8 text-center text-sm text-ink-muted">{t('common.noData')}</p>} columns={[
            { key: 'd', header: t('common.date'), render: (r) => r.day },
            { key: 'q', header: t('admin.ai.queries'), align: 'right', render: (r) => r.queries },
            { key: 'c', header: t('admin.ai.completed'), align: 'right', render: (r) => r.completed },
            { key: 'f', header: t('admin.ai.failed'), align: 'right', render: (r) => r.failed },
            { key: 'fb', header: t('admin.ai.fallback'), align: 'right', render: (r) => r.fallback },
            { key: 'i', header: t('admin.ai.tokens'), align: 'right', render: (r) => `${r.input_tokens} / ${r.output_tokens}` },
            { key: 'b', header: t('admin.ai.businesses'), align: 'right', render: (r) => r.businesses },
          ]} />
        )}
      </Card>
    </div>
  );
}

function Audit() {
  const { t, lang } = useI18n();
  const q = useQuery({ queryKey: ['admin-audit'], queryFn: async () => unwrap(await supabase.from('audit_logs').select('*').or('action.like.admin.%,action.like.billing.%,action.like.platform.%,action.like.support_access.%').order('created_at', { ascending: false }).limit(300)) as any[] });
  return (
    <div>
      <PageHeader title={t('admin.nav.audit')} subtitle={t('admin.auditSub')} />
      <Card>
        {q.isLoading ? <PageLoader /> : (
          <DataTable dense rows={q.data ?? []} rowKey={(r) => String(r.id)} columns={[
            { key: 'd', header: t('common.date'), render: (r) => formatDateTime(r.created_at, lang) },
            { key: 'a', header: t('settings.action'), render: (r) => <span className="font-mono text-xs">{r.action}</span> },
            { key: 'e', header: t('common.reference'), render: (r) => <span className="font-mono text-xs">{r.entity} {r.entity_id?.slice(0, 8)}</span> },
            { key: 'x', header: t('common.details'), render: (r) => <span className="block max-w-md truncate font-mono text-xs text-ink-muted">{r.details ? JSON.stringify(r.details) : ''}</span> },
          ]} />
        )}
      </Card>
    </div>
  );
}
