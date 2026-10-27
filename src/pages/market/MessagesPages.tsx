// BizPilot Messages: the conversation list, one conversation (chat with the product on top) and the
// notifications inbox. Signed-in users only (the routes require a session).
import { FormEvent, KeyboardEvent, useEffect, useRef, useState } from 'react';
import { Link, useLocation, useNavigate, useParams } from 'react-router-dom';
import clsx from 'clsx';
import { Bell, ChevronLeft, ChevronRight, MessageCircle, Search, SendHorizontal } from 'lucide-react';
import { useI18n } from '../../i18n';
import { useAuth } from '../../lib/auth';
import { formatDate, formatXaf } from '../../lib/format';
import {
  ConversationRow, InboxRow, markConversationRead, markInboxRead, messageErrorCode, sendReply,
  useConversations, useInbox, useMessages, useRefreshMessaging, useThread,
} from '../../lib/messages';
import { MarketImage } from '../../components/market';
import { Alert, Button, EmptyState, ErrorState, Input, LinkButton, PageLoader, Textarea } from '../../components/ui';

type Lang = 'en' | 'fr';

const zone = 'Africa/Douala';

function dayOf(d: Date) {
  return new Intl.DateTimeFormat('en-CA', { timeZone: zone, year: 'numeric', month: '2-digit', day: '2-digit' }).format(d);
}

function clock(d: Date, lang: Lang) {
  return new Intl.DateTimeFormat(lang === 'fr' ? 'fr-FR' : 'en-GB', { timeZone: zone, hour: '2-digit', minute: '2-digit' }).format(d);
}

/** Time for today, the date otherwise: the way a chat list shows when something happened. */
function whenLabel(iso: string, lang: Lang) {
  const d = new Date(iso);
  return dayOf(d) === dayOf(new Date()) ? clock(d, lang) : formatDate(d, lang);
}

function initial(name: string) {
  return (name.trim()[0] ?? '?').toUpperCase();
}

function counterpart(r: ConversationRow) {
  return r.side === 'buyer' ? r.store_name : r.buyer_name;
}

/** Conversations open under the shopper pages (/messages) or inside the seller app (/app/messages). */
function useInboxBase() {
  const loc = useLocation();
  return loc.pathname.startsWith('/app') ? '/app/messages' : '/messages';
}

export function MessagesPage() {
  const { t, lang } = useI18n();
  const base = useInboxBase();
  const list = useConversations();
  const [tab, setTab] = useState<'all' | 'unread' | 'customers'>('all');
  const [q, setQ] = useState('');
  const rows = list.data ?? [];
  const unread = rows.filter((r) => r.unread > 0).length;
  const needle = q.trim().toLowerCase();
  const shown = rows
    .filter((r) => tab === 'all' || (tab === 'unread' ? r.unread > 0 : r.side === 'seller'))
    .filter((r) => !needle || [counterpart(r), r.product_name ?? '', r.last_message_preview ?? ''].some((x) => x.toLowerCase().includes(needle)));

  return (
    <div className="mx-auto max-w-2xl space-y-4 px-4 pb-10 pt-4 sm:px-6 sm:pt-8">
      <h1 className="text-2xl font-extrabold tracking-tight">{t('market.msg.title')}</h1>
      <Input type="search" value={q} onChange={(e) => setQ(e.target.value)} placeholder={t('market.msg.searchPlaceholder')}
        aria-label={t('market.msg.searchPlaceholder')} prefixIcon={<Search className="h-4 w-4" />} />
      <div className="-mx-4 flex gap-2 overflow-x-auto px-4 sm:mx-0 sm:px-0" role="group" aria-label={t('market.msg.title')}>
        <FilterChip active={tab === 'all'} onClick={() => setTab('all')} label={t('market.msg.all')} />
        <FilterChip active={tab === 'unread'} onClick={() => setTab('unread')} label={t('market.msg.unread')} count={unread} />
        <FilterChip active={tab === 'customers'} onClick={() => setTab('customers')} label={t('market.msg.customers')} />
      </div>

      {list.isLoading ? <PageLoader /> : list.error ? <ErrorState error={list.error} onRetry={() => list.refetch()} /> : rows.length === 0 ? (
        <EmptyState icon={<MessageCircle className="h-6 w-6" />} title={t('market.msg.emptyTitle')} body={t('market.msg.emptyBody')}
          action={<LinkButton to="/market">{t('market.startShopping')}</LinkButton>} />
      ) : shown.length === 0 ? (
        <p className="py-10 text-center text-sm text-ink-muted">{t('market.msg.noMatch')}</p>
      ) : (
        <ul className="divide-y divide-gray-100 overflow-hidden rounded-2xl bg-white shadow-card ring-1 ring-gray-100 dark:divide-gray-800 dark:bg-gray-900 dark:ring-gray-800">
          {shown.map((r) => {
            const name = counterpart(r);
            return (
              <li key={r.id}>
                <Link to={`${base}/${r.id}`} className="flex items-center gap-3 px-4 py-3 hover:bg-gray-50 dark:hover:bg-gray-800/60">
                  {r.counterpart_image ? (
                    <MarketImage path={r.counterpart_image} alt="" size="thumb" className="h-12 w-12 shrink-0" rounded="rounded-full" />
                  ) : (
                    <span aria-hidden="true" className="flex h-12 w-12 shrink-0 items-center justify-center rounded-full bg-brand-100 text-lg font-extrabold text-brand-800 dark:bg-brand-900 dark:text-brand-200">
                      {initial(name)}
                    </span>
                  )}
                  <span className="min-w-0 flex-1">
                    <span className="flex items-baseline justify-between gap-2">
                      <span className={clsx('truncate', r.unread > 0 ? 'font-extrabold' : 'font-semibold')}>{name}</span>
                      <time className="shrink-0 text-xs text-ink-muted" dateTime={r.last_message_at}>{whenLabel(r.last_message_at, lang)}</time>
                    </span>
                    <span className={clsx('mt-0.5 block truncate text-sm', r.unread > 0 ? 'font-semibold text-ink dark:text-gray-100' : 'text-ink-muted')}>
                      {r.last_message_preview ?? r.product_name ?? ''}
                    </span>
                  </span>
                  {r.unread > 0 && (
                    <span className="flex h-6 min-w-6 shrink-0 items-center justify-center rounded-full bg-red-600 px-1.5 text-xs font-bold text-white" aria-label={t('market.msg.unreadCount', { n: r.unread })}>
                      {r.unread > 99 ? '99+' : r.unread}
                    </span>
                  )}
                </Link>
              </li>
            );
          })}
        </ul>
      )}
    </div>
  );
}

function FilterChip({ active, onClick, label, count }: { active: boolean; onClick: () => void; label: string; count?: number }) {
  return (
    <button type="button" aria-pressed={active} onClick={onClick}
      className={clsx('flex shrink-0 items-center gap-2 rounded-full px-4 py-2 text-sm font-semibold ring-1 transition',
        active ? 'bg-brand-700 text-white ring-brand-700' : 'bg-white text-ink-soft ring-gray-200 dark:bg-gray-900 dark:text-gray-300 dark:ring-gray-800')}>
      {label}
      {!!count && <span className="flex h-5 min-w-5 items-center justify-center rounded-full bg-red-600 px-1.5 text-[11px] font-bold text-white">{count}</span>}
    </button>
  );
}

export function ThreadPage() {
  const { id } = useParams();
  const { t, lang } = useI18n();
  const { session } = useAuth();
  const base = useInboxBase();
  const thread = useThread(id);
  const msgs = useMessages(id);
  const refresh = useRefreshMessaging();
  const [body, setBody] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const endRef = useRef<HTMLDivElement>(null);
  const messages = msgs.data ?? [];
  const lastId = messages[messages.length - 1]?.id;

  // Opening the conversation (and every new message while it is open) marks it read.
  useEffect(() => {
    if (!id || !session || !thread.data) return;
    markConversationRead(id).then(refresh).catch(() => undefined);
  }, [id, lastId, session, thread.data, refresh]);

  useEffect(() => {
    endRef.current?.scrollIntoView({ block: 'end' });
  }, [lastId]);

  const send = async (e: FormEvent) => {
    e.preventDefault();
    const text = body.trim();
    if (!text || !id || busy) return;
    setBusy(true);
    setError(null);
    try {
      await sendReply(id, text);
      setBody('');
      refresh();
    } catch (err) {
      setError(t(`market.msg.problems.${messageErrorCode(err)}`));
    } finally {
      setBusy(false);
    }
  };

  const onKey = (e: KeyboardEvent<HTMLTextAreaElement>) => {
    if (e.key === 'Enter' && !e.shiftKey) {
      e.preventDefault();
      e.currentTarget.form?.requestSubmit();
    }
  };

  if (thread.error) {
    return (
      <div className="mx-auto max-w-2xl px-4 py-10">
        <EmptyState title={t('market.msg.notAvailable')} body={t('market.msg.notAvailableBody')} action={<LinkButton to={base} variant="outline">{t('market.msg.backToMessages')}</LinkButton>} />
      </div>
    );
  }
  if (thread.isLoading || !thread.data) return <PageLoader />;
  const meta = thread.data;
  const p = meta.product;

  return (
    <div className="mx-auto flex min-h-[calc(100dvh-3.5rem)] max-w-2xl flex-col md:min-h-[calc(100dvh-4rem)]">
      <header className="sticky top-14 z-30 flex items-center gap-3 border-b border-gray-200/80 bg-white/95 px-3 py-2.5 backdrop-blur md:top-16 dark:border-gray-800 dark:bg-gray-950/95">
        <Link to={base} className="flex h-10 w-10 shrink-0 items-center justify-center rounded-full hover:bg-gray-100 dark:hover:bg-gray-800" aria-label={t('market.msg.backToMessages')}>
          <ChevronLeft className="h-6 w-6" />
        </Link>
        {meta.counterpart_image ? (
          <MarketImage path={meta.counterpart_image} alt="" className="h-10 w-10 shrink-0" rounded="rounded-full" />
        ) : (
          <span aria-hidden="true" className="flex h-10 w-10 shrink-0 items-center justify-center rounded-full bg-brand-100 font-extrabold text-brand-800 dark:bg-brand-900 dark:text-brand-200">{initial(meta.counterpart)}</span>
        )}
        <span className="min-w-0 flex-1">
          <span className="block truncate font-bold">{meta.counterpart}</span>
          <span className="block truncate text-xs text-ink-muted">{meta.side === 'buyer' ? t('market.msg.storeChat') : t('market.msg.customerChat')}</span>
        </span>
      </header>

      {p && (
        <div className="mx-3 mt-3 flex items-center gap-3 rounded-2xl bg-white p-3 shadow-card ring-1 ring-gray-100 dark:bg-gray-900 dark:ring-gray-800">
          <MarketImage path={p.image} alt="" className="h-16 w-16 shrink-0" />
          <div className="min-w-0 flex-1">
            <p className="truncate font-bold">{p.name}</p>
            <p className="text-sm font-extrabold tabular-nums">{formatXaf(p.price, lang)}</p>
          </div>
          {meta.store_slug && <LinkButton to={`/s/${meta.store_slug}/p/${p.id}`} size="sm" variant="outline">{t('market.msg.viewProduct')}</LinkButton>}
        </div>
      )}

      <ul className="flex-1 space-y-2 px-3 py-4" aria-live="polite">
        {messages.length === 0 && msgs.isSuccess && <li className="py-10 text-center text-sm text-ink-muted">{t('market.msg.noMessages')}</li>}
        {messages.map((m) => {
          const mine = m.side === meta.side;
          return (
            <li key={m.id} className={clsx('flex', mine ? 'justify-end' : 'justify-start')}>
              <div className={clsx('max-w-[80%] rounded-2xl px-3.5 py-2 text-sm shadow-xs',
                mine ? 'rounded-br-md bg-brand-700 text-white' : 'rounded-bl-md bg-white text-ink ring-1 ring-gray-100 dark:bg-gray-900 dark:text-gray-100 dark:ring-gray-800')}>
                <p className="whitespace-pre-wrap break-words">{m.body}</p>
                <p className={clsx('mt-1 text-right text-[10px] tabular-nums', mine ? 'text-brand-100' : 'text-ink-muted')}>
                  <time dateTime={m.created_at}>{clock(new Date(m.created_at), lang)}</time>
                </p>
              </div>
            </li>
          );
        })}
        <li aria-hidden="true"><div ref={endRef} /></li>
      </ul>

      {error && <div className="px-3 pb-2"><Alert tone="red">{error}</Alert></div>}
      <form onSubmit={send} className="sticky bottom-0 flex items-end gap-2 border-t border-gray-200/80 bg-white/95 p-3 backdrop-blur dark:border-gray-800 dark:bg-gray-950/95">
        <label htmlFor="thread-body" className="sr-only">{t('market.msg.yourMessage')}</label>
        <Textarea id="thread-body" rows={1} maxLength={2000} value={body} onChange={(e) => setBody(e.target.value)} onKeyDown={onKey}
          placeholder={t('market.msg.placeholder')} className="max-h-32 min-h-11 resize-none" />
        <Button type="submit" aria-label={t('market.msg.send')} disabled={!body.trim()} loading={busy} className="h-11 w-11 shrink-0 px-0">
          <SendHorizontal className="h-5 w-5" />
        </Button>
      </form>
    </div>
  );
}

export function NotificationsPage() {
  const { t, lang } = useI18n();
  const navigate = useNavigate();
  const inbox = useInbox();
  const refresh = useRefreshMessaging();
  const [tab, setTab] = useState<'all' | 'unread'>('all');
  const rows = inbox.data ?? [];
  const shown = tab === 'unread' ? rows.filter((r) => !r.read_at) : rows;

  const open = async (r: InboxRow) => {
    if (!r.read_at) await markInboxRead([r.id]).catch(() => undefined);
    refresh();
    navigate(r.link);
  };
  const markAll = async () => {
    await markInboxRead(null).catch(() => undefined);
    refresh();
  };

  return (
    <div className="mx-auto max-w-2xl space-y-4 px-4 pb-10 pt-4 sm:px-6 sm:pt-8">
      <div className="flex items-center justify-between gap-3">
        <h1 className="flex items-center gap-2 text-2xl font-extrabold tracking-tight"><Bell className="h-6 w-6 text-brand-700" />{t('market.msg.notificationsTitle')}</h1>
        {rows.some((r) => !r.read_at) && (
          <button type="button" onClick={markAll} className="text-sm font-semibold text-brand-700 hover:underline dark:text-brand-400">{t('market.msg.markAllRead')}</button>
        )}
      </div>
      <div className="flex gap-2" role="group" aria-label={t('market.msg.notificationsTitle')}>
        <FilterChip active={tab === 'all'} onClick={() => setTab('all')} label={t('market.msg.all')} />
        <FilterChip active={tab === 'unread'} onClick={() => setTab('unread')} label={t('market.msg.unread')} count={rows.filter((r) => !r.read_at).length} />
      </div>

      {inbox.isLoading ? <PageLoader /> : inbox.error ? <ErrorState error={inbox.error} onRetry={() => inbox.refetch()} /> : shown.length === 0 ? (
        <EmptyState icon={<Bell className="h-6 w-6" />} title={t('market.msg.noNotifications')} body={t('market.msg.noNotificationsBody')} />
      ) : (
        <ul className="divide-y divide-gray-100 overflow-hidden rounded-2xl bg-white shadow-card ring-1 ring-gray-100 dark:divide-gray-800 dark:bg-gray-900 dark:ring-gray-800">
          {shown.map((r) => (
            <li key={r.id}>
              <button type="button" onClick={() => open(r)} className={clsx('flex w-full items-center gap-3 px-4 py-3 text-left hover:bg-gray-50 dark:hover:bg-gray-800/60', !r.read_at && 'bg-brand-50/50 dark:bg-brand-950/30')}>
                <span className="relative shrink-0">
                  <MarketImage path={r.image_path} alt="" className="h-12 w-12" rounded="rounded-full" />
                  {!r.read_at && <span aria-hidden="true" className="absolute -bottom-0.5 -right-0.5 h-3 w-3 rounded-full bg-brand-600 ring-2 ring-white dark:ring-gray-900" />}
                </span>
                <span className="min-w-0 flex-1">
                  <span className="block font-semibold">{t('market.msg.sentYou', { name: r.from_name })}</span>
                  <span className="mt-0.5 line-clamp-2 block text-sm text-ink-soft dark:text-gray-300">{r.preview}</span>
                  <time className="mt-1 block text-xs text-ink-muted" dateTime={r.created_at}>{whenLabel(r.created_at, lang)}</time>
                </span>
                <ChevronRight className="h-5 w-5 shrink-0 text-ink-soft" aria-hidden="true" />
              </button>
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}
