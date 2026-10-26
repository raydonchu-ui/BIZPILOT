// Messaging UI shared by every page: the live inbox (pop-up and realtime refresh), the bell, the
// "message the seller" dialog and the switch for background notifications on this device.
import { FormEvent, useEffect, useRef, useState } from 'react';
import { Link, useLocation, useNavigate } from 'react-router-dom';
import { Bell, BellRing, BellOff, MessageCircle, X } from 'lucide-react';
import { useI18n } from '../i18n';
import { useAuth } from '../lib/auth';
import { supabase } from '../lib/supabase';
import { InboxRow, messageErrorCode, startConversation, useInboxUnread, useRefreshMessaging } from '../lib/messages';
import { disablePush, enablePush, existingSubscription, pushConfigured } from '../lib/push';
import { MarketImage } from './market';
import { Alert, Button, Card, LinkButton, Modal, Textarea } from './ui';

/**
 * Listens for new messages while the app is open: refreshes the lists and the badges, and shows a pop-up
 * unless the user is already on that conversation. Mounted once, for signed-in users.
 */
export function InboxListener() {
  const { session } = useAuth();
  const refresh = useRefreshMessaging();
  const loc = useLocation();
  const [pop, setPop] = useState<InboxRow | null>(null);
  const here = useRef(loc.pathname);
  here.current = loc.pathname;
  const uid = session?.user.id;

  useEffect(() => {
    if (!uid) return;
    const channel = supabase.channel(`inbox:${uid}`)
      .on('postgres_changes', { event: 'INSERT', schema: 'public', table: 'inbox_notifications', filter: `user_id=eq.${uid}` }, (payload) => {
        refresh();
        const row = payload.new as InboxRow;
        if (here.current !== row.link) setPop(row);
      })
      .on('postgres_changes', { event: 'INSERT', schema: 'public', table: 'messages' }, () => refresh())
      .subscribe();
    return () => { void supabase.removeChannel(channel); };
  }, [uid, refresh]);

  // Opening the conversation (from the pop-up or anywhere) closes the pop-up.
  useEffect(() => {
    if (pop && loc.pathname === pop.link) setPop(null);
  }, [loc.pathname, pop]);

  useEffect(() => {
    if (!pop) return;
    const timer = window.setTimeout(() => setPop(null), 8000);
    return () => window.clearTimeout(timer);
  }, [pop]);

  if (!pop) return null;
  return <MessagePopup row={pop} onClose={() => setPop(null)} />;
}

function MessagePopup({ row, onClose }: { row: InboxRow; onClose: () => void }) {
  const { t } = useI18n();
  return (
    <div role="status" aria-live="polite" className="fixed inset-x-3 top-3 z-[60] mx-auto max-w-sm rounded-2xl bg-white p-4 shadow-xl ring-1 ring-gray-200 sm:left-auto sm:right-4 sm:mx-0 dark:bg-gray-900 dark:ring-gray-700">
      <div className="flex items-start gap-3">
        <MarketImage path={row.image_path} alt="" className="h-12 w-12 shrink-0" rounded="rounded-full" />
        <div className="min-w-0 flex-1">
          <p className="font-bold">{t('market.msg.newFrom', { name: row.from_name })}</p>
          <p className="mt-0.5 line-clamp-2 text-sm text-ink-soft dark:text-gray-300">{row.preview}</p>
        </div>
        <button type="button" onClick={onClose} aria-label={t('market.msg.close')} className="rounded-full p-1 text-ink-muted hover:bg-gray-100 dark:hover:bg-gray-800">
          <X className="h-4 w-4" />
        </button>
      </div>
      <div className="mt-3 grid grid-cols-2 gap-2">
        <Link to={row.link} onClick={onClose} className="flex min-h-11 items-center justify-center rounded-xl bg-brand-700 text-sm font-bold text-white hover:bg-brand-800">
          {t('market.msg.replyNow')}
        </Link>
        <button type="button" onClick={onClose} className="min-h-11 rounded-xl bg-gray-100 text-sm font-bold text-ink hover:bg-gray-200 dark:bg-gray-800 dark:text-gray-100">
          {t('market.msg.viewLater')}
        </button>
      </div>
    </div>
  );
}

/** The bell with the number of unread inbox items; opens the notifications list. */
export function MessageBell() {
  const { t } = useI18n();
  const unread = useInboxUnread().data ?? 0;
  return (
    <Link to="/notifications" className="relative flex h-10 w-10 items-center justify-center rounded-full text-ink hover:bg-gray-100 dark:text-gray-100 dark:hover:bg-gray-800"
      aria-label={unread ? t('market.msg.bellUnread', { n: unread }) : t('market.msg.bell')}>
      <Bell className="h-5 w-5" />
      {unread > 0 && (
        <span aria-hidden="true" className="absolute right-0.5 top-0.5 flex h-4 min-w-4 items-center justify-center rounded-full bg-red-600 px-1 text-[10px] font-bold text-white">
          {unread > 99 ? '99+' : unread}
        </span>
      )}
    </Link>
  );
}

/** "Message the seller": starts a conversation with a store, optionally about one product. */
export function MessageSellerDialog({ open, onClose, store, storeName, product }: {
  open: boolean; onClose: () => void; store: string; storeName: string;
  product?: { id: string; name: string; image?: string | null } | null;
}) {
  const { t } = useI18n();
  const { session } = useAuth();
  const nav = useNavigate();
  const loc = useLocation();
  const refresh = useRefreshMessaging();
  const [body, setBody] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => { if (open) setError(null); }, [open]);

  const send = async (e: FormEvent) => {
    e.preventDefault();
    const text = body.trim();
    if (!text || busy) return;
    setBusy(true);
    setError(null);
    try {
      const id = await startConversation(store, product?.id ?? null, text);
      refresh();
      setBody('');
      onClose();
      nav(`/messages/${id}`);
    } catch (err) {
      setError(t(`market.msg.problems.${messageErrorCode(err)}`));
    } finally {
      setBusy(false);
    }
  };

  return (
    <Modal open={open} onClose={onClose} title={t('market.msg.askTitle', { store: storeName })} size="sm">
      {!session ? (
        <div className="space-y-3">
          <p className="text-sm text-ink-soft dark:text-gray-300">{t('market.msg.signInBody')}</p>
          <LinkButton to={`/login?next=${encodeURIComponent(loc.pathname)}`} block>{t('market.signIn')}</LinkButton>
        </div>
      ) : (
        <form onSubmit={send} className="space-y-3">
          {product && (
            <div className="flex items-center gap-3 rounded-xl bg-gray-50 p-2 dark:bg-gray-800">
              <MarketImage path={product.image} alt="" className="h-12 w-12 shrink-0" />
              <p className="min-w-0 truncate text-sm font-semibold">{product.name}</p>
            </div>
          )}
          <label htmlFor="msg-body" className="sr-only">{t('market.msg.yourMessage')}</label>
          <Textarea id="msg-body" rows={4} maxLength={2000} value={body} onChange={(e) => setBody(e.target.value)}
            placeholder={t('market.msg.placeholder')} autoFocus />
          {error && <Alert tone="red">{error}</Alert>}
          <Button type="submit" block loading={busy} disabled={!body.trim()}>{t('market.msg.send')}</Button>
        </form>
      )}
    </Modal>
  );
}

/** A button on a store or product page that opens the message dialog for that store. */
export function MessageSellerButton({ store, storeName, product, className }: {
  store: string; storeName: string; product?: { id: string; name: string; image?: string | null } | null; className?: string;
}) {
  const { t } = useI18n();
  const [open, setOpen] = useState(false);
  return (
    <>
      <button type="button" onClick={() => setOpen(true)}
        className={className ?? 'mt-4 inline-flex min-h-11 items-center gap-2 rounded-xl px-4 text-sm font-semibold ring-1 ring-gray-300 hover:bg-gray-50 dark:ring-gray-700 dark:hover:bg-gray-800'}>
        <MessageCircle className="h-4 w-4" />{t('market.msg.messageSeller')}
      </button>
      <MessageSellerDialog open={open} onClose={() => setOpen(false)} store={store} storeName={storeName} product={product} />
    </>
  );
}

/** Background notifications on this device: asks for permission and stores this device's push subscription. */
export function PushSettings() {
  const { t } = useI18n();
  const { session } = useAuth();
  const [state, setState] = useState<'checking' | 'unsupported' | 'off' | 'on' | 'denied'>('checking');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let live = true;
    if (!pushConfigured()) {
      setState('unsupported');
    } else if (Notification.permission === 'denied') {
      setState('denied');
    } else {
      existingSubscription()
        .then((s) => { if (live) setState(s ? 'on' : 'off'); })
        .catch(() => { if (live) setState('unsupported'); });
    }
    return () => { live = false; };
  }, []);

  const toggle = async () => {
    if (!session) return;
    setBusy(true);
    setError(null);
    try {
      if (state === 'on') {
        await disablePush();
        setState('off');
      } else {
        setState((await enablePush(session.user.id)) === 'denied' ? 'denied' : 'on');
      }
    } catch {
      setError(t('market.msg.push.failed'));
    } finally {
      setBusy(false);
    }
  };

  const on = state === 'on';
  return (
    <Card className="max-w-xl">
      <div className="flex items-start gap-3">
        <span className="flex h-10 w-10 shrink-0 items-center justify-center rounded-xl bg-brand-50 text-brand-700 dark:bg-brand-900/40 dark:text-brand-300">
          {on ? <BellRing className="h-5 w-5" /> : <BellOff className="h-5 w-5" />}
        </span>
        <div className="min-w-0 flex-1">
          <p className="font-bold">{t('market.msg.push.title')}</p>
          <p className="mt-1 text-sm text-ink-soft dark:text-gray-300">
            {state === 'unsupported' ? t('market.msg.push.unsupported')
              : state === 'denied' ? t('market.msg.push.denied')
                : t('market.msg.push.body')}
          </p>
          {error && <p className="mt-2 text-sm text-red-700 dark:text-red-400">{error}</p>}
        </div>
      </div>
      {state !== 'unsupported' && state !== 'denied' && state !== 'checking' && (
        <Button className="mt-4" variant={on ? 'outline' : 'primary'} loading={busy} onClick={toggle}>
          {on ? t('market.msg.push.turnOff') : t('market.msg.push.turnOn')}
        </Button>
      )}
    </Card>
  );
}
