import { FormEvent, ReactNode, useState } from 'react';
import { Link } from 'react-router-dom';
import { useQuery } from '@tanstack/react-query';
import { Bot, Info, Lightbulb, Send, Sparkles } from 'lucide-react';
import clsx from 'clsx';
import { useI18n } from '../../../i18n';
import { useBiz } from '../../../lib/business';
import { useAuth } from '../../../lib/auth';
import { supabase } from '../../../lib/supabase';
import { rpc, unwrap } from '../../../lib/api';
import { errorMessage } from '../../../lib/errors';
import { formatDate, formatDateTime, formatMoney, formatNumber, formatPct, pctChange, Lang } from '../../../lib/format';
import { Alert, Badge, Button, Card, CardHeader, PageHeader, Spinner, Textarea, UpgradeNotice } from '../../../components/ui';
import { PeriodPicker, usePeriod } from '../../../components/PeriodPicker';
import { InsightCard } from '../../../components/Insights';

const PRESETS = ['restock', 'profit', 'fastest', 'notSold', 'capital', 'categories', 'investigate', 'compare', 'declining', 'improve'] as const;
type Preset = typeof PRESETS[number];

interface Msg { role: 'user' | 'assistant'; text?: string; node?: ReactNode; mode?: 'ai' | 'rules'; period?: { from: string; to: string }; note?: string }

/** Minimal, safe markdown rendering (headings, bullets, bold) for AI answers. */
function Markdown({ text }: { text: string }) {
  const lines = text.split('\n');
  const out: ReactNode[] = [];
  let list: string[] = [];
  const inline = (s: string) => s.split(/(\*\*[^*]+\*\*)/g).map((p, i) => p.startsWith('**') && p.endsWith('**') ? <strong key={i}>{p.slice(2, -2)}</strong> : <span key={i}>{p}</span>);
  const flush = () => { if (list.length) { out.push(<ul key={out.length} className="my-1 list-disc space-y-0.5 pl-5">{list.map((l, i) => <li key={i}>{inline(l)}</li>)}</ul>); list = []; } };
  for (const raw of lines) {
    const l = raw.trimEnd();
    if (/^\s*[-*•]\s+/.test(l)) { list.push(l.replace(/^\s*[-*•]\s+/, '')); continue; }
    if (/^\s*\d+\.\s+/.test(l)) { list.push(l.replace(/^\s*\d+\.\s+/, '')); continue; }
    flush();
    if (/^#{1,4}\s/.test(l)) out.push(<p key={out.length} className="mt-3 font-bold">{inline(l.replace(/^#{1,4}\s/, ''))}</p>);
    else if (l.trim()) out.push(<p key={out.length} className="mt-1.5">{inline(l)}</p>);
  }
  flush();
  return <div className="text-sm leading-relaxed">{out}</div>;
}

function Section({ title, children }: { title: string; children: ReactNode }) {
  return <div className="mt-3"><p className="font-bold">{title}</p><div className="mt-1 text-sm">{children}</div></div>;
}

/** Rule-based answers built only from server-computed figures. */
function ruleAnswer(key: Preset, c: any, t: (k: string, p?: any) => string, lang: Lang): ReactNode {
  const m = (v: unknown) => formatMoney(v as number, lang);
  const s = c.summary; const p = c.previous_summary;
  const facts = (items: ReactNode[]) => <Section title={t('advisor.facts')}><ul className="list-disc space-y-0.5 pl-5">{items.map((x, i) => <li key={i}>{x}</li>)}</ul></Section>;
  const recs = (items: ReactNode[]) => items.length ? <Section title={t('advisor.recommendations')}><ul className="list-disc space-y-0.5 pl-5">{items.map((x, i) => <li key={i}>{x}</li>)}</ul></Section> : null;
  const none = (msg: string) => <p className="text-sm">{msg}</p>;
  switch (key) {
    case 'restock': {
      const r = (c.restock ?? []) as any[];
      if (c.restock === null) return none(t('advisor.r.needsPlan'));
      if (!r.length) return none(t('advisor.r.noRestock'));
      return <>{facts(r.slice(0, 8).map((x) => t('advisor.r.restockLine', { name: x.name, qty: formatNumber(x.qty_on_hand, lang), unit: x.base_unit, daily: formatNumber(x.avg_daily, lang, 2), cover: x.days_of_cover == null ? '—' : formatNumber(x.days_of_cover, lang, 0) })))}
        {recs(r.slice(0, 5).map((x) => t('advisor.r.restockRec', { name: x.name, qty: formatNumber(x.recommended_qty, lang), unit: x.base_unit, priority: t(`reports.restock.p_${x.priority}`), confidence: t(`reports.conf.${x.confidence}`) })))}</>;
    }
    case 'profit': case 'compare': {
      const ch = pctChange(Number(s.gross_profit), Number(p.gross_profit));
      return <>{facts([
        t('advisor.r.netSales', { cur: m(s.net_sales), prev: m(p.net_sales) }),
        t('advisor.r.grossProfit', { cur: m(s.gross_profit), prev: m(p.gross_profit), change: ch == null ? '—' : formatPct(ch, lang, 0) }),
        t('advisor.r.margin', { cur: formatPct(s.gross_margin_pct, lang), prev: formatPct(p.gross_margin_pct, lang) }),
        t('advisor.r.expenses', { cur: m(s.operating_expenses), prev: m(p.operating_expenses) }),
        t('advisor.r.losses', { cur: m(s.stock_losses), prev: m(p.stock_losses) }),
        t('advisor.r.transactions', { cur: s.transactions, prev: p.transactions }),
      ])}
        {recs([
          ...(Number(s.gross_margin_pct) < Number(p.gross_margin_pct) ? [t('advisor.r.recMargin')] : []),
          ...(Number(s.operating_expenses) > Number(p.operating_expenses) * 1.1 ? [t('advisor.r.recExpenses')] : []),
          ...(Number(s.net_sales) < Number(p.net_sales) ? [t('advisor.r.recSales')] : []),
          ...(Number(s.stock_losses) > 0 ? [t('advisor.r.recLosses')] : []),
        ])}</>;
    }
    case 'fastest': {
      const r = (c.top_by_units ?? []) as any[];
      if (!r.length) return none(t('advisor.r.noSales'));
      return facts(r.slice(0, 8).map((x) => t('advisor.r.fastLine', { name: x.name, units: formatNumber(x.units, lang), revenue: m(x.revenue), margin: formatPct(x.margin_pct, lang) })));
    }
    case 'notSold': case 'capital': {
      const r = (c.slow_moving ?? []) as any[];
      if (c.slow_moving === null) return none(t('advisor.r.needsPlan'));
      const tied = r.reduce((a, x) => a + Number(x.stock_value), 0);
      return <>{facts([t('advisor.r.inventoryValue', { value: m(c.inventory_value) }), t('advisor.r.slowValue', { value: m(tied), n: r.length }),
        ...r.slice(0, 8).map((x) => t('advisor.r.slowLine', { name: x.name, value: m(x.stock_value), last: x.last_sold_at ? formatDate(x.last_sold_at, lang) : t('insights.never') }))])}
        {recs(r.length ? [t('advisor.r.recSlow')] : [])}</>;
    }
    case 'categories': {
      const r = (c.categories ?? []) as any[];
      if (!r.length) return none(t('advisor.r.noSales'));
      return facts([...r].sort((a, b) => Number(b.gross_profit) - Number(a.gross_profit)).slice(0, 8).map((x) => t('advisor.r.catLine', { name: x.category, gp: m(x.gross_profit), margin: formatPct(x.margin_pct, lang), share: formatPct(x.revenue_share_pct, lang) })));
    }
    case 'declining': {
      const r = ((c.product_changes ?? []) as any[]).filter((x) => Number(x.revenue_now) < Number(x.revenue_before));
      if (!r.length) return none(t('advisor.r.noDecline'));
      return facts(r.map((x) => t('advisor.r.declineLine', { name: x.name, now: m(x.revenue_now), before: m(x.revenue_before), unow: formatNumber(x.units_now, lang), ubefore: formatNumber(x.units_before, lang) })));
    }
    case 'investigate': case 'improve': {
      const ins = (c.insights ?? []) as any[];
      if (!ins.length) return none(t('dashboard.nothingUrgent'));
      return <div className="mt-2 space-y-2">{ins.slice(0, 6).map((i, idx) => <InsightCard key={idx} insight={i} />)}</div>;
    }
  }
}

export default function AdvisorPage() {
  const { t, tv, lang, has: hasKey } = useI18n();
  const { id, has } = useBiz();
  const { session } = useAuth();
  const [period, setPeriod] = usePeriod('this_month');
  const [msgs, setMsgs] = useState<Msg[]>([]);
  const [q, setQ] = useState('');
  const [busy, setBusy] = useState(false);
  const aiPlan = has('ai_advisor');
  const history = useQuery({
    queryKey: ['ai-history', id], enabled: aiPlan,
    queryFn: async () => unwrap(await supabase.from('ai_queries').select('*').eq('business_id', id).eq('user_id', session!.user.id).eq('status', 'completed').order('created_at', { ascending: false }).limit(10)) as any[],
  });
  if (!has('basic_analytics')) return <div><PageHeader title={t('nav.advisor')} /><UpgradeNotice feature="basic_analytics" /></div>;

  const context = () => rpc<any>('advisor_context', { p_business: id, p_from: period.from, p_to: period.to });

  const ask = async (question: string, preset?: Preset) => {
    setMsgs((x) => [...x, { role: 'user', text: question }]);
    setBusy(true);
    try {
      if (aiPlan) {
        const { data, error } = await supabase.functions.invoke('ai-advisor', { body: { business_id: id, question, from: period.from, to: period.to, lang } });
        if (error) {
          let detail: any = null;
          try { detail = await (error as any).context?.json?.(); } catch { /* ignore */ }
          if (detail?.error && detail.error !== 'not_authenticated') throw { message: detail.error, details: detail.details };
          throw error;
        }
        if (data?.mode === 'ai') {
          setMsgs((x) => [...x, { role: 'assistant', text: data.answer, mode: 'ai', period: data.period }]);
          history.refetch();
          return;
        }
        const ctx = data?.context ?? await context();
        setMsgs((x) => [...x, { role: 'assistant', mode: 'rules', period: ctx.period, note: t(`advisor.fallback.${data?.reason ?? 'ai_error'}`),
          node: preset ? ruleAnswer(preset, ctx, t, lang) : ruleAnswer('investigate', ctx, t, lang) }]);
      } else {
        const ctx = await context();
        setMsgs((x) => [...x, { role: 'assistant', mode: 'rules', period: ctx.period, note: preset ? undefined : t('advisor.fallback.no_plan'),
          node: ruleAnswer(preset ?? 'investigate', ctx, t, lang) }]);
      }
    } catch (e) {
      setMsgs((x) => [...x, { role: 'assistant', text: errorMessage(e, t, hasKey), mode: 'rules' }]);
    } finally {
      setBusy(false);
    }
  };
  const submit = (e: FormEvent) => { e.preventDefault(); if (q.trim()) { ask(q.trim()); setQ(''); } };
  const presetLabels = tv<Record<Preset, string>>('advisor.presets');

  return (
    <div>
      <PageHeader title={<span className="flex items-center gap-2"><Bot className="h-7 w-7 text-brand-700" />{t('advisor.title')}</span>} subtitle={t('advisor.subtitle')} actions={<PeriodPicker value={period} onChange={setPeriod} />} />
      <div className="grid gap-4 lg:grid-cols-3">
        <Card className="flex min-h-[60vh] flex-col lg:col-span-2">
          <div className="flex-1 space-y-4">
            {msgs.length === 0 && (
              <div className="py-6 text-center">
                <div className="mx-auto flex h-20 w-20 items-center justify-center rounded-full bg-brand-50 text-brand-700 dark:bg-brand-900/40"><Bot className="h-11 w-11" /></div>
                <p className="mt-4 text-lg font-extrabold">{t('advisor.hello')}</p>
                <p className="mx-auto mt-1 max-w-md text-sm text-ink-muted">{t('advisor.intro')}</p>
              </div>
            )}
            {msgs.map((m, i) => m.role === 'user' ? (
              <div key={i} className="ml-auto w-fit max-w-[85%] rounded-2xl rounded-br-sm bg-brand-700 px-4 py-2.5 text-sm text-white">{m.text}</div>
            ) : (
              <div key={i} className="flex gap-3">
                <span className="flex h-8 w-8 shrink-0 items-center justify-center rounded-full bg-brand-50 text-brand-700 dark:bg-brand-900/50"><Sparkles className="h-4 w-4" /></span>
                <div className="min-w-0 flex-1 rounded-2xl rounded-tl-sm bg-gray-50 px-4 py-3 dark:bg-gray-800/70">
                  <div className="mb-1 flex flex-wrap items-center gap-2 text-xs text-ink-muted">
                    <Badge tone={m.mode === 'ai' ? 'green' : 'blue'}>{m.mode === 'ai' ? t('advisor.modeAi') : t('advisor.modeRules')}</Badge>
                    {m.period && <span>{t('insights.period', { from: formatDate(m.period.from, lang), to: formatDate(m.period.to, lang) })}</span>}
                  </div>
                  {m.note && <p className="mb-2 flex items-start gap-1.5 text-xs text-amber-800 dark:text-amber-300"><Info className="mt-0.5 h-3.5 w-3.5 shrink-0" />{m.note}</p>}
                  {m.text ? <Markdown text={m.text} /> : m.node}
                </div>
              </div>
            ))}
            {busy && <div className="flex items-center gap-2 text-sm text-ink-muted"><Spinner className="h-4 w-4" />{t('advisor.thinking')}</div>}
          </div>
          <div className="mt-4 flex flex-wrap gap-2">
            {PRESETS.map((k) => <button key={k} disabled={busy} onClick={() => ask(presetLabels[k], k)} className="rounded-full border border-brand-200 bg-white px-3 py-1.5 text-xs font-semibold text-brand-800 hover:bg-brand-50 disabled:opacity-50 dark:border-brand-900 dark:bg-gray-900 dark:text-brand-300">{presetLabels[k]}</button>)}
          </div>
          {aiPlan ? (
            <form onSubmit={submit} className="mt-3 flex gap-2">
              <Textarea rows={1} className="min-h-[44px] flex-1" placeholder={t('advisor.placeholder')} value={q} maxLength={1000} onChange={(e) => setQ(e.target.value)}
                onKeyDown={(e) => { if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); submit(e as unknown as FormEvent); } }} />
              <Button type="submit" loading={busy} disabled={!q.trim()} aria-label={t('common.submit')} icon={<Send className="h-4 w-4" />} />
            </form>
          ) : <p className="mt-3 text-xs text-ink-muted">{t('advisor.freeFormNeedsPlan')} <Link to="/app/billing" className="font-semibold text-brand-700 underline">{t('billing.seePlans')}</Link></p>}
        </Card>
        <div className="space-y-4">
          <Card>
            <CardHeader title={<span className="flex items-center gap-2"><Lightbulb className="h-5 w-5 text-brand-600" />{t('advisor.howTitle')}</span>} />
            <ul className="list-disc space-y-1.5 pl-5 text-sm text-ink-soft dark:text-gray-300">{tv<string[]>('advisor.how').map((h) => <li key={h}>{h}</li>)}</ul>
          </Card>
          {aiPlan && (
            <Card>
              <CardHeader title={t('advisor.history')} />
              {(history.data ?? []).length === 0 ? <p className="text-sm text-ink-muted">{t('common.noData')}</p> : (
                <ul className="space-y-2">{history.data!.map((h) => (
                  <li key={h.id}><button className={clsx('w-full rounded-lg px-2 py-1.5 text-left text-sm hover:bg-gray-50 dark:hover:bg-gray-800')}
                    onClick={() => setMsgs([{ role: 'user', text: h.question }, { role: 'assistant', text: h.answer, mode: 'ai', period: h.period_from ? { from: h.period_from, to: h.period_to } : undefined }])}>
                    <span className="block truncate font-medium">{h.question}</span><span className="text-xs text-ink-muted">{formatDateTime(h.created_at, lang)}</span></button></li>))}</ul>
              )}
            </Card>
          )}
          <Alert tone="blue">{t('advisor.disclaimer')}</Alert>
        </div>
      </div>
    </div>
  );
}
