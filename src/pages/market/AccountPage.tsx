import { FormEvent, useEffect, useState } from 'react';
import { Link, Navigate, useNavigate, useSearchParams } from 'react-router-dom';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { ChevronLeft, Heart, LayoutDashboard, LogOut, Package, Store } from 'lucide-react';
import { ShopperDashboard } from './ShopperDashboard';
import { useI18n } from '../../i18n';
import { rpc, unwrap } from '../../lib/api';
import { supabase } from '../../lib/supabase';
import { useAuth } from '../../lib/auth';
import { formatDate, formatXaf } from '../../lib/format';
import { guestOrders, ProductCard, StoreCard } from '../../lib/market';
import { useAction } from '../../lib/useAction';
import { MarketImage, OrderStatusBadge, PaymentStatusBadge, ProductGrid, StoreTile } from '../../components/market';
import { Button, Card, EmptyState, Field, Input, LinkButton, PageLoader, Tabs } from '../../components/ui';
import { PushSettings } from '../../components/messaging';

type Tab = 'orders' | 'wishlist' | 'stores' | 'profile';

export default function AccountPage() {
  const { t } = useI18n();
  const { session, ready, context, signOut } = useAuth();
  const [params, setParams] = useSearchParams();
  const tabParam = params.get('tab') as Tab | null;
  const nav = useNavigate();
  if (!ready) return <PageLoader />;
  if (!session) return <Navigate to="/login?next=/account" replace />;
  // The shopper dashboard is the Profile tab; the sections below open from its menu.
  if (!tabParam) return <ShopperDashboard />;
  const tab = tabParam;
  const name = context?.profile?.full_name || session.user.email;
  return (
    <div className="mx-auto max-w-6xl px-4 py-6 sm:px-6">
      <Link to="/account" className="mb-3 inline-flex items-center gap-1 text-sm font-semibold text-brand-700 hover:underline dark:text-brand-400"><ChevronLeft className="h-4 w-4" />{t('market.shopper.back')}</Link>
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
        { value: 'stores', label: t('market.favouriteStores') }, { value: 'profile', label: t('market.profile') },
      ]} />
      <div className="mt-4">
        {tab === 'orders' && <MyOrders />}
        {tab === 'wishlist' && <Wishlist />}
        {tab === 'stores' && <FollowedStores />}
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
              <p className="shrink-0 font-extrabold">{formatXaf(o.total, lang)}</p>
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
    <div className="max-w-xl space-y-4">
    <Card>
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
    <PushSettings />
    </div>
  );
}
