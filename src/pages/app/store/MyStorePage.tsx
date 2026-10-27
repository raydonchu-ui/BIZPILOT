import { FormEvent, useEffect, useState } from 'react';
import { Link, useSearchParams } from 'react-router-dom';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import clsx from 'clsx';
import { BadgeCheck, CheckCircle2, Circle, ExternalLink, Plus, Store, Trash2 } from 'lucide-react';
import { useI18n } from '../../../i18n';
import { useBiz } from '../../../lib/business';
import { rpc, unwrap } from '../../../lib/api';
import { supabase } from '../../../lib/supabase';
import { useAction } from '../../../lib/useAction';
import { errorKey } from '../../../lib/errors';
import { formatDate, formatMoney } from '../../../lib/format';
import { storeUrl, useMarketConfig } from '../../../lib/market';
import { useAuth } from '../../../lib/auth';
import { PictureEditor } from '../../../components/PictureEditor';
import { ShareBar, Stars } from '../../../components/market';
import { DeliveryAreaPicker } from '../../../components/DeliveryAreaPicker';
import { VerificationPanel } from './VerificationPanel';
import { Alert, Badge, Button, Card, CardHeader, Checkbox, EmptyState, ErrorState, Field, Input, PageHeader, PageLoader, Tabs, Textarea, UpgradeNotice } from '../../../components/ui';

type Tab = 'profile' | 'contact' | 'delivery' | 'payments' | 'appearance' | 'reviews' | 'verification';
const DAYS = ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'] as const;

export function useStoreRow(id: string, enabled = true) {
  return useQuery({
    queryKey: ['store-row', id], enabled,
    queryFn: async () => (unwrap(await supabase.from('stores').select('*').eq('business_id', id).maybeSingle()) as any) ?? null,
  });
}
export function useReadiness(id: string, enabled = true) {
  return useQuery({ queryKey: ['store-readiness', id], enabled, queryFn: () => rpc<any>('store_readiness', { p_business: id }) });
}

export default function MyStorePage() {
  const { t } = useI18n();
  const { id, biz, can } = useBiz();
  const cfg = useMarketConfig();
  const [params, setParams] = useSearchParams();
  const tab = (params.get('tab') as Tab) ?? 'profile';
  const store = useStoreRow(id, Boolean(cfg.data));
  const ready = useReadiness(id, Boolean(cfg.data));
  const { run, busy } = useAction();
  if (cfg.isLoading) return <PageLoader />;
  if (!cfg.data) {
    return (
      <div className="mx-auto max-w-3xl">
        <PageHeader title={t('nav.myStore')} />
        <Alert tone="blue" title={t('seller.store.upgradeTitle')}>{t('seller.store.upgradeBody')}</Alert>
      </div>
    );
  }
  if (!can('store.manage')) return <ErrorState error={{ message: 'permission_denied' }} />;
  if (store.isLoading || ready.isLoading) return <PageLoader />;
  if (store.error) return <ErrorState error={store.error} onRetry={() => store.refetch()} />;
  const s = store.data;
  if (!s) {
    return (
      <div className="mx-auto max-w-3xl">
        <PageHeader title={t('nav.myStore')} subtitle={t('seller.store.introSub')} />
        <Card className="py-6">
          <EmptyState icon={<Store className="h-6 w-6" />} title={t('seller.store.introTitle', { name: biz.name })} body={t('seller.store.introBody')}
            action={<Button size="lg" loading={busy} onClick={() => run(() => rpc('store_save', { p_business: id, p: {} }), t('seller.store.created'))}>{t('seller.store.create')}</Button>} />
          <ol className="mx-auto mt-2 grid max-w-xl gap-2 text-sm sm:grid-cols-2">
            {(['step1', 'step2', 'step3', 'step4'] as const).map((k, i) => <li key={k} className="flex gap-2 rounded-xl bg-gray-50 p-3 dark:bg-gray-800/60"><b className="text-brand-700">{i + 1}.</b>{t(`seller.store.${k}`)}</li>)}
          </ol>
        </Card>
      </div>
    );
  }
  const r = ready.data ?? {};
  const url = storeUrl(s.slug);
  const setTab = (v: Tab) => setParams({ tab: v }, { replace: true });
  return (
    <div>
      <PageHeader title={s.name} subtitle={<span className="flex flex-wrap items-center gap-2">
          <StoreStatus status={s.status} />
          {s.verification === 'verified' && <Badge tone="green"><BadgeCheck className="h-3.5 w-3.5" />{t('market.verified')}</Badge>}
          <a href={url} target="_blank" rel="noopener noreferrer" className="inline-flex items-center gap-1 text-brand-700 hover:underline">{url.replace(/^https?:\/\//, '')}<ExternalLink className="h-3.5 w-3.5" /></a>
        </span>}
        actions={<>
          <a href={`/s/${s.slug}`} target="_blank" rel="noopener noreferrer" className="inline-flex h-10 items-center gap-2 rounded-lg border border-gray-300 px-4 text-sm font-semibold dark:border-gray-700"><ExternalLink className="h-4 w-4" />{t('seller.store.preview')}</a>
          {s.status === 'published'
            ? <Button variant="outline" loading={busy} onClick={() => run(() => rpc('store_set_published', { p_business: id, p_publish: false }), t('seller.store.unpublished'))}>{t('seller.store.unpublish')}</Button>
            : s.status !== 'suspended' && <PublishButton id={id} />}
        </>} />

      {s.status === 'suspended' && <div className="mb-4"><Alert tone="red" title={t('seller.store.suspendedTitle')}>{t('seller.store.suspendedBody', { reason: s.suspended_reason ?? '' })}</Alert></div>}

      <div className="grid gap-4 lg:grid-cols-3">
        {!(r.published && r.logo) && <Card className="lg:col-span-2">
          <CardHeader title={t('seller.store.checklist')} subtitle={t('seller.store.checklistSub')} />
          <ul className="grid gap-2 sm:grid-cols-2">
            <Step done={r.profile} label={t('seller.store.checkProfile')} action={() => setTab('contact')} />
            <Step done={r.logo} label={t('seller.store.checkLogo')} optional action={() => setTab('profile')} />
            <Step done={r.products} label={t('seller.store.checkProducts', { n: r.listed ?? 0 })} link="/app/products?filter=online" />
            <Step done={r.delivery} label={t('seller.store.checkDelivery')} action={() => setTab('delivery')} />
            <Step done={r.payment} label={t('seller.store.checkPayment')} action={() => setTab('payments')} />
            <Step done={r.published} label={t('seller.store.checkPublished')} />
          </ul>
          {!r.products && <p className="mt-3 text-sm text-ink-muted">{t('seller.store.howToList')} <Link to="/app/products" className="font-semibold text-brand-700 hover:underline">{t('nav.products')}</Link></p>}
        </Card>}
        <Card className={r.published && r.logo ? 'lg:col-span-3' : ''}>
          <CardHeader title={t('seller.store.share')} subtitle={s.status === 'published' ? t('seller.store.shareSub') : t('seller.store.shareDraft')} />
          <ShareBar url={url} text={t('market.shareStoreText', { store: s.name })} />
        </Card>
      </div>

      <Tabs className="mt-6" value={tab} onChange={setTab} items={[
        { value: 'profile', label: t('seller.store.tabProfile') }, { value: 'contact', label: t('seller.store.tabContact') },
        { value: 'delivery', label: t('seller.store.tabDelivery') }, { value: 'payments', label: t('seller.store.tabPayments') },
        { value: 'appearance', label: t('seller.store.tabAppearance') }, { value: 'reviews', label: t('seller.store.tabReviews') },
        { value: 'verification', label: t('premium.verify.tabLabel') },
      ]} />
      <div className="mt-4">
        {tab === 'profile' && <ProfileTab s={s} />}
        {tab === 'contact' && <ContactTab s={s} />}
        {tab === 'delivery' && <DeliveryTab s={s} />}
        {tab === 'payments' && <PaymentsTab s={s} />}
        {tab === 'appearance' && <AppearanceTab s={s} />}
        {tab === 'reviews' && <ReviewsTab />}
        {tab === 'verification' && <VerificationPanel />}
      </div>
    </div>
  );
}

function StoreStatus({ status }: { status: string }) {
  const { t } = useI18n();
  return <Badge tone={status === 'published' ? 'green' : status === 'suspended' ? 'red' : 'amber'}>{t(`seller.store.status.${status}`)}</Badge>;
}

function PublishButton({ id }: { id: string }) {
  const { t } = useI18n();
  const { run, busy } = useAction();
  const [missing, setMissing] = useState<string[] | null>(null);
  const publish = async () => {
    try {
      await rpc('store_set_published', { p_business: id, p_publish: true });
      setMissing(null);
      await run(async () => null, t('seller.store.publishedToast'));
    } catch (e) {
      const { raw, params } = errorKey(e);
      if (raw === 'store_not_ready' && params) setMissing(['profile', 'products', 'payment', 'delivery'].filter((k) => !(params as any)[k]));
      else await run(async () => { throw e; });
    }
  };
  return (
    <div className="relative">
      <Button loading={busy} onClick={publish}>{t('seller.store.publish')}</Button>
      {missing && <div className="absolute right-0 z-10 mt-2 w-72 rounded-xl border border-amber-200 bg-amber-50 p-3 text-sm text-amber-900 shadow-lg">
        <p className="font-semibold">{t('seller.store.notReady')}</p>
        <ul className="mt-1 list-disc pl-5">{missing.map((m) => <li key={m}>{t(`seller.store.missing.${m}`)}</li>)}</ul>
      </div>}
    </div>
  );
}

function Step({ done, label, action, link, optional }: { done?: boolean; label: string; action?: () => void; link?: string; optional?: boolean }) {
  const { t } = useI18n();
  const body = <span className="flex items-center gap-2">{done ? <CheckCircle2 className="h-5 w-5 shrink-0 text-brand-600" /> : <Circle className="h-5 w-5 shrink-0 text-gray-300" />}
    <span className={clsx('text-sm', done && 'text-ink-muted line-through')}>{label}{optional && <span className="ml-1 text-xs text-ink-muted">({t('catalog.optional')})</span>}</span></span>;
  return (
    <li className="rounded-xl border border-gray-200 px-3 py-2.5 dark:border-gray-800">
      {link ? <Link to={link} className="block hover:underline">{body}</Link> : action && !done ? <button type="button" onClick={action} className="block w-full text-left hover:underline">{body}</button> : body}
    </li>
  );
}

function useSave(id: string) {
  const { t } = useI18n();
  const { run, busy } = useAction();
  const qc = useQueryClient();
  const save = async (p: Record<string, unknown>) => {
    const r = await run(() => rpc('store_save', { p_business: id, p }), t('common.saved'));
    qc.invalidateQueries({ queryKey: ['store-row', id] });
    return r;
  };
  return { save, busy };
}

function ProfileTab({ s }: { s: any }) {
  const { session } = useAuth();
  const { t } = useI18n();
  const { id } = useBiz();
  const { save, busy } = useSave(id);
  const [f, setF] = useState({ name: s.name, slug: s.slug, tagline: s.tagline ?? '', description: s.description ?? '', city: s.city ?? '', region: s.region ?? '', address: s.address ?? '', logo_path: s.logo_path as string | null });
  const slugOk = useQuery({
    queryKey: ['slug', f.slug], enabled: f.slug !== s.slug && f.slug.length >= 3,
    queryFn: () => rpc<boolean>('store_slug_available', { p_slug: f.slug, p_business: id }),
  });
  const set = (k: keyof typeof f) => (e: { target: { value: string } }) => setF((x) => ({ ...x, [k]: e.target.value }));
  const submit = (e: FormEvent) => { e.preventDefault(); save(f); };
  return (
    <Card>
      <form onSubmit={submit} className="grid gap-4 sm:grid-cols-2">
        <Field label={t('seller.store.name')} required><Input required minLength={2} maxLength={80} value={f.name} onChange={set('name')} /></Field>
        <Field label={t('seller.store.link')} required hint={f.slug !== s.slug && slugOk.data === false ? <span className="text-red-600">{t('errors.slug_unavailable')}</span> : t('seller.store.linkHint', { url: storeUrl(f.slug) })}>
          <Input required pattern="[a-z0-9][a-z0-9-]{1,38}[a-z0-9]" maxLength={40} value={f.slug} onChange={(e) => setF({ ...f, slug: e.target.value.toLowerCase().replace(/[^a-z0-9-]/g, '-') })} />
        </Field>
        <Field label={t('seller.store.tagline')} optional className="sm:col-span-2"><Input maxLength={120} value={f.tagline} onChange={set('tagline')} placeholder={t('seller.store.taglinePlaceholder')} /></Field>
        <Field label={t('seller.store.description')} optional className="sm:col-span-2"><Textarea rows={4} maxLength={2000} value={f.description} onChange={set('description')} /></Field>
        <Field label={t('market.city')} optional><Input maxLength={80} value={f.city} onChange={set('city')} /></Field>
        <Field label={t('seller.store.region')} optional><Input maxLength={80} value={f.region} onChange={set('region')} /></Field>
        <Field label={t('seller.store.address')} optional className="sm:col-span-2"><Input maxLength={200} value={f.address} onChange={set('address')} /></Field>
        <div className="sm:col-span-2"><PictureEditor kind="logo" ownerId={session!.user.id} folder={`${id}/store`} currentPath={f.logo_path} title={t('seller.store.logo')}
          onSaved={(p) => setF({ ...f, logo_path: p })} onRemove={() => setF({ ...f, logo_path: null })} /></div>
        <div className="sm:col-span-2 flex justify-end"><Button type="submit" loading={busy} disabled={f.slug !== s.slug && slugOk.data === false}>{t('common.save')}</Button></div>
      </form>
    </Card>
  );
}

function ContactTab({ s }: { s: any }) {
  const { t } = useI18n();
  const { id } = useBiz();
  const { save, busy } = useSave(id);
  const [f, setF] = useState({
    phone: s.phone ?? '', whatsapp: s.whatsapp ?? '', email: s.email ?? '', show_phone: s.show_phone, show_whatsapp: s.show_whatsapp,
    show_email: s.show_email, show_address: s.show_address, facebook_url: s.facebook_url ?? '', instagram_url: s.instagram_url ?? '',
    tiktok_url: s.tiktok_url ?? '', hours_note: s.hours_note ?? '', opening_hours: (s.opening_hours ?? {}) as Record<string, { open?: string; close?: string; closed?: boolean }>,
  });
  const set = (k: keyof typeof f) => (e: { target: { value: string } }) => setF((x) => ({ ...x, [k]: e.target.value }));
  const setDay = (d: string, patch: Record<string, unknown>) => setF((x) => ({ ...x, opening_hours: { ...x.opening_hours, [d]: { open: '08:00', close: '18:00', ...x.opening_hours[d], ...patch } } }));
  return (
    <Card>
      <form onSubmit={(e) => { e.preventDefault(); save(f); }} className="space-y-6">
        <div>
          <h3 className="mb-1 font-bold">{t('seller.store.contactTitle')}</h3>
          <p className="mb-3 text-sm text-ink-muted">{t('seller.store.contactSub')}</p>
          <div className="grid gap-4 sm:grid-cols-3">
            <div className="space-y-2"><Field label={t('market.phone')} optional><Input type="tel" value={f.phone} onChange={set('phone')} /></Field>
              <Checkbox label={t('seller.store.showPublic')} checked={f.show_phone} onChange={(v) => setF({ ...f, show_phone: v })} /></div>
            <div className="space-y-2"><Field label="WhatsApp" optional><Input type="tel" value={f.whatsapp} onChange={set('whatsapp')} /></Field>
              <Checkbox label={t('seller.store.showPublic')} checked={f.show_whatsapp} onChange={(v) => setF({ ...f, show_whatsapp: v })} /></div>
            <div className="space-y-2"><Field label={t('market.email')} optional><Input type="email" value={f.email} onChange={set('email')} /></Field>
              <Checkbox label={t('seller.store.showPublic')} checked={f.show_email} onChange={(v) => setF({ ...f, show_email: v })} /></div>
          </div>
          <div className="mt-3"><Checkbox label={t('seller.store.showAddress')} checked={f.show_address} onChange={(v) => setF({ ...f, show_address: v })} /></div>
        </div>
        <div>
          <h3 className="mb-3 font-bold">{t('seller.store.social')}</h3>
          <div className="grid gap-4 sm:grid-cols-3">
            <Field label="Facebook" optional><Input type="url" placeholder="https://facebook.com/…" value={f.facebook_url} onChange={set('facebook_url')} /></Field>
            <Field label="Instagram" optional><Input type="url" placeholder="https://instagram.com/…" value={f.instagram_url} onChange={set('instagram_url')} /></Field>
            <Field label="TikTok" optional><Input type="url" placeholder="https://tiktok.com/@…" value={f.tiktok_url} onChange={set('tiktok_url')} /></Field>
          </div>
        </div>
        <div>
          <h3 className="mb-3 font-bold">{t('market.openingHours')}</h3>
          <div className="space-y-2">
            {DAYS.map((d) => {
              const h = f.opening_hours[d];
              const closed = !h || h.closed;
              return (
                <div key={d} className="flex flex-wrap items-center gap-3">
                  <span className="w-24 text-sm font-semibold">{t(`market.days.${d}`)}</span>
                  <Checkbox label={t('seller.store.openDay')} checked={!closed} onChange={(v) => setDay(d, { closed: !v })} />
                  {!closed && <>
                    <Input type="time" aria-label={t('seller.store.opensAt', { day: t(`market.days.${d}`) })} className="w-32" value={h?.open ?? '08:00'} onChange={(e) => setDay(d, { open: e.target.value })} />
                    <span>–</span>
                    <Input type="time" aria-label={t('seller.store.closesAt', { day: t(`market.days.${d}`) })} className="w-32" value={h?.close ?? '18:00'} onChange={(e) => setDay(d, { close: e.target.value })} />
                  </>}
                </div>
              );
            })}
          </div>
          <Field label={t('seller.store.hoursNote')} optional className="mt-3"><Input maxLength={200} value={f.hours_note} onChange={set('hours_note')} /></Field>
        </div>
        <div className="flex justify-end"><Button type="submit" loading={busy}>{t('common.save')}</Button></div>
      </form>
    </Card>
  );
}

function DeliveryTab({ s }: { s: any }) {
  const { t, lang } = useI18n();
  const { id } = useBiz();
  const { save, busy } = useSave(id);
  const { run, busy: zBusy } = useAction();
  const zones = useQuery({ queryKey: ['zones', id], queryFn: async () => unwrap(await supabase.from('store_delivery_zones').select('*').eq('business_id', id).order('sort')) as any[] });
  const [rows, setRows] = useState<{ id?: string; name: string; fee: string; eta: string; active: boolean; regions: string[]; localities: string[] }[]>([]);
  const [areaError, setAreaError] = useState<string | null>(null);
  useEffect(() => { if (zones.data) setRows(zones.data.map((z) => ({ id: z.id, name: z.name, fee: String(z.fee), eta: z.eta ?? '', active: z.active, regions: z.regions ?? [], localities: z.localities ?? [] }))); }, [zones.data]);
  const [f, setF] = useState({ pickup_enabled: s.pickup_enabled, pickup_note: s.pickup_note ?? '', delivery_note: s.delivery_note ?? '', min_order_amount: String(s.min_order_amount ?? 0) });
  const saveAll = async (e: FormEvent) => {
    e.preventDefault();
    // An active area must say where it delivers: a zone with no region and no town would look like it delivers anywhere.
    const unset = rows.find((r) => r.name.trim() && r.active && r.regions.length === 0 && r.localities.length === 0);
    if (unset) { setAreaError(t('seller.store.areaRequired', { zone: unset.name.trim() })); return; }
    setAreaError(null);
    const ok = await run(() => rpc('store_save_zones', { p_business: id, p_zones: rows.filter((r) => r.name.trim()).map((r) => ({ ...r, fee: Number(r.fee || 0) })) }));
    if (ok !== undefined) await save(f);
  };
  return (
    <Card>
      <form onSubmit={saveAll} className="space-y-6">
        <div>
          <h3 className="mb-1 font-bold">{t('seller.store.zones')}</h3>
          <p className="mb-3 text-sm text-ink-muted">{t('seller.store.zonesSub')}</p>
          <div className="space-y-2">
            {rows.map((r, i) => (
              <div key={r.id ?? `n${i}`} className="space-y-3 rounded-xl border border-gray-200 p-3 dark:border-gray-800">
              <div className="grid items-end gap-2 sm:grid-cols-[2fr_1fr_1.5fr_auto_auto]">
                <Field label={t('seller.store.zoneName')}><Input required value={r.name} onChange={(e) => setRows(rows.map((x, j) => (j === i ? { ...x, name: e.target.value } : x)))} placeholder="Akwa, Bonapriso…" /></Field>
                <Field label={t('seller.store.zoneFee')}><Input type="number" min="0" value={r.fee} onChange={(e) => setRows(rows.map((x, j) => (j === i ? { ...x, fee: e.target.value } : x)))} suffix="FCFA" /></Field>
                <Field label={t('seller.store.zoneEta')} optional><Input maxLength={60} value={r.eta} onChange={(e) => setRows(rows.map((x, j) => (j === i ? { ...x, eta: e.target.value } : x)))} placeholder={t('seller.store.zoneEtaPlaceholder')} /></Field>
                <div className="pb-2"><Checkbox label={t('common.active')} checked={r.active} onChange={(v) => setRows(rows.map((x, j) => (j === i ? { ...x, active: v } : x)))} /></div>
                <Button variant="ghost" aria-label={t('common.delete')} icon={<Trash2 className="h-4 w-4" />} onClick={() => setRows(rows.filter((_, j) => j !== i))} />
              </div>
              <div>
                <p className="mb-2 text-sm font-semibold">{t('seller.store.areaTitle')}</p>
                <DeliveryAreaPicker regions={r.regions} localities={r.localities}
                  onChange={(v) => setRows(rows.map((x, j) => (j === i ? { ...x, regions: v.regions, localities: v.localities } : x)))} />
              </div>
              </div>
            ))}
          </div>
          <Button size="sm" variant="secondary" className="mt-2" icon={<Plus className="h-4 w-4" />} onClick={() => setRows([...rows, { name: '', fee: '', eta: '', active: true, regions: [], localities: [] }])}>{t('seller.store.addZone')}</Button>
        </div>
        <div className="grid gap-4 sm:grid-cols-2">
          <div className="space-y-2 sm:col-span-2">
            <Checkbox label={t('seller.store.pickup')} hint={t('seller.store.pickupHint')} checked={f.pickup_enabled} onChange={(v) => setF({ ...f, pickup_enabled: v })} />
            {f.pickup_enabled && <Field label={t('seller.store.pickupNote')} optional><Input maxLength={300} value={f.pickup_note} onChange={(e) => setF({ ...f, pickup_note: e.target.value })} placeholder={t('seller.store.pickupNotePlaceholder')} /></Field>}
          </div>
          <Field label={t('seller.store.deliveryNote')} optional className="sm:col-span-2" hint={t('seller.store.deliveryNoteHint')}><Textarea maxLength={1000} value={f.delivery_note} onChange={(e) => setF({ ...f, delivery_note: e.target.value })} /></Field>
          <Field label={t('seller.store.minOrder')} optional hint={Number(f.min_order_amount) > 0 ? formatMoney(f.min_order_amount, lang) : t('seller.store.minOrderNone')}><Input type="number" min="0" value={f.min_order_amount} onChange={(e) => setF({ ...f, min_order_amount: e.target.value })} suffix="FCFA" /></Field>
        </div>
        {areaError && <Alert tone="red">{areaError}</Alert>}
        <div className="flex justify-end"><Button type="submit" loading={busy || zBusy}>{t('common.save')}</Button></div>
      </form>
    </Card>
  );
}

/** One Mobile Money account the seller receives on. What is typed here is the seller's own statement, not a provider check. */
function MomoMethod({ label, tone, placeholder, enabled, onEnabled, number, onNumber, name, onName, instructions, onInstructions }: {
  label: string; tone: string; placeholder: string; enabled: boolean; onEnabled: (v: boolean) => void;
  number: string; onNumber: (e: { target: { value: string } }) => void; name: string; onName: (e: { target: { value: string } }) => void;
  instructions: string; onInstructions: (e: { target: { value: string } }) => void;
}) {
  const { t } = useI18n();
  return (
    <div className={clsx('space-y-3 rounded-xl border p-3', enabled ? tone : 'border-gray-200 dark:border-gray-800')}>
      <Checkbox label={label} checked={enabled} onChange={onEnabled} />
      {enabled && (
        <>
          <Field label={t('seller.store.momoNumber')} required><Input type="tel" inputMode="tel" autoComplete="off" placeholder={placeholder} value={number} onChange={onNumber} /></Field>
          <Field label={t('seller.store.momoName')} optional hint={t('seller.store.momoNameHint')}><Input maxLength={80} value={name} onChange={onName} /></Field>
          <Field label={t('seller.store.momoInstructions')} optional hint={t('seller.store.momoInstructionsHint')}>
            <Textarea rows={2} maxLength={300} value={instructions} onChange={onInstructions} />
          </Field>
        </>
      )}
    </div>
  );
}

/** How buyers pay: cash on delivery and/or Mobile Money sent straight to the seller's own number.
 *  BizPilot never collects marketplace payments. Also the store's policies and service area. */
function PaymentsTab({ s }: { s: any }) {
  const { t } = useI18n();
  const { id } = useBiz();
  const { run, busy } = useAction();
  const qc = useQueryClient();
  const [f, setF] = useState({
    cod_enabled: Boolean(s.cod_enabled), momo_direct_enabled: Boolean(s.momo_direct_enabled),
    momo_mtn_number: s.momo_mtn_number ?? '', momo_mtn_name: s.momo_mtn_name ?? '',
    momo_orange_number: s.momo_orange_number ?? '', momo_orange_name: s.momo_orange_name ?? '',
    momo_mtn_enabled: Boolean(s.momo_mtn_enabled), momo_orange_enabled: Boolean(s.momo_orange_enabled),
    momo_mtn_instructions: s.momo_mtn_instructions ?? '', momo_orange_instructions: s.momo_orange_instructions ?? '',
    momo_proof_required: Boolean(s.momo_proof_required),
    payment_note: s.payment_note ?? '', return_policy: s.return_policy ?? '', neighborhood: s.neighborhood ?? '', service_area: s.service_area ?? '',
  });
  const set = (k: keyof typeof f) => (e: { target: { value: string } }) => setF((x) => ({ ...x, [k]: e.target.value }));
  const save = async (e: FormEvent) => {
    e.preventDefault();
    await run(() => rpc('store_save_payments', { p_business: id, p: f }), t('common.saved'));
    qc.invalidateQueries({ queryKey: ['store-row', id] });
  };
  const noNumber = f.momo_direct_enabled && ((f.momo_mtn_enabled && !f.momo_mtn_number.trim()) || (f.momo_orange_enabled && !f.momo_orange_number.trim())
    || (!f.momo_mtn_enabled && !f.momo_orange_enabled));
  return (
    <Card>
      <form onSubmit={save} className="space-y-6">
        <Alert tone="blue" title={t('seller.store.directTitle')}>{t('seller.store.directBody')}</Alert>
        <Checkbox label={t('market.cod')} hint={t('seller.store.codHint')} checked={f.cod_enabled} onChange={(v) => setF({ ...f, cod_enabled: v })} />
        <div>
          <Checkbox label={t('market.momoDirect')} hint={t('seller.store.momoHint')} checked={f.momo_direct_enabled} onChange={(v) => setF({ ...f, momo_direct_enabled: v })} />
          {f.momo_direct_enabled && (
            <div className="mt-3 space-y-4">
              <Alert tone="blue">{t('seller.store.momoVerifyNote')}</Alert>
              <div className="grid gap-4 sm:grid-cols-2">
                <MomoMethod label="MTN Mobile Money" tone="border-yellow-300 dark:border-yellow-700" placeholder="67X XX XX XX"
                  enabled={f.momo_mtn_enabled} onEnabled={(v) => setF({ ...f, momo_mtn_enabled: v })}
                  number={f.momo_mtn_number} onNumber={set('momo_mtn_number')} name={f.momo_mtn_name} onName={set('momo_mtn_name')}
                  instructions={f.momo_mtn_instructions} onInstructions={set('momo_mtn_instructions')} />
                <MomoMethod label="Orange Money" tone="border-orange-300 dark:border-orange-700" placeholder="69X XX XX XX"
                  enabled={f.momo_orange_enabled} onEnabled={(v) => setF({ ...f, momo_orange_enabled: v })}
                  number={f.momo_orange_number} onNumber={set('momo_orange_number')} name={f.momo_orange_name} onName={set('momo_orange_name')}
                  instructions={f.momo_orange_instructions} onInstructions={set('momo_orange_instructions')} />
              </div>
              <Checkbox label={t('seller.store.momoProof')} hint={t('seller.store.momoProofHint')} checked={f.momo_proof_required} onChange={(v) => setF({ ...f, momo_proof_required: v })} />
              <Field label={t('seller.store.paymentNote')} optional hint={t('seller.store.paymentNoteHint')}><Input maxLength={300} value={f.payment_note} onChange={set('payment_note')} /></Field>
              {noNumber && <Alert tone="amber">{t('errors.momo_number_required')}</Alert>}
            </div>
          )}
        </div>
        {!f.cod_enabled && !f.momo_direct_enabled && <Alert tone="amber">{t('seller.store.needPayment')}</Alert>}
        <div className="grid gap-4 sm:grid-cols-2">
          <Field label={t('seller.store.neighborhood')} optional><Input maxLength={80} value={f.neighborhood} onChange={set('neighborhood')} /></Field>
          <Field label={t('seller.store.serviceArea')} optional hint={t('seller.store.serviceAreaHint')}><Input maxLength={200} value={f.service_area} onChange={set('service_area')} /></Field>
          <Field className="sm:col-span-2" label={t('seller.store.returnPolicy')} optional hint={t('seller.store.returnPolicyHint')}><Textarea rows={3} maxLength={1500} value={f.return_policy} onChange={set('return_policy')} /></Field>
        </div>
        <div className="flex justify-end"><Button type="submit" loading={busy} disabled={noNumber}>{t('common.save')}</Button></div>
      </form>
    </Card>
  );
}

function AppearanceTab({ s }: { s: any }) {
  const { session } = useAuth();
  const { t } = useI18n();
  const { id, has } = useBiz();
  const { save, busy } = useSave(id);
  const [f, setF] = useState({ cover_path: s.cover_path as string | null, brand_color: s.brand_color ?? '#156834' });
  if (!has('store_customization')) return <UpgradeNotice feature="store_customization" />;
  return (
    <Card>
      <form onSubmit={(e) => { e.preventDefault(); save(f); }} className="space-y-5">
        <PictureEditor kind="cover" ownerId={session!.user.id} folder={`${id}/store`} currentPath={f.cover_path} title={t('seller.store.cover')}
          onSaved={(p) => setF({ ...f, cover_path: p })} onRemove={() => setF({ ...f, cover_path: null })} />
        <Field label={t('seller.store.brandColor')} optional>
          <div className="flex items-center gap-3"><input type="color" aria-label={t('seller.store.brandColor')} value={f.brand_color} onChange={(e) => setF({ ...f, brand_color: e.target.value })} className="h-10 w-16 rounded border border-gray-300" />
            <span className="text-sm text-ink-muted">{f.brand_color}</span></div>
        </Field>
        <div className="flex justify-end"><Button type="submit" loading={busy}>{t('common.save')}</Button></div>
      </form>
    </Card>
  );
}

function ReviewsTab() {
  const { t, lang } = useI18n();
  const { id } = useBiz();
  const { run } = useAction();
  const store = useStoreRow(id);
  const [reply, setReply] = useState<Record<string, string>>({});
  const q = useQuery({ queryKey: ['seller-reviews', id], queryFn: async () => unwrap(await supabase.from('market_reviews').select('*, products!market_reviews_product_id_fkey(name)').eq('business_id', id).order('created_at', { ascending: false }).limit(100)) as any[] });
  const s = store.data;
  return (
    <div className="space-y-4">
      {s && (
        <Card>
          <div className="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
            <div><p className="font-bold">{t('seller.store.verification')}</p><p className="text-sm text-ink-muted">{t(`seller.store.verify.${s.verification}`, { note: s.verification_note ?? '' })}</p></div>
            {['unverified', 'rejected'].includes(s.verification) && <Button variant="outline" onClick={() => run(() => rpc('store_request_verification', { p_business: id, p_note: null }), t('seller.store.verifyRequested'))}>{t('seller.store.requestVerification')}</Button>}
          </div>
        </Card>
      )}
      <Card>
        <CardHeader title={t('seller.store.tabReviews')} subtitle={s ? <Stars value={s.rating_avg} count={s.rating_count} /> : undefined} />
        {q.isLoading ? <PageLoader /> : !q.data?.length ? <EmptyState title={t('market.noReviews')} body={t('seller.store.noReviewsBody')} /> : (
          <ul className="divide-y divide-gray-100 dark:divide-gray-800">
            {q.data.map((r) => (
              <li key={r.id} className="py-3">
                <div className="flex items-center justify-between gap-2"><span className="flex items-center gap-2"><Stars value={r.rating} /><span className="text-sm font-semibold">{r.products?.name}</span></span>
                  <span className="text-xs text-ink-muted">{formatDate(r.created_at, lang)}{r.status === 'hidden' && <Badge tone="gray" className="ml-2">{t('seller.store.hidden')}</Badge>}</span></div>
                {r.comment && <p className="mt-1 text-sm">{r.comment}</p>}
                <p className="text-xs text-ink-muted">{r.author_name}</p>
                {r.seller_reply ? <p className="mt-2 rounded-lg bg-gray-50 p-2 text-xs dark:bg-gray-800"><b>{t('market.sellerReply')}:</b> {r.seller_reply}</p> : (
                  <div className="mt-2 flex gap-2">
                    <Input aria-label={t('seller.store.reply')} placeholder={t('seller.store.replyPlaceholder')} value={reply[r.id] ?? ''} onChange={(e) => setReply({ ...reply, [r.id]: e.target.value })} />
                    <Button size="sm" variant="secondary" disabled={!reply[r.id]?.trim()} onClick={() => run(() => rpc('market_review_reply', { p_review: r.id, p_reply: reply[r.id] }), t('common.saved'))}>{t('seller.store.reply')}</Button>
                  </div>
                )}
              </li>
            ))}
          </ul>
        )}
      </Card>
    </div>
  );
}

export function StoreSetupCard({ compact }: { compact?: boolean }) {
  const { t } = useI18n();
  const { id, can } = useBiz();
  const cfg = useMarketConfig();
  const r = useReadiness(id, Boolean(cfg.data) && can('store.manage'));
  if (!cfg.data || !can('store.manage') || !r.data || r.data.published) return null;
  const steps = ['store_created', 'profile', 'products', 'delivery', 'payment'] as const;
  const done = steps.filter((k) => r.data[k]).length;
  return (
    <Card className={compact ? '' : 'border-brand-200 bg-gradient-to-br from-brand-50 to-white dark:border-brand-900 dark:from-brand-950/40 dark:to-gray-900'}>
      <div className="flex flex-col gap-3 sm:flex-row sm:items-center">
        <div className="flex-1">
          <p className="font-bold">{t('seller.store.dashTitle')}</p>
          <p className="text-sm text-ink-muted">{t('seller.store.dashBody', { done, total: steps.length + 1 })}</p>
        </div>
        <Link to="/app/store" className="inline-flex h-10 items-center rounded-lg bg-brand-700 px-4 text-sm font-semibold text-white hover:bg-brand-800">{r.data.store_created ? t('seller.store.continueSetup') : t('seller.store.create')}</Link>
      </div>
    </Card>
  );
}
