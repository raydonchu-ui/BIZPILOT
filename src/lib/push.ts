// Background notifications for BizPilot messages: this device's Web Push subscription, stored for the signed-in
// user. It needs the VAPID public key (VITE_VAPID_PUBLIC_KEY) and a registered service worker (the published app).
import { supabase } from './supabase';

const VAPID_PUBLIC_KEY = (import.meta.env.VITE_VAPID_PUBLIC_KEY as string | undefined) ?? '';

/** The browser can receive push and the deployment has a key for it. */
export function pushConfigured(): boolean {
  return !!VAPID_PUBLIC_KEY && typeof window !== 'undefined' && 'serviceWorker' in navigator && 'PushManager' in window && 'Notification' in window;
}

/** A VAPID public key, as the browser needs it (base64url in, bytes out). */
export function urlBase64ToUint8Array(value: string): Uint8Array<ArrayBuffer> {
  const pad = '='.repeat((4 - (value.length % 4)) % 4);
  const raw = atob((value + pad).replace(/-/g, '+').replace(/_/g, '/'));
  return Uint8Array.from(raw, (c) => c.charCodeAt(0));
}

async function currentRegistration() {
  const reg = await navigator.serviceWorker.getRegistration();
  if (!reg) throw new Error('service_worker_missing');
  return reg;
}

export async function existingSubscription(): Promise<PushSubscription | null> {
  if (!pushConfigured()) return null;
  const reg = await currentRegistration().catch(() => null);
  return reg ? reg.pushManager.getSubscription() : null;
}

/** Asks for permission, subscribes this device and stores the subscription for the user. */
export async function enablePush(userId: string): Promise<'enabled' | 'denied'> {
  const permission = await Notification.requestPermission();
  if (permission !== 'granted') return 'denied';
  const reg = await currentRegistration();
  const sub = (await reg.pushManager.getSubscription())
    ?? (await reg.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: urlBase64ToUint8Array(VAPID_PUBLIC_KEY) }));
  const json = sub.toJSON();
  // The same device may have been used by another account before: its row is replaced, never shared.
  await supabase.from('push_subscriptions').delete().eq('endpoint', json.endpoint ?? '');
  const { error } = await supabase.from('push_subscriptions').insert({
    user_id: userId, endpoint: json.endpoint, p256dh: json.keys?.p256dh, auth: json.keys?.auth,
  });
  if (error) throw error;
  return 'enabled';
}

export async function disablePush(): Promise<void> {
  const sub = await existingSubscription();
  if (!sub) return;
  await supabase.from('push_subscriptions').delete().eq('endpoint', sub.endpoint);
  await sub.unsubscribe();
}
