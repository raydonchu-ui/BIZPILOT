import { FormEvent, useEffect, useState } from 'react';
import { Link, Navigate, useNavigate, useSearchParams } from 'react-router-dom';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { Heart, LayoutDashboard, LogOut, MapPin, Package, Plus, Store, Trash2 } from 'lucide-react';
import { useI18n } from '../../i18n';
import { rpc, unwrap } from '../../lib/api';
import { supabase } from '../../lib/supabase';
import { useAuth } from '../../lib/auth';
import { formatDate, formatMoney } from '../../lib/format';
import { guestOrders, ProductCard, StoreCard } from '../../lib/market';
import { useAction } from '../../lib/useAction';
import { MarketImage, OrderStatusBadge, PaymentStatusBadge, ProductGrid, StoreTile } from '../../components/market';
import { Badge, Button, Card, Checkbox, EmptyState, Field, Input, LinkButton, Modal, PageLoader, Tabs } from '../../components/ui';

type Tab = 'orders' | 'wishlist' | 'stores' | 'addresses' | 'profile';

export default function AccountPage() {
  const { t } = useI18n();
  const { session, ready, context, signOut } = useAuth();
  const [params, setParams] = useSearchParams();
  const tab = (params.get('tab') as Tab) ?? 'orders';
  const nav = useNavigate();
  if (!ready) return <PageLoader />;
  if (!session) return <Navigate to="/login?next=/account" replace />;
  const name = context?.profile?.full_name || session.user.email;
  return (
    <div className="mx-auto max-w-6xl px-4 py-6 sm:px-6">
      <div className="mb-4 flex flex-col gap-3 sm:flex-row sm:items-end sm:justify-between">
        <div>
          <h1 className="text-2xl font-extrabold tracking-tight">{t('market.accountTitle')}</h1>
          <p className="text-sm text-ink-muted">{t('market.accountHello', { name: name ?? '' })}</p>
        </div>
        <div className="flex flex-wrap gap-2">
          {(context?.businesses.length ?? 0) > 0 && <LinkButton to="/app" variant="outline" size="sm" icon={<LayoutDashboard className="h-4 w-4" />}>{t('market.mySellerDashboard')}</LinkButton>}
          <Button variant="ghost" size="sm" icon={<LogOut className="h-4 w-4" />} onClick={async () => { await signOut(); nav('/market'); }}>{t('nav.logout')}</Button>
        </div>
      </div>
      <Tabs value={tab} onChange={(v) => setParams({ tab: v }, { replace: true })} items={[
        { value: 'orders', label: t('market.myOrders') }, { value: 'wishlist', label: t('market.wishlist') },
        { value: 'stores', label: t('market.favouriteStores') }, { value: 'addresses', label: t('market.addresses') },
        { value: 'profile', label: t('market.profile') },
      ]} />
      <div className="mt-4">
        {tab === 'orders' && <MyOrders />}
        {tab === 'wishlist' && <Wishlist />}
        {tab === 'stores' && <FollowedStores />}
        {tab === 'addresses' && <Addresses />}
        {tab === 'profile' && <Profile />}
      </div>
    </div>
  );
}

function MyOrders() {
  const { t, lang } = useI18n();
  const qc = useQueryClient();
  // Orders placed on this device before signing in are attached to the account.
  useEffect(() => {
    const local = guestOrders();
    if (!local.length) return;
    rpc<number>('market_claim_orders', { p_orders: local.map((o) => ({ id: o.id, token: o.token })) })
      .then((n) => { if (n > 0) qc.invalidateQueries({ queryKey: ['my-orders'] }); }).catch(() => {});
  }, [qc]);
  const q = useQuery({ queryKey: ['my-orders'], queryFn: () => rpc<any[]>('market_my_orders', { p_limit: 50, p_offset: 0 }) });
  if (q.isLoading) return <PageLoader />;
  if (!q.data?.length) return <EmptyState icon={<Package className="h-6 w-6" />} title={t('market.noOrders')} body={t('market.noOrdersBody')} action={<LinkButton to="/market">{t('market.startShopping')}</LinkButton>} />;
  return (
    <div className="space-y-3">
      {q.data.map((o) => (
        <Link key={o.id} to={`/order/${o.id}`} className="block">
          <Card className="transition hover:shadow-md">
            <div className="flex items-center gap-3">
              <MarketImage path={o.first_image} alt="" className="h-14 w-14 shrink-0" />
              <div className="min-w-0 flex-1">
                <p className="font-bold">{o.number} <span className="font-normal text-ink-muted">· {o.store.name}</span></p>
                <p className="text-xs text-ink-muted">{formatDate(o.created_at, lang)} · {t('market.itemsCount', { n: o.items })}</p>
                <div className="mt-1 flex flex-wrap gap-1.5"><OrderStatusBadge status={o.status} /><PaymentStatusBadge status={o.payment_status} /></div>
              </div>
              <p className="shrink-0 font-extrabold">{formatMoney(o.total, lang)}</p>
            </div>
          </Card>
        </Link>
      ))}
    </div>
  );
}

function Wishlist() {
  const { t } = useI18n();
  const q = useQuery({
    queryKey: ['fav', 'list'],
    queryFn: async () => {
      const ids = (unwrap(await supabase.from('market_favorites').select('product_id').order('created_at', { ascending: false })) as any[]).map((r) => r.product_id);
      return ids.length ? rpc<ProductCard[]>('market_products_by_ids', { p_ids: ids }) : [];
    },
  });
  if (q.isLoading) return <PageLoader />;
  return <ProductGrid items={q.data ?? []} empty={<EmptyState icon={<Heart className="h-6 w-6" />} title={t('market.wishlistEmpty')} body={t('market.wishlistEmptyBody')} />} />;
}

function FollowedStores() {
  const { t } = useI18n();
  const q = useQuery({
    queryKey: ['follow', 'list'],
    queryFn: async () => {
      const ids = (unwrap(await supabase.from('market_store_follows').select('business_id')) as any[]).map((r) => r.business_id);
      return ids.length ? rpc<StoreCard[]>('market_store_cards', { p_ids: ids }) : [];
    },
  });
  if (q.isLoading) return <PageLoader />;
  if (!q.data?.length) return <EmptyState icon={<Store className="h-6 w-6" />} title={t('market.noFollowed')} body={t('market.noFollowedBody')} />;
  return <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">{q.data.map((s) => <StoreTile key={s.business_id} s={s} />)}</div>;
}

const blankAddr = { id: '', label: '', recipient_name: '', phone: '', city: '', area: '', line: '', landmark: '', is_default: false };

function Addresses() {
  const { t } = useI18n();
  const { run, busy } = useAction();
  const [edit, setEdit] = useState<typeof blankAddr | null>(null);
  const q = useQuery({ queryKey: ['addresses'], queryFn: async () => unwrap(await supabase.from('customer_addresses').select('*').order('is_default', { ascending: false }).order('created_at')) as any[] });
  const save = async (e: FormEvent) => {
    e.preventDefault();
    if (!edit) return;
    const { id, ...row } = edit;
    const r = await run(async () => unwrap(id ? await supabase.from('customer_addresses').update(row).eq('id', id).select() : await supabase.from('customer_addresses').insert(row).select()), t('common.saved'));
    if (r) setEdit(null);
  };
  const set = (k: keyof typeof blankAddr) => (e: { target: { value: string } }) => setEdit((x) => (x ? { ...x, [k]: e.target.value } : x));
  return (
    <div>
      <div className="mb-3 flex justify-end"><Button icon={<Plus className="h-4 w-4" />} onClick={() => setEdit({ ...blankAddr })}>{t('market.addAddress')}</Button></div>
      {q.isLoading ? <PageLoader /> : !q.data?.length ? <EmptyState icon={<MapPin className="h-6 w-6" />} title={t('market.noAddresses')} body={t('market.noAddressesBody')} /> : (
        <div className="grid gap-3 sm:grid-cols-2">
          {q.data.map((a) => (
            <Card key={a.id}>
              <div className="flex items-start justify-between gap-2">
                <div className="text-sm">
                  <p className="font-bold">{a.label || a.recipient_name} {a.is_default && <Badge tone="green">{t('market.default')}</Badge>}</p>
                  <p>{[a.line, a.area, a.city].filter(Boolean).join(', ')}</p>
                  {a.landmark && <p className="text-xs text-ink-muted">{a.landmark}</p>}
                  <p className="text-xs text-ink-muted">{a.recipient_name} · {a.phone}</p>
                </div>
                <div className="flex gap-1">
                  <Button size="sm" variant="ghost" onClick={() => setEdit({ ...blankAddr, ...a, label: a.label ?? '', area: a.area ?? '', line: a.line ?? '', landmark: a.landmark ?? '' })}>{t('common.edit')}</Button>
                  <Button size="sm" variant="ghost" aria-label={t('common.delete')} icon={<Trash2 className="h-4 w-4" />}
                    onClick={() => run(async () => unwrap(await supabase.from('customer_addresses').delete().eq('id', a.id)), t('common.deleted'))} />
                </div>
              </div>
            </Card>
          ))}
        </div>
      )}
      <Modal open={Boolean(edit)} onClose={() => setEdit(null)} title={edit?.id ? t('market.editAddress') : t('market.addAddress')}
        footer={<><Button variant="outline" onClick={() => setEdit(null)}>{t('common.cancel')}</Button><Button type="submit" form="addr-form" loading={busy}>{t('common.save')}</Button></>}>
        {edit && (
          <form id="addr-form" onSubmit={save} className="grid gap-4 sm:grid-cols-2">
            <Field label={t('market.addressLabel')} optional><Input maxLength={40} value={edit.label} onChange={set('label')} placeholder={t('market.addressLabelPlaceholder')} /></Field>
            <Field label={t('market.fullName')} required><Input required minLength={2} value={edit.recipient_name} onChange={set('recipient_name')} /></Field>
            <Field label={t('market.phone')} required><Input required type="tel" value={edit.phone} onChange={set('phone')} /></Field>
            <Field label={t('market.city')} required><Input required minLength={2} value={edit.city} onChange={set('city')} /></Field>
            <Field label={t('market.area')} optional><Input value={edit.area} onChange={set('area')} /></Field>
            <Field label={t('market.streetLine')} optional><Input value={edit.line} onChange={set('line')} /></Field>
            <Field label={t('market.landmark')} optional className="sm:col-span-2"><Input value={edit.landmark} onChange={set('landmark')} /></Field>
            <div className="sm:col-span-2"><Checkbox label={t('market.makeDefault')} checked={edit.is_default} onChange={(v) => setEdit({ ...edit, is_default: v })} /></div>
          </form>
        )}
      </Modal>
    </div>
  );
}

function Profile() {
  const { t } = useI18n();
  const { context, session, refreshContext } = useAuth();
  const { run, busy } = useAction();
  const [f, setF] = useState({ full_name: context?.profile?.full_name ?? '', phone: context?.profile?.phone ?? '' });
  const save = async (e: FormEvent) => {
    e.preventDefault();
    await run(async () => { unwrap(await supabase.from('profiles').update(f).eq('id', session!.user.id).select()); await refreshContext(); }, t('common.saved'));
  };
  return (
    <Card className="max-w-xl">
      <form onSubmit={save} className="space-y-4">
        <Field label={t('market.email')}><Input value={session?.user.email ?? ''} disabled /></Field>
        <Field label={t('market.fullName')}><Input value={f.full_name} onChange={(e) => setF({ ...f, full_name: e.target.value })} /></Field>
        <Field label={t('market.phone')}><Input type="tel" value={f.phone} onChange={(e) => setF({ ...f, phone: e.target.value })} /></Field>
        <div className="flex flex-wrap gap-2"><Button type="submit" loading={busy}>{t('common.save')}</Button>
          <LinkButton to="/forgot-password" variant="ghost">{t('market.changePassword')}</LinkButton></div>
      </form>
      {(context?.businesses.length ?? 0) === 0 && (
        <div className="mt-6 rounded-xl bg-brand-50 p-4 text-sm dark:bg-brand-900/30">
          <p className="font-bold">{t('market.sellTitle')}</p><p className="mt-1">{t('market.sellBody')}</p>
          <LinkButton to="/onboarding" size="sm" className="mt-3">{t('market.sellCta')}</LinkButton>
        </div>
      )}
    </Card>
  );
}
