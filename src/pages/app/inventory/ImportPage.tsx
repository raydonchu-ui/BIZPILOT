import { useState } from 'react';
import { useQuery } from '@tanstack/react-query';
import { CheckCircle2, Download, FileUp, RotateCcw, XCircle } from 'lucide-react';
import { useI18n } from '../../../i18n';
import { useBiz } from '../../../lib/business';
import { supabase } from '../../../lib/supabase';
import { rpc, unwrap } from '../../../lib/api';
import { useAction } from '../../../lib/useAction';
import { downloadText, parseCsv, toCsv } from '../../../lib/csv';
import { formatDateTime, formatNumber } from '../../../lib/format';
import { Alert, Badge, Button, Card, CardHeader, ConfirmDialog, DataTable, ErrorState, PageHeader, PageLoader, Tabs, UpgradeNotice } from '../../../components/ui';

type Kind = 'products' | 'suppliers' | 'customers';

const TEMPLATES: Record<Kind, { columns: string[]; example: Record<string, string>[] }> = {
  products: {
    columns: ['name', 'sku', 'barcode', 'category', 'brand', 'base_unit', 'allow_fraction', 'purchase_cost', 'selling_price', 'min_stock', 'opening_qty', 'opening_unit_cost', 'location', 'description'],
    example: [
      { name: 'Indomie Noodles 70g', sku: 'IND-70', barcode: '', category: 'Food', brand: 'Indomie', base_unit: 'packet', allow_fraction: 'no', purchase_cost: '210', selling_price: '300', min_stock: '24', opening_qty: '120', opening_unit_cost: '210', location: 'Shelf A', description: '' },
      { name: 'Rice 25kg', sku: 'RICE-25', barcode: '', category: 'Food', brand: '', base_unit: 'kg', allow_fraction: 'yes', purchase_cost: '480', selling_price: '600', min_stock: '25', opening_qty: '50', opening_unit_cost: '', location: '', description: 'Sold by the kilo' },
    ],
  },
  suppliers: {
    columns: ['name', 'contact_person', 'phone', 'email', 'address', 'reference', 'payment_terms_days', 'notes'],
    example: [{ name: 'Grossiste Akwa', contact_person: 'M. Ngono', phone: '+237 6 99 00 00 00', email: '', address: 'Akwa, Douala', reference: '', payment_terms_days: '15', notes: '' }],
  },
  customers: {
    columns: ['name', 'phone', 'email', 'address', 'notes'],
    example: [{ name: 'Marie N.', phone: '+237 6 77 00 00 00', email: '', address: 'Bonamoussadi', notes: '' }],
  },
};

export default function ImportPage() {
  const { t, lang } = useI18n();
  const { id, has, can } = useBiz();
  const { run, busy } = useAction();
  const [kind, setKind] = useState<Kind>('products');
  const [file, setFile] = useState<string | null>(null);
  const [rows, setRows] = useState<Record<string, string>[] | null>(null);
  const [preview, setPreview] = useState<any | null>(null);
  const [result, setResult] = useState<any | null>(null);
  const [rollback, setRollback] = useState<string | null>(null);
  const history = useQuery({
    queryKey: ['imports', id],
    queryFn: async () => unwrap(await supabase.from('import_batches').select('*').eq('business_id', id).order('created_at', { ascending: false }).limit(30)) as any[],
  });
  if (!has('import')) return <div><PageHeader title={t('imports.title')} /><UpgradeNotice feature="import" /></div>;
  if (!can('imports.manage')) return <ErrorState error={{ message: 'permission_denied' }} />;

  const reset = () => { setFile(null); setRows(null); setPreview(null); setResult(null); };
  const template = () => {
    const tpl = TEMPLATES[kind];
    downloadText(`bizpilot-${kind}-template.csv`, toCsv(tpl.example, tpl.columns.map((c) => ({ key: c, label: c }))));
  };
  const onFile = async (f?: File) => {
    if (!f) return;
    reset();
    const text = await f.text();
    const parsed = parseCsv(text);
    setFile(f.name);
    setRows(parsed);
    if (kind === 'products') {
      const pv = await run(() => rpc('preview_product_import', { p_business: id, p_rows: parsed }));
      setPreview(pv ?? null);
    } else {
      // Suppliers / customers are validated (name required, duplicates skipped) by the server during import.
      setPreview({ total: parsed.length, valid: parsed.filter((r) => r.name?.trim()).length, invalid: parsed.filter((r) => !r.name?.trim()).length,
        rows: parsed.map((r, i) => ({ row: i + 1, ok: Boolean(r.name?.trim()), errors: r.name?.trim() ? [] : ['name_required'] })) });
    }
  };
  const doImport = async () => {
    const res = kind === 'products'
      ? await run(() => rpc('import_products', { p_business: id, p_rows: rows, p_file_name: file }), t('imports.done'))
      : await run(() => rpc('import_parties', { p_business: id, p_kind: kind, p_rows: rows, p_file_name: file }), t('imports.done'));
    if (res) { setResult(res); setRows(null); setPreview(null); }
  };
  const errLabel = (e: string) => {
    const [code, field] = e.split(':');
    return t(`imports.errors.${code}`, { field: field ?? '' });
  };
  const cols = TEMPLATES[kind].columns;
  return (
    <div>
      <PageHeader title={t('imports.title')} subtitle={t('imports.subtitle')} />
      <Tabs className="mb-4" value={kind} onChange={(k) => { setKind(k); reset(); }} items={[
        { value: 'products', label: t('nav.products') }, { value: 'suppliers', label: t('nav.suppliers'), hidden: !has('suppliers') },
        { value: 'customers', label: t('nav.customers') }]} />
      <div className="grid gap-4 lg:grid-cols-3">
        <Card className="lg:col-span-2">
          <CardHeader title={t('imports.step1')} subtitle={t(`imports.help.${kind}`)} action={<Button variant="outline" size="sm" icon={<Download className="h-4 w-4" />} onClick={template}>{t('imports.template')}</Button>} />
          <label className="flex cursor-pointer flex-col items-center justify-center gap-2 rounded-xl border-2 border-dashed border-gray-300 px-4 py-10 text-center text-sm text-ink-muted hover:border-brand-500 dark:border-gray-700">
            <FileUp className="h-8 w-8" />{file ?? t('imports.chooseFile')}
            <input type="file" accept=".csv,text/csv" className="sr-only" onChange={(e) => { onFile(e.target.files?.[0]); e.target.value = ''; }} />
          </label>
          <p className="mt-2 text-xs text-ink-muted">{t('imports.columns')}: {cols.join(', ')}</p>
          {kind === 'products' && <p className="mt-1 text-xs text-ink-muted">{t('imports.openingNote')}</p>}

          {preview && rows && (
            <div className="mt-6">
              <h3 className="mb-2 font-bold">{t('imports.step2')}</h3>
              <div className="mb-3 flex flex-wrap gap-2">
                <Badge tone="gray">{t('imports.rowsTotal', { n: preview.total })}</Badge>
                <Badge tone="green">{t('imports.rowsValid', { n: preview.valid })}</Badge>
                {preview.invalid > 0 && <Badge tone="red">{t('imports.rowsInvalid', { n: preview.invalid })}</Badge>}
              </div>
              {preview.limit != null && Number(preview.current_products) + Number(preview.valid) > Number(preview.limit) && (
                <div className="mb-3"><Alert tone="red">{t('imports.overLimit', { limit: preview.limit })}</Alert></div>
              )}
              <div className="max-h-[420px] overflow-auto rounded-xl border border-gray-200 dark:border-gray-800">
                <table className="min-w-full text-xs">
                  <thead className="sticky top-0 bg-gray-50 dark:bg-gray-800"><tr><th className="px-2 py-2 text-left">#</th><th className="px-2 py-2 text-left">{t('common.status')}</th>
                    {cols.slice(0, 6).map((c) => <th key={c} className="px-2 py-2 text-left">{c}</th>)}</tr></thead>
                  <tbody className="divide-y divide-gray-100 dark:divide-gray-800">
                    {rows.map((r, i) => {
                      const pr = preview.rows[i];
                      return (
                        <tr key={i} className={pr?.ok ? '' : 'bg-red-50/60 dark:bg-red-950/20'}>
                          <td className="px-2 py-1.5">{i + 1}</td>
                          <td className="px-2 py-1.5">{pr?.ok ? <CheckCircle2 className="h-4 w-4 text-brand-600" /> : <span className="flex items-start gap-1 text-red-700"><XCircle className="h-4 w-4 shrink-0" />{(pr?.errors ?? []).map(errLabel).join(', ')}</span>}</td>
                          {cols.slice(0, 6).map((c) => <td key={c} className="max-w-[160px] truncate px-2 py-1.5">{r[c]}</td>)}
                        </tr>
                      );
                    })}
                  </tbody>
                </table>
              </div>
              <div className="mt-4 flex flex-wrap items-center gap-3">
                <Button loading={busy} disabled={!preview.valid} onClick={doImport}>{t('imports.importValid', { n: preview.valid })}</Button>
                <Button variant="ghost" onClick={reset}>{t('common.cancel')}</Button>
                {preview.invalid > 0 && <span className="text-xs text-ink-muted">{t('imports.invalidSkipped')}</span>}
              </div>
            </div>
          )}
          {result && <div className="mt-6"><Alert tone="green" title={t('imports.done')}>{t('imports.summary', { created: result.created, skipped: result.skipped })}</Alert></div>}
        </Card>
        <Card>
          <CardHeader title={t('imports.history')} />
          {history.isLoading ? <PageLoader /> : (
            <DataTable rows={history.data ?? []} rowKey={(r) => r.id} dense empty={<p className="py-6 text-center text-sm text-ink-muted">{t('common.noData')}</p>} columns={[
              { key: 'f', header: t('imports.file'), render: (r) => <div><p className="max-w-[140px] truncate font-semibold">{r.file_name ?? t(`nav.${r.kind}`)}</p><p className="text-xs text-ink-muted">{formatDateTime(r.created_at, lang)}</p></div> },
              { key: 'n', header: t('imports.created'), align: 'right', render: (r) => formatNumber(r.created_count, lang) },
              { key: 's', header: '', align: 'right', render: (r) => r.status === 'rolled_back' ? <Badge tone="gray">{t('imports.rolledBack')}</Badge>
                : <Button size="sm" variant="ghost" icon={<RotateCcw className="h-3.5 w-3.5" />} onClick={() => setRollback(r.id)}>{t('imports.undo')}</Button> },
            ]} />
          )}
        </Card>
      </div>
      <ConfirmDialog open={Boolean(rollback)} onClose={() => setRollback(null)} danger loading={busy} title={t('imports.undoTitle')} body={t('imports.undoBody')}
        onConfirm={async () => { await run(() => rpc('rollback_import', { p_batch: rollback }), t('imports.undone')); setRollback(null); }} />
    </div>
  );
}
