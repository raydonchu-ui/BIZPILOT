import { useMemo, useState } from 'react';
import { Link } from 'react-router-dom';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { Archive, ArchiveRestore, ArrowDown, ArrowLeft, ArrowUp, FolderTree, Pencil, Plus } from 'lucide-react';
import { useI18n } from '../../../i18n';
import { useBiz } from '../../../lib/business';
import { supabase } from '../../../lib/supabase';
import { rpc, unwrap } from '../../../lib/api';
import { Category, subcategoriesOf, useBusinessRow, useCategoryTree, useDbUpgraded } from '../../../lib/hooks';
import { useAction } from '../../../lib/useAction';
import { BUSINESS_TYPES, categoryTemplate, type TemplateCategory } from '../../../lib/catalogTemplates';
import { Alert, Badge, Button, Card, CardHeader, Checkbox, EmptyState, ErrorState, Field, Input, PageHeader, PageLoader, Select } from '../../../components/ui';

export default function CategoriesPage() {
  const { t, lang } = useI18n();
  const { id, can } = useBiz();
  const qc = useQueryClient();
  const tree = useCategoryTree(id);
  const { run, busy } = useAction();
  const [showArchived, setShowArchived] = useState(false);
  const [adding, setAdding] = useState<{ parent: string | null; name: string } | null>(null);
  const [editing, setEditing] = useState<{ id: string; name: string } | null>(null);
  const counts = useQuery({
    queryKey: ['category-counts', id],
    queryFn: async () => {
      const rows = unwrap(await supabase.from('products').select('category_id,subcategory').eq('business_id', id).limit(10000)) as { category_id: string | null; subcategory: string | null }[];
      const top = new Map<string, number>(); const sub = new Map<string, number>();
      for (const r of rows) {
        if (!r.category_id) continue;
        top.set(r.category_id, (top.get(r.category_id) ?? 0) + 1);
        if (r.subcategory) { const k = `${r.category_id}|${r.subcategory.toLowerCase()}`; sub.set(k, (sub.get(k) ?? 0) + 1); }
      }
      return { top, sub };
    },
  });
  const refresh = () => { qc.invalidateQueries({ queryKey: ['categories', id] }); qc.invalidateQueries({ queryKey: ['category-counts', id] }); };

  const upgraded = useDbUpgraded();
  if (!can('products.manage')) return <ErrorState error={{ message: 'permission_denied' }} />;
  if (upgraded === false) return <div><PageHeader title={t('catalog.categories.title')} /><Alert tone="blue">{t('catalog.upgradeNeeded')}</Alert></div>;
  if (tree.isLoading || upgraded === undefined) return <PageLoader />;
  if (tree.error) return <ErrorState error={tree.error} onRetry={() => tree.refetch()} />;

  const all = tree.data ?? [];
  const visible = (c: Category) => showArchived || !c.archived_at;
  const tops = all.filter((c) => !c.parent_id && visible(c));

  const add = async () => {
    if (!adding?.name.trim()) return;
    const siblings = all.filter((c) => c.parent_id === adding.parent);
    const ok = await run(async () => unwrap(await supabase.from('categories').insert({
      business_id: id, name: adding.name.trim(), parent_id: adding.parent, sort_order: Math.max(0, ...siblings.map((s) => s.sort_order)) + 1,
    })), t('common.saved'));
    if (ok !== undefined) { setAdding(null); refresh(); }
  };
  const rename = async () => {
    if (!editing?.name.trim()) return;
    await run(() => rpc('rename_category', { p_business: id, p_category: editing.id, p_name: editing.name.trim() }), t('common.saved'));
    setEditing(null); refresh();
  };
  const setArchived = async (c: Category, archived: boolean) => {
    await run(async () => unwrap(await supabase.from('categories').update({ archived_at: archived ? new Date().toISOString() : null }).eq('id', c.id)), t('common.saved'));
    refresh();
  };
  const move = async (c: Category, dir: -1 | 1) => {
    const siblings = all.filter((x) => x.parent_id === c.parent_id);
    const i = siblings.findIndex((x) => x.id === c.id); const j = i + dir;
    if (j < 0 || j >= siblings.length) return;
    const ids = siblings.map((x) => x.id); [ids[i], ids[j]] = [ids[j], ids[i]];
    await run(() => rpc('reorder_categories', { p_business: id, p_ids: ids }));
    refresh();
  };

  const row = (c: Category, siblings: Category[], count: number | undefined) => {
    const i = siblings.findIndex((x) => x.id === c.id);
    return (
      <div className="flex flex-wrap items-center gap-2 py-2" data-testid={`category-${c.name}`}>
        {editing?.id === c.id ? (
          <form className="flex flex-1 gap-2" onSubmit={(e) => { e.preventDefault(); rename(); }}>
            <Input autoFocus aria-label={t('catalog.categories.rename')} value={editing.name} onChange={(e) => setEditing({ id: c.id, name: e.target.value })} />
            <Button type="submit" size="sm" loading={busy}>{t('common.save')}</Button>
            <Button size="sm" variant="ghost" onClick={() => setEditing(null)}>{t('common.cancel')}</Button>
          </form>
        ) : (
          <div className="flex min-w-0 flex-1 items-center gap-2">
            <span className={c.parent_id ? 'text-sm' : 'font-semibold'}>{c.name}</span>
            {count ? <span className="text-xs text-ink-muted">{t('catalog.categories.products', { n: count })}</span> : null}
            {c.archived_at && <Badge tone="gray">{t('catalog.categories.archived')}</Badge>}
          </div>
        )}
        {editing?.id !== c.id && (
          <div className="flex items-center gap-1">
            <Button size="sm" variant="ghost" aria-label={t('catalog.categories.moveUp')} title={t('catalog.categories.moveUp')} disabled={i <= 0} onClick={() => move(c, -1)} icon={<ArrowUp className="h-4 w-4" />} />
            <Button size="sm" variant="ghost" aria-label={t('catalog.categories.moveDown')} title={t('catalog.categories.moveDown')} disabled={i >= siblings.length - 1} onClick={() => move(c, 1)} icon={<ArrowDown className="h-4 w-4" />} />
            <Button size="sm" variant="ghost" aria-label={`${t('catalog.categories.rename')} ${c.name}`} title={t('catalog.categories.rename')} onClick={() => setEditing({ id: c.id, name: c.name })} icon={<Pencil className="h-4 w-4" />} />
            {!c.parent_id && !c.archived_at && <Button size="sm" variant="ghost" onClick={() => setAdding({ parent: c.id, name: '' })} icon={<Plus className="h-4 w-4" />}><span className="hidden sm:inline">{t('catalog.categories.addSub')}</span></Button>}
            {c.archived_at
              ? <Button size="sm" variant="ghost" onClick={() => setArchived(c, false)} icon={<ArchiveRestore className="h-4 w-4" />}>{t('catalog.categories.restore')}</Button>
              : <Button size="sm" variant="ghost" aria-label={`${t('catalog.categories.archive')} ${c.name}`} title={t('catalog.categories.archive')} onClick={() => setArchived(c, true)} icon={<Archive className="h-4 w-4" />} />}
          </div>
        )}
      </div>
    );
  };

  const addForm = (parent: string | null) => adding && adding.parent === parent && (
    <form className={`flex gap-2 py-2 ${parent ? 'pl-6' : ''}`} onSubmit={(e) => { e.preventDefault(); add(); }}>
      <Input autoFocus aria-label={parent ? t('catalog.categories.subPlaceholder') : t('catalog.categories.namePlaceholder')}
        placeholder={parent ? t('catalog.categories.subPlaceholder') : t('catalog.categories.namePlaceholder')} maxLength={80}
        value={adding.name} onChange={(e) => setAdding({ parent, name: e.target.value })} />
      <Button type="submit" loading={busy}>{t('common.add')}</Button>
      <Button variant="ghost" onClick={() => setAdding(null)}>{t('common.cancel')}</Button>
    </form>
  );

  return (
    <div>
      <PageHeader title={t('catalog.categories.title')} subtitle={t('catalog.categories.subtitle')}
        back={<Link to="/app/products" className="mb-2 inline-flex items-center gap-1 text-sm text-ink-muted hover:text-ink"><ArrowLeft className="h-4 w-4" />{t('nav.products')}</Link>}
        actions={<Button icon={<Plus className="h-4 w-4" />} onClick={() => setAdding({ parent: null, name: '' })}>{t('catalog.categories.add')}</Button>} />
      <div className="grid gap-4 lg:grid-cols-3">
        <Card className="lg:col-span-2">
          <div className="mb-2 flex justify-end"><Checkbox checked={showArchived} onChange={setShowArchived} label={t('catalog.categories.showArchived')} /></div>
          {addForm(null)}
          {tops.length === 0 && !adding ? <EmptyState icon={<FolderTree className="h-6 w-6" />} title={t('catalog.categories.title')} body={t('catalog.categories.empty')} /> : (
            <div className="divide-y divide-gray-100 dark:divide-gray-800">
              {tops.map((c) => {
                const subs = subcategoriesOf(all, c.id, true).filter(visible);
                return (
                  <div key={c.id} className="py-1">
                    {row(c, all.filter((x) => !x.parent_id), counts.data?.top.get(c.id))}
                    {(subs.length > 0 || adding?.parent === c.id) && (
                      <div className="ml-3 border-l border-gray-200 pl-3 dark:border-gray-800">
                        {subs.map((s) => <div key={s.id}>{row(s, subcategoriesOf(all, c.id, true), counts.data?.sub.get(`${c.id}|${s.name.toLowerCase()}`))}</div>)}
                        {addForm(c.id)}
                      </div>
                    )}
                  </div>
                );
              })}
            </div>
          )}
        </Card>
        <SuggestedCategories existing={all} onAdded={refresh} lang={lang} />
      </div>
    </div>
  );
}

function SuggestedCategories({ existing, onAdded, lang }: { existing: Category[]; onAdded: () => void; lang: 'en' | 'fr' }) {
  const { t } = useI18n();
  const { id } = useBiz();
  const bizRow = useBusinessRow(id);
  const { run, busy } = useAction();
  const [type, setType] = useState<string | null>(null);
  const current = type ?? (bizRow.data as any)?.category ?? 'general';
  const has = (name: string, parent?: string) => {
    const top = existing.find((c) => !c.parent_id && c.name.toLowerCase() === (parent ?? name).toLowerCase());
    if (!parent) return Boolean(top && !top.archived_at);
    return Boolean(top && existing.some((c) => c.parent_id === top.id && c.name.toLowerCase() === name.toLowerCase() && !c.archived_at));
  };
  const template = useMemo(() => categoryTemplate(current, lang), [current, lang]);
  const [picked, setPicked] = useState<Record<string, boolean>>({});
  const key = (top: string, sub?: string) => (sub ? `${top}|${sub}` : top);
  const isPicked = (k: string) => picked[k] ?? false;
  const toggle = (k: string, v: boolean, children?: string[]) => setPicked((p) => {
    const n = { ...p, [k]: v };
    if (children) for (const c of children) n[`${k}|${c}`] = v;
    return n;
  });
  const selection: TemplateCategory[] = template
    .map((c) => ({ ...c, children: c.children.filter((s) => isPicked(key(c.name, s)) && !has(s, c.name)) }))
    .filter((c) => (isPicked(key(c.name)) && !has(c.name)) || c.children.length > 0);
  const addSelected = async () => {
    const n = await run(() => rpc<number>('apply_category_template', { p_business: id, p_categories: selection }));
    if (n !== undefined) { setPicked({}); onAdded(); }
  };
  return (
    <Card>
      <CardHeader title={t('catalog.categories.suggested')} subtitle={t('catalog.categories.suggestedSub')} />
      <Field label={t('catalog.categories.businessType')}>
        <Select value={current} onChange={(e) => { setType(e.target.value); setPicked({}); }}>
          {BUSINESS_TYPES.map((b) => <option key={b} value={b}>{t(`businessCategories.${b}`)}</option>)}
        </Select>
      </Field>
      <div className="mt-3 max-h-[28rem] space-y-2 overflow-y-auto pr-1">
        {template.map((c) => (
          <div key={c.name}>
            <Checkbox checked={has(c.name) || isPicked(key(c.name))} disabled={has(c.name)} onChange={(v) => toggle(key(c.name), v, c.children)} label={c.name} />
            {c.children.length > 0 && (
              <div className="ml-7 mt-1 grid gap-1 sm:grid-cols-2">
                {c.children.map((s) => <Checkbox key={s} checked={has(s, c.name) || isPicked(key(c.name, s))} disabled={has(s, c.name)} onChange={(v) => toggle(key(c.name, s), v)} label={<span className="text-sm font-normal">{s}</span>} />)}
              </div>
            )}
          </div>
        ))}
      </div>
      <Button className="mt-4" block loading={busy} disabled={selection.length === 0} onClick={addSelected}>{t('catalog.categories.addSelected')}</Button>
    </Card>
  );
}
