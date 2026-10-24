// BizPilot Market (public shopping) helpers: cart, guest order links, images, sharing, online payment.
import { createContext, ReactNode, useCallback, useContext, useEffect, useMemo, useState } from 'react';
import { useQuery } from '@tanstack/react-query';
import { supabase } from './supabase';
import { ApiError, rpc } from './api';
import { isMissingFunction } from './storeLock';

export const STOREFRONT_BUCKET = 'storefront';

export interface StoreRef { slug: string; name: string; city?: string | null; verified?: boolean; logo_path?: string | null }
export interface ProductCard {
  id: string; name: string; brand: string | null; image: string | null; unit: string; price: number; max_price: number;
  compare_at_price: number | null; available: number; options: number; category: string | null; subcategory: string | null;
  rating_avg: number | null; rating_count: number; store: StoreRef;
}
export interface StoreCard {
  business_id: string; slug: string; name: string; tagline: string | null; logo_path: string | null; city: string | null;
  verified: boolean; rating_avg: number; rating_count: number; business_type: string; cover_path: string | null;
  brand_color: string | null; products: number;
}
export interface MarketConfig {
  enabled: boolean; online_payments_enabled: boolean; commission_pct: number; online_fee_pct: number;
  unpaid_order_minutes: number; policies_en: string | null; policies_fr: string | null;
}

export function publicUrl(path?: string | null) {
  if (!path) return null;
  return supabase.storage.from(STOREFRONT_BUCKET).getPublicUrl(path).data.publicUrl;
}

const MAX_BYTES = 5 * 1024 * 1024;
export async function uploadStorefrontImage(businessId: string, folder: 'store' | 'products', file: Blob, name = 'image.jpg') {
  if (file.size > MAX_BYTES) throw new Error('file_too_large');
  if (!['image/png', 'image/jpeg', 'image/webp'].includes(file.type)) throw new Error('file_type_not_allowed');
  const ext = ({ 'image/png': 'png', 'image/webp': 'webp' } as Record<string, string>)[file.type] ?? (name.split('.').pop()?.toLowerCase().replace(/[^a-z0-9]/g, '') || 'jpg');
  const path = `${businessId}/${folder}/${crypto.randomUUID()}.${ext}`;
  const { error } = await supabase.storage.from(STOREFRONT_BUCKET).upload(path, file, { contentType: file.type, upsert: false });
  if (error) throw error;
  return path;
}

/** The marketplace database functions exist (the 05 upgrade has been applied). */
export function useMarketConfig() {
  return useQuery<MarketConfig | null>({
    queryKey: ['market-config'],
    staleTime: 5 * 60_000,
    retry: (n, e) => !isMissingFunction(e) && n < 1,
    queryFn: async () => {
      try { return await rpc<MarketConfig>('market_config_public'); } catch (e) { if (isMissingFunction(e)) return null; throw e; }
    },
  });
}

// ---------------------------------------------------------------------------
// Cart (one seller at a time). Stored in this browser only; prices are re-checked by the server.
// ---------------------------------------------------------------------------
export interface CartItem {
  product_id: string; listing_id: string; name: string; variant_label: string | null; image: string | null;
  price: number; quantity: number; max: number; allow_fraction?: boolean;
}
export interface Cart { business_id: string | null; store_slug: string | null; store_name: string | null; items: CartItem[] }
const EMPTY: Cart = { business_id: null, store_slug: null, store_name: null, items: [] };
const CART_KEY = 'bizpilot.cart';

function readCart(): Cart {
  try {
    const c = JSON.parse(localStorage.getItem(CART_KEY) ?? 'null');
    return c && Array.isArray(c.items) ? c : EMPTY;
  } catch { return EMPTY; }
}

interface CartApi {
  cart: Cart; count: number; subtotal: number;
  add: (store: { business_id: string; slug: string; name: string }, item: CartItem) => 'added' | 'other_store';
  replace: (store: { business_id: string; slug: string; name: string }, item: CartItem) => void;
  setQty: (productId: string, qty: number) => void;
  remove: (productId: string) => void;
  clear: () => void;
}
const CartCtx = createContext<CartApi | null>(null);

export function CartProvider({ children }: { children: ReactNode }) {
  const [cart, setCart] = useState<Cart>(readCart);
  const save = useCallback((c: Cart) => {
    setCart(c);
    try { localStorage.setItem(CART_KEY, JSON.stringify(c)); } catch { /* storage unavailable */ }
  }, []);
  useEffect(() => {
    const onStorage = (e: StorageEvent) => { if (e.key === CART_KEY) setCart(readCart()); };
    window.addEventListener('storage', onStorage);
    return () => window.removeEventListener('storage', onStorage);
  }, []);
  const api = useMemo<CartApi>(() => {
    const put = (base: Cart, store: { business_id: string; slug: string; name: string }, item: CartItem): Cart => {
      const existing = base.items.find((i) => i.product_id === item.product_id);
      const items = existing
        ? base.items.map((i) => (i.product_id === item.product_id ? { ...i, ...item, quantity: Math.min(i.quantity + item.quantity, item.max || 999) } : i))
        : [...base.items, { ...item, quantity: Math.min(item.quantity, item.max || 999) }];
      return { business_id: store.business_id, store_slug: store.slug, store_name: store.name, items };
    };
    return {
      cart,
      count: cart.items.reduce((s, i) => s + i.quantity, 0),
      subtotal: cart.items.reduce((s, i) => s + i.quantity * i.price, 0),
      add: (store, item) => {
        if (cart.business_id && cart.business_id !== store.business_id && cart.items.length) return 'other_store';
        save(put(cart.items.length ? cart : EMPTY, store, item));
        return 'added';
      },
      replace: (store, item) => save(put(EMPTY, store, item)),
      setQty: (id, qty) => save({ ...cart, items: cart.items.map((i) => (i.product_id === id ? { ...i, quantity: Math.max(qty, 0) } : i)).filter((i) => i.quantity > 0) }),
      remove: (id) => {
        const items = cart.items.filter((i) => i.product_id !== id);
        save(items.length ? { ...cart, items } : EMPTY);
      },
      clear: () => save(EMPTY),
    };
  }, [cart, save]);
  return <CartCtx.Provider value={api}>{children}</CartCtx.Provider>;
}

export function useCart() {
  const c = useContext(CartCtx);
  if (!c) throw new Error('useCart outside CartProvider');
  return c;
}

// ---------------------------------------------------------------------------
// Guest orders: the order link (id + access token) is kept on this device so the buyer can
// follow the order without an account. The token only opens that one order.
// ---------------------------------------------------------------------------
export interface GuestOrder { id: string; token: string; number: string; store_name: string; created_at: string }
const ORDERS_KEY = 'bizpilot.orders';

export function newAccessToken() {
  const b = new Uint8Array(24);
  crypto.getRandomValues(b);
  return Array.from(b, (x) => x.toString(16).padStart(2, '0')).join('');
}
export function guestOrders(): GuestOrder[] {
  try { const v = JSON.parse(localStorage.getItem(ORDERS_KEY) ?? '[]'); return Array.isArray(v) ? v : []; } catch { return []; }
}
export function rememberGuestOrder(o: GuestOrder) {
  try { localStorage.setItem(ORDERS_KEY, JSON.stringify([o, ...guestOrders().filter((x) => x.id !== o.id)].slice(0, 30))); } catch { /* ignore */ }
}
export function guestToken(orderId: string) {
  return guestOrders().find((o) => o.id === orderId)?.token ?? null;
}
export function orderLink(id: string, token?: string | null) {
  return `/order/${id}${token ? `?t=${token}` : ''}`;
}

// ---------------------------------------------------------------------------
// Online payment (Fapshi hosted checkout through the edge function)
// ---------------------------------------------------------------------------
async function invokeFapshi(body: Record<string, unknown>) {
  const { data, error } = await supabase.functions.invoke('fapshi', { body });
  if (error) {
    let payload: any = null;
    try { payload = await (error as any).context?.json?.(); } catch { /* not JSON */ }
    throw new ApiError({ message: payload?.error ?? 'payment_provider_error', details: payload?.details ?? null });
  }
  return data as any;
}
export type PayStart =
  | { mode: 'direct'; payment_id: string; amount: number }
  | { mode: 'link'; payment_id: string; link: string; direct_failed?: boolean; direct_error?: string };
export type Medium = 'mobile money' | 'orange money';

/** MTN or Orange from a Cameroon number (MTN 67/650-654/680-684, Orange 69/655-659/685-689). */
export function detectMedium(phone: string): Medium | null {
  let d = phone.replace(/\D/g, '');
  if (d.length === 12 && d.startsWith('237')) d = d.slice(3);
  if (!/^6\d{8}$/.test(d)) return null;
  const p2 = Number(d.slice(0, 2)); const p3 = Number(d.slice(0, 3));
  if (p2 === 67 || (p3 >= 650 && p3 <= 654) || (p3 >= 680 && p3 <= 684)) return 'mobile money';
  if (p2 === 69 || (p3 >= 655 && p3 <= 659) || (p3 >= 685 && p3 <= 689)) return 'orange money';
  return null;
}

/** Asks Fapshi to send the payment request to the phone (or returns a payment page link). */
export async function requestOrderPayment(orderId: string, token: string | null, phone?: string, medium?: Medium) {
  const d = await invokeFapshi({ action: 'order', order_id: orderId, token, ...(phone ? { phone, medium } : {}) });
  if (!d?.payment_id) throw new ApiError({ message: d?.error ?? 'payment_provider_error' });
  return d as PayStart;
}
export async function requestSubscriptionPayment(businessId: string, plan: string, period: 'monthly' | 'annual', phone?: string, medium?: Medium) {
  const d = await invokeFapshi({ action: 'subscription', business_id: businessId, plan_code: plan, period, ...(phone ? { phone, medium } : {}) });
  if (!d?.payment_id) throw new ApiError({ message: d?.error ?? 'payment_provider_error' });
  return d as PayStart;
}
export async function fapshiBalance() {
  return invokeFapshi({ action: 'balance' }) as Promise<{ service: string | null; balance: number; currency: string; live?: boolean;
    direct_pay?: { ok: boolean; at: string; http_status?: number; message?: string;
      last_error?: { where: string; code: string; http_status: number; message: string; at: string } } | null }>;
}

export async function verifyPayment(paymentId: string) {
  return invokeFapshi({ action: 'verify', payment_id: paymentId }) as Promise<{ status: string; kind: string; order_id: string | null;
    order_payment_status: string | null; order_status: string | null }>;
}

// ---------------------------------------------------------------------------
// Sharing and contact
// ---------------------------------------------------------------------------
export function siteOrigin() {
  return typeof window !== 'undefined' ? window.location.origin : 'https://www.bizpilotmarket.com';
}
export function storeUrl(slug: string) { return `${siteOrigin()}/s/${slug}`; }
export function productUrl(slug: string, id: string) { return `${siteOrigin()}/s/${slug}/p/${id}`; }
export function waLink(phone: string | null | undefined, text?: string) {
  const d = (phone ?? '').replace(/\D/g, '');
  return `https://wa.me/${d}${text ? `?text=${encodeURIComponent(text)}` : ''}`;
}
export function shareLinks(url: string, text: string) {
  return {
    whatsapp: `https://wa.me/?text=${encodeURIComponent(`${text} ${url}`)}`,
    facebook: `https://www.facebook.com/sharer/sharer.php?u=${encodeURIComponent(url)}`,
  };
}
