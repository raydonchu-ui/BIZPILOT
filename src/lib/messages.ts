// BizPilot Messages: shopper and store conversations, the inbox and unread counts. Reads go through row level
// security and the msg_* functions; writes go through the functions only (supabase/migrations/…_messaging.sql).
import { useCallback } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { useAuth } from './auth';
import { rpc, unwrap } from './api';
import { supabase } from './supabase';

export type Side = 'buyer' | 'seller';

export interface ConversationRow {
  id: string;
  business_id: string;
  store_slug: string | null;
  store_name: string;
  buyer_name: string;
  product_id: string | null;
  product_name: string | null;
  last_message_at: string;
  last_message_preview: string | null;
  side: Side;
  unread: number;
  counterpart_image: string | null;
}

export interface ThreadMeta {
  id: string;
  side: Side;
  store_name: string;
  store_slug: string | null;
  buyer_name: string;
  counterpart: string;
  counterpart_image: string | null;
  product: { id: string; name: string; image: string | null; price: number | null } | null;
}

export interface Message {
  id: string;
  conversation_id: string;
  sender_id: string;
  side: Side;
  body: string;
  created_at: string;
}

export interface InboxRow {
  id: string;
  kind: 'message';
  conversation_id: string;
  from_name: string;
  preview: string;
  image_path: string | null;
  link: string;
  read_at: string | null;
  created_at: string;
}

/** Errors the database raises for a message, by code (see market.msg.problems). */
export function messageErrorCode(e: unknown): string {
  const msg = String((e as { message?: string })?.message ?? '');
  return /^[a-z_]+$/.test(msg) ? msg : 'failed';
}

export function useConversations() {
  const { session } = useAuth();
  return useQuery({
    queryKey: ['msg-list', session?.user.id],
    queryFn: () => rpc<ConversationRow[]>('msg_list'),
    enabled: !!session,
  });
}

/** Conversations with something unread: the Messages tab badge. */
export function useMessagesUnread() {
  const { session } = useAuth();
  return useQuery({
    queryKey: ['msg-unread', session?.user.id],
    queryFn: () => rpc<number>('msg_unread'),
    enabled: !!session,
  });
}

/** Unread inbox rows: the bell. */
export function useInboxUnread() {
  const { session } = useAuth();
  return useQuery({
    queryKey: ['inbox-unread', session?.user.id],
    queryFn: async () => {
      const res = await supabase.from('inbox_notifications').select('id', { count: 'exact', head: true }).is('read_at', null);
      if (res.error) throw res.error;
      return res.count ?? 0;
    },
    enabled: !!session,
  });
}

export function useInbox() {
  const { session } = useAuth();
  return useQuery({
    queryKey: ['inbox', session?.user.id],
    queryFn: async () => unwrap(await supabase.from('inbox_notifications').select('*').order('created_at', { ascending: false }).limit(100)) as InboxRow[],
    enabled: !!session,
  });
}

export function useThread(id: string | undefined) {
  const { session } = useAuth();
  return useQuery({
    queryKey: ['msg-thread', id, session?.user.id],
    queryFn: () => rpc<ThreadMeta>('msg_thread', { p_conversation: id }),
    enabled: !!session && !!id,
  });
}

export function useMessages(id: string | undefined) {
  const { session } = useAuth();
  return useQuery({
    queryKey: ['msg-messages', id, session?.user.id],
    queryFn: async () => unwrap(await supabase.from('messages').select('*').eq('conversation_id', id!)
      .order('created_at', { ascending: true }).limit(500)) as Message[],
    enabled: !!session && !!id,
  });
}

/** Refreshes every messaging query; called when something arrives or is sent. */
export function useRefreshMessaging() {
  const qc = useQueryClient();
  return useCallback(() => {
    for (const key of ['msg-list', 'msg-unread', 'msg-thread', 'msg-messages', 'inbox', 'inbox-unread']) {
      void qc.invalidateQueries({ queryKey: [key] });
    }
  }, [qc]);
}

/** Asks the chat-push function to notify the other side. Best effort: the message is already stored. */
function pushMessage(messageId: string) {
  void supabase.functions.invoke('chat-push', { body: { message_id: messageId } }).catch(() => undefined);
}

/** A shopper starts a conversation with a store (about a product, when given) and sends the first message. */
export async function startConversation(store: string, productId: string | null, body: string) {
  const res = await rpc<{ conversation_id: string; message_id: string }>('msg_start', { p_store: store, p_product: productId, p_body: body });
  pushMessage(res.message_id);
  return res.conversation_id;
}

export async function sendReply(conversationId: string, body: string) {
  const res = await rpc<{ conversation_id: string; message_id: string }>('msg_send', { p_conversation: conversationId, p_body: body });
  pushMessage(res.message_id);
}

export async function markConversationRead(conversationId: string) {
  await rpc('msg_mark_read', { p_conversation: conversationId });
}

export async function markInboxRead(ids: string[] | null = null) {
  await rpc('inbox_mark_read', { p_ids: ids });
}
