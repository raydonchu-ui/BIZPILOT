import { useMemo } from 'react';
import { Plus, Trash2 } from 'lucide-react';
import { useI18n } from '../i18n';
import { toNumber } from '../lib/format';
import { ATTRIBUTE_FIELDS } from '../lib/catalogTemplates';
import { Button, Field, Input } from './ui';

export interface VariantOption { name: string; values: string }
export interface VariantRow { label: string; attributes: Record<string, string>; selling_price: string; opening_qty: string }

const ATTR_KEYS = new Set(Object.values(ATTRIBUTE_FIELDS).flat().map((f) => f.key));
const slug = (s: string) => s.trim().toLowerCase().normalize('NFD').replace(/[̀-ͯ]/g, '').replace(/[^a-z0-9]+/g, '_').replace(/^_|_$/g, '').slice(0, 30);

// Option name → attribute key ("Size"/"Taille" → size, "Colour"/"Couleur" → color, else a slug).
export function optionKey(name: string, labels: Record<string, string>) {
  const n = name.trim().toLowerCase();
  const byLabel = Object.entries(labels).find(([, l]) => l.toLowerCase() === n)?.[0];
  if (byLabel) return byLabel;
  const s = slug(name);
  if (['colour', 'couleur'].includes(s)) return 'color';
  if (['taille'].includes(s)) return 'size';
  return ATTR_KEYS.has(s) ? s : s || 'option';
}

// Every combination of the option values (max 100), e.g. Size × Colour → "M / Black".
export function combine(options: VariantOption[], labels: Record<string, string>): Omit<VariantRow, 'selling_price' | 'opening_qty'>[] {
  const opts = options.map((o) => ({ key: optionKey(o.name, labels), values: [...new Set(o.values.split(',').map((v) => v.trim()).filter(Boolean))] }))
    .filter((o) => o.values.length > 0);
  if (!opts.length) return [];
  let rows: { parts: string[]; attributes: Record<string, string> }[] = [{ parts: [], attributes: {} }];
  for (const o of opts) {
    rows = rows.flatMap((r) => o.values.map((v) => ({ parts: [...r.parts, v], attributes: { ...r.attributes, [o.key]: v } })));
    if (rows.length > 100) rows = rows.slice(0, 100);
  }
  return rows.map((r) => ({ label: r.parts.join(' / '), attributes: r.attributes }));
}

export function VariantGenerator({ options, onOptions, rows, onRows, defaultPrice, unit }:
  { options: VariantOption[]; onOptions: (o: VariantOption[]) => void; rows: VariantRow[]; onRows: (r: VariantRow[]) => void; defaultPrice: string; unit: string }) {
  const { t, tv } = useI18n();
  const labels = tv<Record<string, string>>('catalog.attr');
  const combos = useMemo(() => combine(options, labels), [options, labels]);
  // Keep typed prices/stock when options change.
  const merged: VariantRow[] = combos.map((c) => rows.find((r) => r.label === c.label) ?? { ...c, selling_price: '', opening_qty: '' });
  const setOpt = (i: number, patch: Partial<VariantOption>) => { onOptions(options.map((o, j) => (j === i ? { ...o, ...patch } : o))); };
  const setRow = (label: string, patch: Partial<VariantRow>) => onRows(merged.map((r) => (r.label === label ? { ...r, ...patch } : r)));
  return (
    <div className="space-y-4">
      <p className="text-sm text-ink-muted dark:text-gray-400">{t('catalog.variantIntro')}</p>
      {options.map((o, i) => (
        <div key={i} className="grid gap-3 sm:grid-cols-[minmax(0,1fr)_minmax(0,2fr)_auto] sm:items-end">
          <Field label={t('catalog.variantOptionName')}><Input value={o.name} onChange={(e) => setOpt(i, { name: e.target.value })} placeholder={i === 0 ? t('catalog.attr.size') : t('catalog.attr.color')} /></Field>
          <Field label={t('catalog.variantOptionValues')}><Input value={o.values} onChange={(e) => setOpt(i, { values: e.target.value })} placeholder={i === 0 ? 'S, M, L, XL' : 'Black, White, Red'} /></Field>
          <Button variant="ghost" aria-label={t('catalog.removeOption')} title={t('catalog.removeOption')} disabled={options.length === 1} onClick={() => onOptions(options.filter((_, j) => j !== i))} icon={<Trash2 className="h-4 w-4" />} />
        </div>
      ))}
      {options.length < 3 && <Button size="sm" variant="secondary" icon={<Plus className="h-4 w-4" />} onClick={() => onOptions([...options, { name: '', values: '' }])}>{t('catalog.addOption')}</Button>}
      {merged.length > 0 && (
        <div>
          <p className="mb-2 text-sm font-semibold">{t('catalog.variantPreview', { n: merged.length })}</p>
          <div className="overflow-x-auto rounded-xl border border-gray-200 dark:border-gray-800">
            <table className="w-full text-sm">
              <thead className="bg-gray-50 text-left text-xs text-ink-muted dark:bg-gray-900"><tr>
                <th className="px-3 py-2">{t('catalog.variantLabel')}</th>
                <th className="px-3 py-2">{t('catalog.variantPrice')} (FCFA)</th>
                <th className="px-3 py-2">{t('catalog.variantStock')} ({unit})</th>
              </tr></thead>
              <tbody>
                {merged.map((r) => (
                  <tr key={r.label} className="border-t border-gray-100 dark:border-gray-800">
                    <td className="px-3 py-2 font-medium">{r.label}</td>
                    <td className="px-3 py-1.5"><Input aria-label={`${t('catalog.variantPrice')} ${r.label}`} type="number" min="0" step="any" inputMode="decimal" value={r.selling_price} placeholder={defaultPrice}
                      onChange={(e) => setRow(r.label, { selling_price: e.target.value })} /></td>
                    <td className="px-3 py-1.5"><Input aria-label={`${t('catalog.variantStock')} ${r.label}`} type="number" min="0" step="any" inputMode="decimal" value={r.opening_qty} placeholder="0"
                      onChange={(e) => setRow(r.label, { opening_qty: e.target.value })} /></td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </div>
      )}
    </div>
  );
}

export function variantPayload(rows: VariantRow[], options: VariantOption[], labels: Record<string, string>, opening: { cost: string; known: boolean }) {
  const combos = combine(options, labels);
  return combos.map((c) => {
    const r = rows.find((x) => x.label === c.label);
    return {
      label: c.label, attributes: c.attributes,
      selling_price: r?.selling_price ? toNumber(r.selling_price) : null,
      opening_qty: r?.opening_qty ? toNumber(r.opening_qty) : 0,
      opening_cost: opening.known && opening.cost ? toNumber(opening.cost) : null,
    };
  });
}
