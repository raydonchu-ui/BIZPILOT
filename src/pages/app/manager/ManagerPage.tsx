// AI Business Manager: ask about your own recorded sales, stock, orders and profit; get drafts. Nothing changes in your
// business until you confirm an action that the server allows. Verified Premium only.
import { FormEvent, useState } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import clsx from 'clsx';
import { Bot, Copy, MessageSquarePlus, Send, Trash2 } from 'lucide-react';
import { useI18n } from '../../../i18n';
import { useBiz } from '../../../lib/business';
import { rpc } from '../../../lib/api';
import { useAction } from '../../../lib/useAction';
import { useToast } from '../../../lib/toast';
import { formatDateTime } from '../../../lib/format';
import { Alert, Button, Card, ConfirmDialog, EmptyState, PageHeader, PageLoader, Textarea, UpgradeNotice } from '../../../components/ui';

type Msg = { role: 'user' | 'assistant'; content: string; intent?: string; data?: any };

export default function ManagerPage() {
  const { t, lang } = useI18n();
  const { id, has, can } = useBiz();
  const toast = useToast();
  const { run, busy } = useAction();
  const qc = useQueryClient();
  const [convId, setConvId] = useState<string | null>(null);
  const [messages, setMessages] = useState<Msg[]>([]);
  const [text, setText] = useState('');
  const [usage, setUsage] = useState<{ used: number; limit: number | null } | null>(null);
  const [pending, setPending] = useState<any>(null);
  const [confirmClear, setConfirmClear] = useState(false);
  const [suggestions, setSuggestions] = useState<string[]>([]);
  const enabled = has('ai_business_manager');
  const history = useQuery({
    queryKey: ['ai-conversations', id], enabled: enabled && can('reports.view'),
    queryFn: () => rpc<any[]>('ai_list_conversations', { p_business: id }),
  });
  if (!can('reports.view')) return <EmptyState title={t('manager.noAccess')} />;
  if (!enabled) return <div><PageHeader title={t('manager.title')} subtitle={t('manager.subtitle')} /><UpgradeNotice feature="ai_business_manager" /></div>;

  const send = async (question: string) => {
    const q = question.trim();
    if (!q) return;
    setText('');
    setMessages((m) => [...m, { role: 'user', content: q }]);
    const r = await run(() => rpc<any>('ai_send_message', { p_business: id, p_conversation: convId, p_text: q, p_lang: lang }));
    if (!r) return;
    setConvId(r.conversation_id);
    setUsage(r.usage);
    setMessages((m) => [...m, { role: 'assistant', content: r.text, intent: r.intent, data: r.data }]);
    setSuggestions(r.suggestions ?? []);
    qc.invalidateQueries({ queryKey: ['ai-conversations', id] });
  };
  const shownSuggestions = suggestions.length ? suggestions : (lang === 'fr'
    ? ['Quel chiffre d’affaires ai-je enregistré cette semaine ?', 'Quels produits doivent être réapprovisionnés ?', 'Résumez mes commandes en attente.', 'Préparez mon rapport de ventes hebdomadaire.']
    : ['How much revenue did I record this week?', 'Which products need restocking?', 'Summarize my outstanding orders.', 'Create my weekly sales report.']);
  const openHistory = async (c: any) => {
    const full = await rpc<any>('ai_get_conversation', { p_conversation: c.id });
    setConvId(full.id);
    setMessages(full.messages.map((m: any) => ({ role: m.role, content: m.content, intent: m.intent, data: m.data })));
  };
  const newChat = () => { setConvId(null); setMessages([]); setSuggestions([]); };
  const proposeRestock = async () => {
    const p = await run(() => rpc<any>('ai_propose_action', { p_business: id, p_kind: 'draft_restock_list', p_payload: {} }));
    if (p) setPending(p);
  };
  const confirmPending = async () => {
    const r = await run(() => rpc<any>('ai_confirm_action', { p_action: pending.action_id }), t('manager.draftSaved'));
    if (r) setPending(null);
  };
  const cancelPending = async () => {
    if (pending) await run(() => rpc('ai_cancel_action', { p_action: pending.action_id }));
    setPending(null);
  };
  const clearAll = async () => {
    const n = await run(() => rpc<number>('ai_clear_history', { p_business: id }), t('manager.historyCleared'));
    if (n !== undefined) { setConfirmClear(false); newChat(); history.refetch(); }
  };
  const copyText = async (v: string) => { try { await navigator.clipboard.writeText(v); toast(t('market.copied'), 'success'); } catch { window.prompt('', v); } };
  const onSubmit = (e: FormEvent) => { e.preventDefault(); send(text); };

  return (
    <div>
      <PageHeader title={t('manager.title')} subtitle={t('manager.subtitle')}
        actions={<Button variant="outline" size="sm" icon={<MessageSquarePlus className="h-4 w-4" />} onClick={newChat}>{t('manager.newChat')}</Button>} />
      <div className="grid gap-4 lg:grid-cols-[260px_minmax(0,1fr)]">
        <Card className="order-last h-fit lg:order-first">
          <p className="mb-2 text-sm font-bold">{t('manager.history')}</p>
          {history.isLoading ? <PageLoader /> : (history.data ?? []).length === 0 ? (
            <p className="text-sm text-ink-muted">{t('manager.noHistory')}</p>
          ) : (
            <ul className="space-y-1">
              {(history.data ?? []).map((c: any) => (
                <li key={c.id}>
                  <button type="button" onClick={() => openHistory(c)} className={clsx('w-full rounded-lg px-2 py-2 text-left text-sm hover:bg-gray-100 dark:hover:bg-gray-800', convId === c.id && 'bg-gray-100 font-semibold dark:bg-gray-800')}>
                    <span className="block truncate">{c.title}</span>
                    <span className="text-xs text-ink-muted">{formatDateTime(c.updated_at, lang)}</span>
                  </button>
                </li>
              ))}
            </ul>
          )}
          {(history.data ?? []).length > 0 && (
            <Button className="mt-3" variant="outline" size="sm" icon={<Trash2 className="h-4 w-4" />} onClick={() => setConfirmClear(true)}>{t('manager.clearHistory')}</Button>
          )}
        </Card>

        <Card className="flex min-h-[420px] flex-col">
          <div className="flex-1 space-y-3" aria-live="polite">
            {messages.length === 0 && (
              <div>
                <p className="flex items-center gap-2 font-semibold"><Bot className="h-5 w-5 text-brand-600" />{t('manager.askTitle')}</p>
                <p className="mt-1 text-sm text-ink-muted">{t('manager.askBody')}</p>
                <div className="mt-4 flex flex-wrap gap-2">
                  {shownSuggestions.map((s) => (
                    <button key={s} type="button" onClick={() => send(s)} disabled={busy}
                      className="min-h-9 rounded-full bg-white px-3 text-left text-sm font-semibold ring-1 ring-gray-200 hover:bg-brand-50 dark:bg-gray-900 dark:ring-gray-700">{s}</button>
                  ))}
                </div>
              </div>
            )}
            {messages.map((m, i) => (
              <div key={i} className={clsx('max-w-[90%] rounded-2xl px-4 py-3 text-sm', m.role === 'user' ? 'ml-auto bg-brand-600 text-white' : 'bg-gray-100 dark:bg-gray-800')}>
                <p className="whitespace-pre-line">{m.content}</p>
                {m.role === 'assistant' && m.intent === 'copy' && m.data?.title && (
                  <div className="mt-3 space-y-2 rounded-xl bg-white p-3 dark:bg-gray-900">
                    <p className="text-xs font-semibold text-ink-muted">{t('manager.draftLabel')}</p>
                    {(['title', 'description', 'whatsapp'] as const).map((k) => m.data[k] && (
                      <div key={k} className="flex items-start gap-2">
                        <p className="flex-1 text-sm">{m.data[k]}</p>
                        <button type="button" aria-label={t('market.copyNumber')} onClick={() => copyText(m.data[k])} className="text-ink-muted hover:text-ink"><Copy className="h-4 w-4" /></button>
                      </div>
                    ))}
                  </div>
                )}
                {m.role === 'assistant' && m.intent === 'restock' && Array.isArray(m.data?.low_stock) && m.data.low_stock.length > 0 && can('purchases.manage') && (
                  <div className="mt-3"><Button size="sm" variant="outline" loading={busy} onClick={proposeRestock}>{t('manager.saveRestockDraft')}</Button></div>
                )}
              </div>
            ))}
          </div>
          {usage && usage.limit !== null && <p className="mt-3 text-xs text-ink-muted">{t('manager.usage', { used: usage.used, limit: usage.limit })}</p>}
          <form onSubmit={onSubmit} className="mt-3 flex items-end gap-2">
            <label htmlFor="manager-q" className="sr-only">{t('manager.askLabel')}</label>
            <Textarea id="manager-q" rows={2} maxLength={1000} className="min-h-[44px]" value={text} onChange={(e) => setText(e.target.value)} placeholder={t('manager.placeholder')} />
            <Button type="submit" loading={busy} disabled={!text.trim()} icon={<Send className="h-4 w-4" />} aria-label={t('manager.send')} />
          </form>
          <p className="mt-2 text-xs text-ink-muted">{t('manager.disclaimer')}</p>
        </Card>
      </div>

      <ConfirmDialog open={Boolean(pending)} onClose={cancelPending} loading={busy} title={pending?.title ?? ''}
        confirmLabel={t('manager.confirmDraft')} onConfirm={confirmPending}>
        <p className="text-sm">{t('manager.draftPreviewBody')}</p>
        <ul className="mt-2 max-h-56 space-y-1 overflow-y-auto text-sm">
          {(pending?.preview?.lines ?? []).map((l: any) => (
            <li key={l.product_id}>{l.name}: {l.on_hand} → {t('manager.suggested', { qty: l.suggested_qty })}</li>
          ))}
        </ul>
        <p className="mt-2 text-xs text-ink-muted">{pending?.preview?.note}</p>
      </ConfirmDialog>
      <ConfirmDialog open={confirmClear} onClose={() => setConfirmClear(false)} danger loading={busy} title={t('manager.clearHistory')}
        body={t('manager.clearHistoryBody')} confirmLabel={t('manager.clearHistory')} onConfirm={clearAll} />
      {messages.length === 0 && !enabled && <Alert tone="amber">{t('manager.notEnabled')}</Alert>}
    </div>
  );
}
