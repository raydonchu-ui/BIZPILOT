import { FormEvent, useEffect, useState } from 'react';
import { Link, useNavigate, useParams } from 'react-router-dom';
import { useQuery } from '@tanstack/react-query';
import { ArrowLeft, ImagePlus, Plus, Trash2 } from 'lucide-react';
import { useI18n } from '../../../i18n';
import { useBiz } from '../../../lib/business';
import { useAuth } from '../../../lib/auth';
import { supabase } from '../../../lib/supabase';
import { rpc, unwrap } from '../../../lib/api';
import { Product, ProductUnit, uploadFile, useCategories, useSignedUrl, useSuppliers } from '../../../lib/hooks';
import { useAction } from '../../../lib/useAction';
import { newId } from '../../../lib/ids';
import { toNumber } from '../../../lib/format';
import { Alert, Button, Card, CardHeader, Checkbox, ErrorState, Field, Input, PageHeader, PageLoader, Select, Textarea, UpgradeNotice } from '../../../components/ui';

const UNITS = ['piece', 'bottle', 'can', 'packet', 'sachet', 'box', 'carton', 'bag', 'kg', 'g', 'litre', 'metre', 'roll', 'pair', 'dozen'];

interface UnitRow { id?: string; key: string; name: string; factor: string; selling_price: string; barcode: string; is_default_purchase: boolean; is_default_sale: boolean; active: boolean; used?: boolean }

const blank = {
  name: '', sku: '', barcode: '', category_id: '', subcategory: '', brand: '', description: '', base_unit: 'piece',
  allow_fraction: false, purchase_cost: '', selling_price: '', min_stock: '', lead_time_days: '', min_order_qty: '',
  preferred_supplier_id: '', location: '', track_expiry: false, variant_of: '', variant_label: '', image_path: '' as string | null,
};

export default function ProductForm() {
  const { id: productId } = useParams();
  const editing = Boolean(productId);
  const { t } = useI18n();
  const { id, can, has } = useBiz();
  const { session } = useAuth();
  const nav = useNavigate();
  const { run, busy } = useAction();
  const cats = useCategories(id);
  const sups = useSuppliers(id, has('suppliers'));
  const [f, setF] = useState(blank);
  const [units, setUnits] = useState<UnitRow[]>([]);
  const [opening, setOpening] = useState({ qty: '', cost: '', known: true, batch: '', expiry: '' });
  const [newCat, setNewCat] = useState<string | null>(null);
  const [uploading, setUploading] = useState(false);
  const img = useSignedUrl(f.image_path || null);

  const existing = useQuery({
    queryKey: ['product-edit', productId],
    enabled: editing,
    queryFn: async () => {
      const p = unwrap(await supabase.from('products').select('*, product_units(*)').eq('id', productId!).single()) as Product;
      const unitIds = (p.product_units ?? []).map((u) => u.id);
      const used = new Set<string>();
      if (unitIds.length) {
        const [a, b] = await Promise.all([
          supabase.from('sale_lines').select('unit_id').in('unit_id', unitIds).limit(1000),
          supabase.from('purchase_lines').select('unit_id').in('unit_id', unitIds).limit(1000),
        ]);
        [...(a.data ?? []), ...(b.data ?? [])].forEach((r: any) => used.add(r.unit_id));
      }
      const mv = await supabase.from('stock_movements').select('id', { count: 'exact', head: true }).eq('product_id', productId!);
      return { p, used, hasHistory: (mv.count ?? 0) > 0 };
    },
  });
  const variants = useQuery({
    queryKey: ['variant-parents', id],
    queryFn: async () => unwrap(await supabase.from('products').select('id,name').eq('business_id', id).eq('status', 'active').is('variant_of', null).order('name').limit(500)) as { id: string; name: string }[],
  });

  useEffect(() => {
    if (!existing.data) return;
    const p = existing.data.p;
    setF({
      name: p.name, sku: p.sku, barcode: p.barcode ?? '', category_id: p.category_id ?? '', subcategory: p.subcategory ?? '', brand: p.brand ?? '',
      description: p.description ?? '', base_unit: p.base_unit, allow_fraction: p.allow_fraction, purchase_cost: String(p.purchase_cost ?? ''),
      selling_price: String(p.selling_price ?? ''), min_stock: String(p.min_stock ?? ''), lead_time_days: p.lead_time_days?.toString() ?? '',
      min_order_qty: p.min_order_qty?.toString() ?? '', preferred_supplier_id: p.preferred_supplier_id ?? '', location: p.location ?? '',
      track_expiry: p.track_expiry, variant_of: p.variant_of ?? '', variant_label: p.variant_label ?? '', image_path: p.image_path,
    });
    setUnits((p.product_units ?? []).map((u: ProductUnit) => ({ id: u.id, key: u.id, name: u.name, factor: String(u.factor), selling_price: u.selling_price?.toString() ?? '',
      barcode: u.barcode ?? '', is_default_purchase: u.is_default_purchase, is_default_sale: u.is_default_sale, active: u.active, used: existing.data!.used.has(u.id) })));
  }, [existing.data]);

  if (!can('products.manage')) return <ErrorState error={{ message: 'permission_denied' }} />;
  if (editing && existing.isLoading) return <PageLoader />;
  if (editing && existing.error) return <ErrorState error={existing.error} />;

  const set = (k: keyof typeof blank) => (e: { target: { value: string } }) => setF((x) => ({ ...x, [k]: e.target.value }));
  const setUnit = (key: string, patch: Partial<UnitRow>) => setUnits((u) => u.map((r) => (r.key === key ? { ...r, ...patch } : patch.is_default_purchase ? { ...r, is_default_purchase: false } : patch.is_default_sale ? { ...r, is_default_sale: false } : r)));

  const onImage = async (file?: File) => {
    if (!file) return;
    setUploading(true);
    const path = await run(() => uploadFile(id, 'products', file));
    setUploading(false);
    if (path) setF((x) => ({ ...x, image_path: path }));
  };

  const submit = async (e: FormEvent) => {
    e.preventDefault();
    const result = await run(async () => {
      let categoryId = f.category_id || null;
      if (newCat && newCat.trim()) {
        const c = unwrap(await supabase.from('categories').insert({ business_id: id, name: newCat.trim() }).select('id').single()) as { id: string };
        categoryId = c.id;
      }
      const row = {
        name: f.name.trim(), sku: f.sku.trim() || `SKU-${newId().slice(0, 6).toUpperCase()}`, barcode: f.barcode.trim() || null,
        category_id: categoryId, subcategory: f.subcategory || null, brand: f.brand || null, description: f.description || null,
        base_unit: f.base_unit.trim() || 'piece', allow_fraction: f.allow_fraction, purchase_cost: toNumber(f.purchase_cost),
        selling_price: toNumber(f.selling_price), min_stock: toNumber(f.min_stock),
        lead_time_days: f.lead_time_days === '' ? null : Math.round(toNumber(f.lead_time_days)),
        min_order_qty: f.min_order_qty === '' ? null : toNumber(f.min_order_qty),
        preferred_supplier_id: f.preferred_supplier_id || null, location: f.location || null, track_expiry: f.track_expiry,
        variant_of: f.variant_of || null, variant_label: f.variant_label || null, image_path: f.image_path || null,
      };
      let pid = productId;
      if (editing) {
        unwrap(await supabase.from('products').update(row).eq('id', productId!).select('id').single());
      } else {
        const created = unwrap(await supabase.from('products').insert({ ...row, business_id: id }).select('id').single()) as { id: string };
        pid = created.id;
      }
      for (const u of units) {
        if (!u.name.trim() || toNumber(u.factor) <= 0) continue;
        const data = { name: u.name.trim(), factor: toNumber(u.factor), selling_price: u.selling_price === '' ? null : toNumber(u.selling_price),
          barcode: u.barcode.trim() || null, is_default_purchase: u.is_default_purchase, is_default_sale: u.is_default_sale, active: u.active };
        if (u.id) {
          const upd = u.used ? { ...data, factor: undefined, name: undefined } : data;
          unwrap(await supabase.from('product_units').update(JSON.parse(JSON.stringify(upd))).eq('id', u.id));
        } else {
          unwrap(await supabase.from('product_units').insert({ ...data, business_id: id, product_id: pid }));
        }
      }
      if (!editing && toNumber(opening.qty) > 0) {
        await rpc('record_opening_stock', { p_business: id, p_product: pid, p_quantity: toNumber(opening.qty),
          p_unit_cost: opening.known ? toNumber(opening.cost || f.purchase_cost) : null, p_cost_known: opening.known,
          p_batch_code: opening.batch || null, p_expiry: opening.expiry || null, p_client_ref: newId() });
      }
      return pid;
    }, t('common.saved'));
    if (result) nav(`/app/products/${result}`, { replace: true });
  };

  const margin = toNumber(f.selling_price) > 0 ? ((toNumber(f.selling_price) - toNumber(f.purchase_cost)) / toNumber(f.selling_price)) * 100 : null;

  return (
    <form onSubmit={submit}>
      <PageHeader title={editing ? t('products.editTitle') : t('products.newTitle')}
        back={<Link to={editing ? `/app/products/${productId}` : '/app/products'} className="mb-2 inline-flex items-center gap-1 text-sm text-ink-muted hover:text-ink"><ArrowLeft className="h-4 w-4" />{t('common.back')}</Link>}
        actions={<Button type="submit" loading={busy} disabled={!session}>{t('common.save')}</Button>} />
      <div className="grid gap-4 lg:grid-cols-3">
        <div className="space-y-4 lg:col-span-2">
          <Card>
            <CardHeader title={t('products.basics')} />
            <div className="grid gap-4 sm:grid-cols-2">
              <Field label={t('common.name')} required className="sm:col-span-2"><Input required value={f.name} onChange={set('name')} placeholder="Indomie Noodles 70g" /></Field>
              <Field label={t('products.sku')} hint={t('products.skuHint')}><Input value={f.sku} onChange={set('sku')} /></Field>
              <Field label={t('products.barcode')}><Input value={f.barcode} onChange={set('barcode')} inputMode="numeric" /></Field>
              <Field label={t('common.category')} htmlFor="product-category">
                {newCat === null ? (
                  <Select id="product-category" value={f.category_id} onChange={(e) => e.target.value === '__new' ? setNewCat('') : setF((x) => ({ ...x, category_id: e.target.value }))}>
                    <option value="">—</option>
                    {(cats.data ?? []).map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}
                    <option value="__new">+ {t('products.newCategory')}</option>
                  </Select>
                ) : (
                  <div className="flex gap-2"><Input autoFocus value={newCat} onChange={(e) => setNewCat(e.target.value)} placeholder={t('products.newCategory')} />
                    <Button variant="ghost" onClick={() => setNewCat(null)}>{t('common.cancel')}</Button></div>
                )}
              </Field>
              <Field label={t('products.subcategory')}><Input value={f.subcategory} onChange={set('subcategory')} /></Field>
              <Field label={t('products.brand')}><Input value={f.brand} onChange={set('brand')} /></Field>
              <Field label={t('products.location')} hint={t('products.locationHint')}><Input value={f.location} onChange={set('location')} /></Field>
              <Field label={t('common.description')} className="sm:col-span-2"><Textarea rows={2} value={f.description} onChange={set('description')} /></Field>
            </div>
          </Card>

          <Card>
            <CardHeader title={t('products.pricing')} subtitle={t('products.pricingSub')} />
            <div className="grid gap-4 sm:grid-cols-3">
              <Field label={t('products.baseUnit')} hint={t('products.baseUnitHint')}>
                <Input list="unit-suggestions" value={f.base_unit} onChange={set('base_unit')} disabled={editing && existing.data?.hasHistory} />
                <datalist id="unit-suggestions">{UNITS.map((u) => <option key={u} value={u} />)}</datalist>
              </Field>
              <Field label={t('products.purchaseCost')} hint={t('products.purchaseCostHint')}><Input type="number" min="0" step="any" inputMode="decimal" value={f.purchase_cost} onChange={set('purchase_cost')} suffix="FCFA" /></Field>
              <Field label={t('products.sellingPrice')} hint={margin !== null ? t('products.marginPreview', { pct: margin.toFixed(1) }) : undefined}><Input type="number" min="0" step="any" inputMode="decimal" required value={f.selling_price} onChange={set('selling_price')} suffix="FCFA" /></Field>
            </div>
            <div className="mt-4"><Checkbox checked={f.allow_fraction} onChange={(v) => setF((x) => ({ ...x, allow_fraction: v }))} label={t('products.allowFraction')} hint={t('products.allowFractionHint')} /></div>
          </Card>

          <Card>
            <CardHeader title={t('products.units')} subtitle={t('products.unitsSub', { unit: f.base_unit || 'piece' })}
              action={<Button size="sm" variant="secondary" icon={<Plus className="h-4 w-4" />} onClick={() => setUnits((u) => [...u, { key: newId(), name: '', factor: '', selling_price: '', barcode: '', is_default_purchase: u.length === 0, is_default_sale: false, active: true }])}>{t('products.addUnit')}</Button>} />
            {units.length === 0 ? <p className="text-sm text-ink-muted">{t('products.noUnits')}</p> : (
              <div className="space-y-3">
                {units.map((u) => (
                  <div key={u.key} className="grid gap-3 rounded-xl border border-gray-200 p-3 dark:border-gray-800 sm:grid-cols-12">
                    <Field label={t('products.unitName')} className="sm:col-span-3"><Input list="unit-suggestions" value={u.name} disabled={u.used} onChange={(e) => setUnit(u.key, { name: e.target.value })} placeholder="carton" /></Field>
                    <Field label={t('products.unitFactor', { unit: f.base_unit })} className="sm:col-span-3" hint={u.used ? t('products.unitLocked') : undefined}><Input type="number" min="0" step="any" value={u.factor} disabled={u.used} onChange={(e) => setUnit(u.key, { factor: e.target.value })} placeholder="24" /></Field>
                    <Field label={t('products.unitPrice')} className="sm:col-span-3"><Input type="number" min="0" step="any" value={u.selling_price} onChange={(e) => setUnit(u.key, { selling_price: e.target.value })} placeholder={toNumber(u.factor) && toNumber(f.selling_price) ? String(toNumber(u.factor) * toNumber(f.selling_price)) : ''} suffix="FCFA" /></Field>
                    <Field label={t('products.barcode')} className="sm:col-span-3"><Input value={u.barcode} onChange={(e) => setUnit(u.key, { barcode: e.target.value })} /></Field>
                    <div className="flex flex-wrap items-center gap-4 sm:col-span-12">
                      <Checkbox checked={u.is_default_purchase} onChange={(v) => setUnit(u.key, { is_default_purchase: v })} label={t('products.defaultPurchase')} />
                      <Checkbox checked={u.is_default_sale} onChange={(v) => setUnit(u.key, { is_default_sale: v })} label={t('products.defaultSale')} />
                      <Checkbox checked={u.active} onChange={(v) => setUnit(u.key, { active: v })} label={t('common.active')} />
                      {!u.id && <Button size="sm" variant="ghost" className="ml-auto text-red-600" icon={<Trash2 className="h-4 w-4" />} onClick={() => setUnits((x) => x.filter((r) => r.key !== u.key))}>{t('common.delete')}</Button>}
                    </div>
                  </div>
                ))}
              </div>
            )}
          </Card>

          {!editing && (
            <Card>
              <CardHeader title={t('products.openingStock')} subtitle={t('products.openingStockSub')} />
              <div className="grid gap-4 sm:grid-cols-3">
                <Field label={t('products.openingQty', { unit: f.base_unit })}><Input type="number" min="0" step="any" value={opening.qty} onChange={(e) => setOpening((o) => ({ ...o, qty: e.target.value }))} /></Field>
                <Field label={t('products.openingCost', { unit: f.base_unit })} hint={!opening.known ? t('products.costUnknownHint') : undefined}>
                  <Input type="number" min="0" step="any" disabled={!opening.known} value={opening.known ? opening.cost : ''} placeholder={f.purchase_cost} onChange={(e) => setOpening((o) => ({ ...o, cost: e.target.value }))} suffix="FCFA" />
                </Field>
                <div className="pt-7"><Checkbox checked={!opening.known} onChange={(v) => setOpening((o) => ({ ...o, known: !v }))} label={t('products.costUnknown')} /></div>
                {f.track_expiry && <>
                  <Field label={t('inventory.batchCode')}><Input value={opening.batch} onChange={(e) => setOpening((o) => ({ ...o, batch: e.target.value }))} /></Field>
                  <Field label={t('inventory.expiryDate')}><Input type="date" value={opening.expiry} onChange={(e) => setOpening((o) => ({ ...o, expiry: e.target.value }))} /></Field>
                </>}
              </div>
            </Card>
          )}
        </div>

        <div className="space-y-4">
          <Card>
            <CardHeader title={t('products.image')} />
            <label className="flex aspect-square cursor-pointer flex-col items-center justify-center gap-2 overflow-hidden rounded-xl border-2 border-dashed border-gray-300 text-sm text-ink-muted hover:border-brand-500 dark:border-gray-700">
              {img.data ? <img src={img.data} alt="" className="h-full w-full object-cover" /> : <><ImagePlus className="h-8 w-8" />{uploading ? t('common.loading') : t('products.addImage')}</>}
              <input type="file" accept="image/png,image/jpeg,image/webp" className="sr-only" onChange={(e) => onImage(e.target.files?.[0])} />
            </label>
            {f.image_path && <Button size="sm" variant="ghost" className="mt-2" onClick={() => setF((x) => ({ ...x, image_path: null }))}>{t('products.removeImage')}</Button>}
          </Card>
          <Card>
            <CardHeader title={t('products.stockSettings')} />
            <div className="space-y-4">
              <Field label={t('products.minStock', { unit: f.base_unit })} hint={t('products.minStockHint')}><Input type="number" min="0" step="any" value={f.min_stock} onChange={set('min_stock')} /></Field>
              {has('suppliers') && (
                <Field label={t('products.preferredSupplier')}>
                  <Select value={f.preferred_supplier_id} onChange={set('preferred_supplier_id')}>
                    <option value="">—</option>{(sups.data ?? []).map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}
                  </Select>
                </Field>
              )}
              <Field label={t('products.leadTime')} hint={t('products.leadTimeHint')}><Input type="number" min="0" max="365" value={f.lead_time_days} onChange={set('lead_time_days')} suffix={t('common.days')} /></Field>
              <Field label={t('products.minOrderQty', { unit: f.base_unit })}><Input type="number" min="0" step="any" value={f.min_order_qty} onChange={set('min_order_qty')} /></Field>
              {has('batch_tracking') ? <Checkbox checked={f.track_expiry} onChange={(v) => setF((x) => ({ ...x, track_expiry: v }))} label={t('products.trackExpiry')} hint={t('products.trackExpiryHint')} />
                : <UpgradeNotice feature="batch_tracking" compact />}
            </div>
          </Card>
          <Card>
            <CardHeader title={t('products.variant')} subtitle={t('products.variantSub')} />
            <div className="space-y-4">
              <Field label={t('products.variantOf')}>
                <Select value={f.variant_of} onChange={set('variant_of')}>
                  <option value="">—</option>{(variants.data ?? []).filter((v) => v.id !== productId).map((v) => <option key={v.id} value={v.id}>{v.name}</option>)}
                </Select>
              </Field>
              <Field label={t('products.variantLabel')}><Input value={f.variant_label} onChange={set('variant_label')} placeholder="500 ml, XL, Red…" /></Field>
            </div>
          </Card>
          {editing && <Alert tone="blue">{t('products.stockEditNote')}</Alert>}
        </div>
      </div>
      <div className="mt-6 flex justify-end"><Button type="submit" size="lg" loading={busy}>{t('common.save')}</Button></div>
    </form>
  );
}
