// Offline-tolerant sale entry.
// A sale that cannot reach the server is stored on this device with its unique
// client_ref. Sync re-submits it; the server's idempotency on (business, client_ref)
// guarantees a retried sale is never recorded twice. A queued sale is NEVER shown
// as saved until the server confirms it. Business-rule failures (e.g. stock no
// longer available) are kept as "needs attention" for the user to resolve.
import { useEffect, useState, useSyncExternalStore } from 'react';
import { recordSale } from './api';

export interface QueuedSale {
  client_ref: string;
  business_id: string;
  payload: Record<string, unknown>;
  summary: { total: number; items: number };
  created_at: string;
  status: 'pending' | 'failed';
  error?: { message: string; details?: string | null };
  attempts: number;
}

const KEY = 'bizpilot.offlineQueue';
const EVT = 'bizpilot-queue';
let syncing = false;

function read(): QueuedSale[] {
  try { return JSON.parse(localStorage.getItem(KEY) ?? '[]'); } catch { return []; }
}
function write(items: QueuedSale[]) {
  try { localStorage.setItem(KEY, JSON.stringify(items)); } catch { /* storage full or blocked */ }
  window.dispatchEvent(new Event(EVT));
}

export function isNetworkError(e: unknown) {
  const m = String((e as { message?: string })?.message ?? e);
  return !navigator.onLine || /Failed to fetch|NetworkError|Load failed|fetch failed|network/i.test(m);
}

export function enqueueSale(item: Omit<QueuedSale, 'status' | 'attempts' | 'created_at'>) {
  const items = read().filter((i) => i.client_ref !== item.client_ref);
  items.push({ ...item, status: 'pending', attempts: 0, created_at: new Date().toISOString() });
  write(items);
}

export function discardQueued(ref: string) {
  write(read().filter((i) => i.client_ref !== ref));
}

export function retryQueued(ref: string) {
  write(read().map((i) => (i.client_ref === ref ? { ...i, status: 'pending', error: undefined } : i)));
  return syncQueue();
}

export async function syncQueue(): Promise<{ synced: number; failed: number }> {
  if (syncing || !navigator.onLine) return { synced: 0, failed: 0 };
  syncing = true;
  let synced = 0; let failed = 0;
  try {
    for (const item of read().filter((i) => i.status === 'pending')) {
      try {
        await recordSale(item.business_id, { ...item.payload, client_ref: item.client_ref, offline: true });
        discardQueued(item.client_ref);
        synced++;
      } catch (e: any) {
        if (isNetworkError(e)) break; // still offline: keep everything pending
        write(read().map((i) => (i.client_ref === item.client_ref
          ? { ...i, status: 'failed', attempts: i.attempts + 1, error: { message: e.message, details: e.details } } : i)));
        failed++;
      }
    }
  } finally {
    syncing = false;
  }
  return { synced, failed };
}

/** Removes cached catalogues on logout. Unsynced sales are kept so they are not lost. */
export function clearCachedCatalogs() {
  try {
    Object.keys(localStorage).filter((k) => k.startsWith('bizpilot.catalog.')).forEach((k) => localStorage.removeItem(k));
  } catch { /* ignore */ }
}

function subscribe(cb: () => void) {
  window.addEventListener(EVT, cb);
  window.addEventListener('storage', cb);
  return () => { window.removeEventListener(EVT, cb); window.removeEventListener('storage', cb); };
}
let cache = '';
let cacheVal: QueuedSale[] = [];
function snapshot() {
  const raw = (() => { try { return localStorage.getItem(KEY) ?? '[]'; } catch { return '[]'; } })();
  if (raw !== cache) { cache = raw; try { cacheVal = JSON.parse(raw); } catch { cacheVal = []; } }
  return cacheVal;
}

export function useOfflineQueue(businessId?: string) {
  const all = useSyncExternalStore(subscribe, snapshot);
  const items = businessId ? all.filter((i) => i.business_id === businessId) : all;
  const [online, setOnline] = useState(typeof navigator === 'undefined' ? true : navigator.onLine);
  useEffect(() => {
    const up = () => { setOnline(true); syncQueue(); };
    const down = () => setOnline(false);
    window.addEventListener('online', up);
    window.addEventListener('offline', down);
    const id = setInterval(() => { if (navigator.onLine) syncQueue(); }, 30_000);
    return () => { window.removeEventListener('online', up); window.removeEventListener('offline', down); clearInterval(id); };
  }, []);
  return {
    items,
    online,
    pending: items.filter((i) => i.status === 'pending').length,
    failed: items.filter((i) => i.status === 'failed').length,
  };
}

/** Last-known catalogue for the sales screen, so products can be picked while offline. */
export function cacheCatalog(businessId: string, products: unknown[]) {
  try { localStorage.setItem(`bizpilot.catalog.${businessId}`, JSON.stringify({ at: Date.now(), products })); } catch { /* ignore */ }
}
export function cachedCatalog<T>(businessId: string): T[] | null {
  try {
    const raw = localStorage.getItem(`bizpilot.catalog.${businessId}`);
    return raw ? (JSON.parse(raw).products as T[]) : null;
  } catch { return null; }
}
