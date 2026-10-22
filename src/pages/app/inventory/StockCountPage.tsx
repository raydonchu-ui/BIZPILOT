import { useEffect, useMemo, useState } from 'react';
import { Link, useParams } from 'react-router-dom';
import { useQuery } from '@tanstack/react-query';
import { ArrowLeft, CheckCircle2, Printer, Save, XCircle } from 'lucide-react';
import { useI18n } from '../../../i18n';
import { supabase } from '../../../lib/supabase';
import { rpc, unwrap } from '../../../lib/api';
import { useAction } from '../../../lib/useAction';
import { formatDateTime, formatNumber } from '../../../lib/format';
import { Alert, Badge, Button, Card, ConfirmDialog, ErrorState, Input, PageHeader, PageLoader, useMoney } from '../../../components/ui';

export default function StockCountPage() {
  const { id: cid } = useParams();
  const { t, lang } = useI18n();
  const money = useMoney();
  const { run, busy } = useAction();
  const [edits, setEdits] = useState<Record<string, { counted: string; reason: string }>>({});
  const [confirm, setConfirm] = useState<'complete' | 'cancel' | null>(null);
  const [onlyDiff, setOnlyDiff] = useState(false);
  const q = useQuery({
    queryKey: ['count', cid],
    queryFn: async () => {
      const c = unwrap(await supabase.from('stock_counts').select('*').eq('id', cid!).single()) as any;
      const lines = unwrap(await supabase.from('stock_count_lines').select('*, products(name,sku,base_unit,qty_on_hand,avg_cost,location)').eq('count_id', cid!)) as any[];
      lines.sort((a, b) => a.products.name.localeCompare(b.products.name));
      return { c, lines };
    },
  });
  useEffect(() => {
    if (!q.data) return;
    setEdits(Object.fromEntries(q.data.lines.map((l) => [l.product_id, { counted: l.counted_qty?.toString() ?? '', reason: l.reason ?? '' }])));
  }, [q.data]);
  const rows = useMemo(() => (q.data?.lines ?? []).map((l) => {
    const e = edits[l.product_id] ?? { counted: '', reason: '' };
    const system = q.data!.c.status === 'completed' ? Number(l.system_qty_at_completion ?? l.expected_qty) : Number(l.products.qty_on_hand);
    const counted = e.counted === '' ? null : Number(e.counted);
    const diff = counted === null ? null : counted - system;
    return { ...l, e, system, counted, diff };
  }), [q.data, edits]);
  if (q.isLoading) return <PageLoader />;
  if (q.error) return <ErrorState error={q.error} />;
  const c = q.data!.c;
  const editable = c.status === 'draft';
  const missingReasons = rows.filter((r) => r.diff !== null && r.diff !== 0 && !r.e.reason.trim()).length;
  const counted = rows.filter((r) => r.counted !== null).length;
  const valueDiff = rows.reduce((a, r) => a + (r.diff ?? 0) * Number(r.products.avg_cost), 0);
  const save = () => run(() => rpc('save_stock_count_lines', { p_count: cid, p_lines: rows.map((r) => ({ product_id: r.product_id, counted_qty: r.e.counted === '' ? null : Number(r.e.counted), reason: r.e.reason })) }), t('common.saved'));
  const complete = async () => {
    await run(async () => {
      await rpc('save_stock_count_lines', { p_count: cid, p_lines: rows.map((r) => ({ product_id: r.product_id, counted_qty: r.e.counted === '' ? null : Number(r.e.counted), reason: r.e.reason })) });
      return rpc('complete_stock_count', { p_count: cid });
    }, t('inventory.countCompleted'));
    setConfirm(null);
  };
  const cancel = async () => { await run(() => rpc('cancel_stock_count', { p_count: cid }), t('common.saved')); setConfirm(null); };
  const shown = onlyDiff ? rows.filter((r) => r.diff !== null && r.diff !== 0) : rows;
  return (
    <div>
      <PageHeader back={<Link to="/app/inventory?tab=counts" className="mb-2 inline-flex items-center gap-1 text-sm text-ink-muted hover:text-ink no-print"><ArrowLeft className="h-4 w-4" />{t('inventory.tabCounts')}</Link>}
        title={`${t('inventory.stockCount')} ${c.number}`} subtitle={<span className="flex items-center gap-2">{formatDateTime(c.created_at, lang)} <Badge tone={c.status === 'completed' ? 'green' : c.status === 'cancelled' ? 'gray' : 'amber'}>{t(`inventory.countStatus.${c.status}`)}</Badge></span>}
        actions={<div className="flex flex-wrap gap-2 no-print">
          <Button variant="outline" icon={<Printer className="h-4 w-4" />} onClick={() => window.print()}>{t('inventory.printSheet')}</Button>
          {editable && <>
            <Button variant="outline" icon={<XCircle className="h-4 w-4" />} onClick={() => setConfirm('cancel')}>{t('common.cancel')}</Button>
            <Button variant="outline" icon={<Save className="h-4 w-4" />} loading={busy} onClick={save}>{t('inventory.saveProgress')}</Button>
            <Button icon={<CheckCircle2 className="h-4 w-4" />} disabled={counted === 0 || missingReasons > 0} onClick={() => setConfirm('complete')}>{t('inventory.completeCount')}</Button>
          </>}
        </div>} />
      {editable && <div className="mb-4 no-print"><Alert tone="blue">{t('inventory.countHelp')}</Alert></div>}
      <Card>
        <div className="mb-3 flex flex-wrap items-center gap-4 text-sm no-print">
          <span>{t('inventory.countedOf', { n: counted, total: rows.length })}</span>
          <span>{t('inventory.valueDifference')}: <b className={valueDiff < 0 ? 'text-red-600' : ''}>{money(c.status === 'completed' ? c.adjustment_value : valueDiff)}</b></span>
          {missingReasons > 0 && <span className="text-amber-700">{t('inventory.missingReasons', { n: missingReasons })}</span>}
          <label className="ml-auto flex items-center gap-2"><input type="checkbox" checked={onlyDiff} onChange={(e) => setOnlyDiff(e.target.checked)} />{t('inventory.onlyDifferences')}</label>
        </div>
        <div className="-mx-4 overflow-x-auto sm:mx-0">
          <table className="min-w-full text-sm">
            <thead><tr className="text-left text-xs uppercase text-ink-muted">
              <th className="px-3 py-2">{t('dashboard.product')}</th><th className="px-3 py-2 text-right">{t('inventory.recorded')}</th>
              <th className="px-3 py-2 text-right">{t('inventory.counted')}</th><th className="px-3 py-2 text-right">{t('inventory.difference')}</th><th className="px-3 py-2">{t('common.reason')}</th>
            </tr></thead>
            <tbody className="divide-y divide-gray-100 dark:divide-gray-800">
              {shown.map((r) => (
                <tr key={r.id}>
                  <td className="px-3 py-2"><p className="font-semibold">{r.products.name}</p><p className="text-xs text-ink-muted">{r.products.sku}{r.products.location ? ` · ${r.products.location}` : ''}</p></td>
                  <td className="px-3 py-2 text-right tabular-nums">{formatNumber(r.system, lang)} {r.products.base_unit}</td>
                  <td className="px-3 py-2 text-right">{editable ? <Input type="number" min="0" step="any" className="ml-auto w-24 text-right" value={r.e.counted}
                    onChange={(e) => setEdits((x) => ({ ...x, [r.product_id]: { ...r.e, counted: e.target.value } }))} aria-label={t('inventory.counted')} /> : formatNumber(r.counted_qty, lang)}</td>
                  <td className={`px-3 py-2 text-right font-semibold tabular-nums ${r.diff && r.diff < 0 ? 'text-red-600' : r.diff && r.diff > 0 ? 'text-brand-700' : ''}`}>{r.diff === null ? '—' : `${r.diff > 0 ? '+' : ''}${formatNumber(r.diff, lang)}`}</td>
                  <td className="px-3 py-2">{editable ? <Input value={r.e.reason} disabled={!r.diff} placeholder={r.diff ? t('inventory.reasonPlaceholder') : ''}
                    onChange={(e) => setEdits((x) => ({ ...x, [r.product_id]: { ...r.e, reason: e.target.value } }))} /> : r.reason}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </Card>
      <ConfirmDialog open={confirm === 'complete'} onClose={() => setConfirm(null)} onConfirm={complete} loading={busy} title={t('inventory.completeCount')}
        body={t('inventory.completeBody', { n: rows.filter((r) => r.diff).length, value: money(valueDiff) })} />
      <ConfirmDialog open={confirm === 'cancel'} onClose={() => setConfirm(null)} onConfirm={cancel} loading={busy} danger title={t('inventory.cancelCount')} body={t('inventory.cancelCountBody')} />
    </div>
  );
}
