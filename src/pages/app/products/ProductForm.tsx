import { FormEvent, ReactNode, useEffect, useState } from 'react';
import { Link, useNavigate, useParams } from 'react-router-dom';
import { useQuery } from '@tanstack/react-query';
import { ArrowLeft, Camera, ChevronDown, Copy, Globe, ImagePlus, Plus, Trash2 } from 'lucide-react';
import clsx from 'clsx';
import { useI18n } from '../../../i18n';
import { useBiz } from '../../../lib/business';
import { useAuth } from '../../../lib/auth';
import { supabase } from '../../../lib/supabase';
import { rpc, unwrap } from '../../../lib/api';
import { Product, ProductUnit, subcategoriesOf, uploadFile, useBusinessRow, useCategoryTree, useDbUpgraded, useSignedUrl, useSuppliers } from '../../../lib/hooks';
import { useAction } from '../../../lib/useAction';
import { newId } from '../../../lib/ids';
import { toNumber } from '../../../lib/format';
import { ATTRIBUTE_FIELDS, barcodeProblem, COMMON_UNITS, DEFAULT_ATTRIBUTE_SET, type AttributeSet, type BusinessType } from '../../../lib/catalogTemplates';
import { Alert, Button, Card, Checkbox, ErrorState, Field, Input, PageHeader, PageLoader, Select, Textarea, UpgradeNotice } from '../../../components/ui';
import { CameraScanner } from '../../../components/ProductPicker';
import { VariantGenerator, variantPayload, type VariantOption, type VariantRow } from '../../../components/VariantGenerator';
import { publicUrl, uploadStorefrontImage, useMarketConfig } from '../../../lib/market';

interface UnitRow { id?: string; key: string; name: string; factor: string; selling_price: string; barcode: string; is_default_purchase: boolean; is_default_sale: boolean; active: boolean; used?: boolean }

const blank = {
  name: '', sku: '', barcode: '', category_id: '', subcategory: '', brand: '', description: '', base_unit: 'piece',
  allow_fraction: false, purchase_cost: '', selling_price: '', min_stock: '', lead_time_days: '', min_order_qty: '',
  preferred_supplier_id: '', location: '', track_expiry: false, variant_of: '', variant_label: '', image_path: '' as string | null,
  online_published: false, online_images: [] as string[], compare_at_price: '',
};
type SectionKey = 'pricing' | 'identifiers' | 'variants' | 'details' | 'online' | 'more';

// Collapsible card: keeps the form short; optional sections open on demand.
function Section({ id, title, subtitle, open, onToggle, children, optional }:
  { id: string; title: string; subtitle?: string; open: boolean; onToggle: () => void; children: ReactNode; optional?: boolean }) {
  const { t } = useI18n();
  return (
    <Card padded={false}>
      <h2>
        <button type="button" aria-expanded={open} aria-controls={`section-${id}`} onClick={onToggle}
          className="flex w-full items-start justify-between gap-3 rounded-2xl px-4 py-4 text-left sm:px-5">
          <span>
            <span className="block text-base font-bold text-ink dark:text-white">{title}{optional && <span className="ml-2 text-xs font-normal text-ink-muted">({t('catalog.optional')})</span>}</span>
            {subtitle && <span className="mt-0.5 block text-sm font-normal text-ink-muted dark:text-gray-400">{subtitle}</span>}
          </span>
          <ChevronDown className={clsx('mt-1 h-5 w-5 shrink-0 text-ink-muted transition', open && 'rotate-180')} />
        </button>
      </h2>
      {open && <div id={`section-${id}`} className="border-t border-gray-100 px-4 pb-5 pt-4 dark:border-gray-800 sm:px-5">{children}</div>}
    </Card>
  );
}

export default function ProductForm() {
  const { id: productId } = useParams();
  const editing = Boolean(productId);
  const { t, tv } = useI18n();
  const { id, can, has } = useBiz();
  const { session } = useAuth();
  const nav = useNavigate();
  const { run, busy } = useAction();
  const tree = useCategoryTree(id);
  const upgraded = useDbUpgraded() !== false;
  const bizRow = useBusinessRow(id);
  const sups = useSuppliers(id, has('suppliers'));
  const [f, setF] = useState(blank);
  const [attrs, setAttrs] = useState<Record<string, string>>({});
  const [units, setUnits] = useState<UnitRow[]>([]);
  const [opening, setOpening] = useState({ qty: '', cost: '', known: true, batch: '', expiry: '' });
  const [newCat, setNewCat] = useState<string | null>(null);
  const [uploading, setUploading] = useState(false);
  const [scanning, setScanning] = useState(false);
  const [open, setOpen] = useState<Record<SectionKey, boolean>>({ pricing: true, identifiers: false, variants: false, details: false, online: false, more: false });
  const market = Boolean(useMarketConfig().data);
  const [onlineUploading, setOnlineUploading] = useState(false);
  const [useVariants, setUseVariants] = useState(false);
  const [vOptions, setVOptions] = useState<VariantOption[]>([{ name: '', values: '' }]);
  const [vRows, setVRows] = useState<VariantRow[]>([]);
  const img = useSignedUrl(f.image_path || null);
  const toggle = (k: SectionKey) => setOpen((o) => ({ ...o, [k]: !o[k] }));
  const hasCamera = typeof window !== 'undefined' && 'BarcodeDetector' in window && !!navigator.mediaDevices?.getUserMedia;

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
      const kids = unwrap(await supabase.from('products').select('id,variant_label,selling_price,qty_on_hand,sku').eq('variant_of', productId!).order('variant_label')) as any[];
      return { p, used, hasHistory: (mv.count ?? 0) > 0, kids };
    },
  });
  const parents = useQuery({
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
      online_published: Boolean(p.online_published), online_images: p.online_images ?? [], compare_at_price: p.compare_at_price?.toString() ?? '',
    });
    setAttrs(Object.fromEntries(Object.entries(p.attributes ?? {}).map(([k, v]) => [k, String(v)])));
    setUnits((p.product_units ?? []).map((u: ProductUnit) => ({ id: u.id, key: u.id, name: u.name, factor: String(u.factor), selling_price: u.selling_price?.toString() ?? '',
      barcode: u.barcode ?? '', is_default_purchase: u.is_default_purchase, is_default_sale: u.is_default_sale, active: u.active, used: existing.data!.used.has(u.id) })));
    // Open the sections that already hold information.
    setOpen({ pricing: true, identifiers: true, variants: existing.data.kids.length > 0 || Boolean(p.variant_of),
      details: Boolean(p.description || p.image_path || Object.keys(p.attributes ?? {}).length), online: Boolean(p.online_published || p.online_images?.length), more: Boolean(p.preferred_supplier_id || p.location || (p.product_units ?? []).length) });
  }, [existing.data]);

  if (!can('products.manage')) return <ErrorState error={{ message: 'permission_denied' }} />;
  if (editing && existing.isLoading) return <PageLoader />;
  if (editing && existing.error) return <ErrorState error={existing.error} />;

  const all = tree.data ?? [];
  const tops = all.filter((c) => !c.parent_id && (!c.archived_at || c.id === f.category_id));
  const subs = subcategoriesOf(all, f.category_id || null);
  const selectedCat = all.find((c) => c.id === f.category_id);
  const attrSet = ((selectedCat?.attribute_set as AttributeSet | null) ?? DEFAULT_ATTRIBUTE_SET[(bizRow.data?.category as BusinessType) ?? 'general'] ?? 'general') as AttributeSet;
  const attrFields = ATTRIBUTE_FIELDS[attrSet] ?? ATTRIBUTE_FIELDS.general;
  // Attributes saved under another set stay visible (and editable) when the category changes.
  const extraAttrKeys = Object.keys(attrs).filter((k) => !attrFields.some((a) => a.key === k));
  const attrLabels = tv<Record<string, string>>('catalog.attr');
  const isParent = editing && (existing.data?.kids.length ?? 0) > 0;
  const variantsWanted = upgraded && useVariants && !f.variant_of;
  const barcodeWarn = f.barcode ? barcodeProblem(f.barcode) : null;

  const set = (k: keyof typeof blank) => (e: { target: { value: string } }) => setF((x) => ({ ...x, [k]: e.target.value }));
  const setUnit = (key: string, patch: Partial<UnitRow>) => setUnits((u) => u.map((r) => (r.key === key ? { ...r, ...patch } : patch.is_default_purchase ? { ...r, is_default_purchase: false } : patch.is_default_sale ? { ...r, is_default_sale: false } : r)));

  const addOnlineImage = async (file?: Blob, name?: string) => {
    if (!file) return;
    setOnlineUploading(true);
    const path = await run(() => uploadStorefrontImage(id, 'products', file, name));
    setOnlineUploading(false);
    if (path) setF((x) => ({ ...x, online_images: [...x.online_images, path].slice(0, 8) }));
  };
  // Copies the private shop photo into the public storefront (the shop photo itself stays private).
  const copyShopPhoto = async () => {
    if (!img.data) return;
    const blob = await (await fetch(img.data)).blob();
    await addOnlineImage(blob, f.image_path ?? 'photo.jpg');
  };

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
      const attributes = Object.fromEntries(Object.entries(attrs).map(([k, v]) => [k, v.trim()]).filter(([, v]) => v !== ''));
      const row = {
        // Blank SKU → generated by the server (a previous database needs one from the app).
        name: f.name.trim(), sku: f.sku.trim() || (upgraded ? '' : `SKU-${newId().slice(0, 6).toUpperCase()}`), barcode: f.barcode.trim() || null,
        category_id: categoryId, subcategory: f.subcategory.trim() || null, brand: f.brand.trim() || null, description: f.description.trim() || null,
        base_unit: f.base_unit.trim() || 'piece', allow_fraction: f.allow_fraction, purchase_cost: toNumber(f.purchase_cost),
        selling_price: toNumber(f.selling_price), min_stock: toNumber(f.min_stock),
        lead_time_days: f.lead_time_days === '' ? null : Math.round(toNumber(f.lead_time_days)),
        min_order_qty: f.min_order_qty === '' ? null : toNumber(f.min_order_qty),
        preferred_supplier_id: f.preferred_supplier_id || null, location: f.location.trim() || null, track_expiry: f.track_expiry,
        variant_of: f.variant_of || null, variant_label: f.variant_of ? f.variant_label.trim() || null : null, image_path: f.image_path || null,
        ...(upgraded ? { attributes } : {}),
        // Online-store fields exist only once the marketplace database upgrade is applied.
        ...(market ? { online_images: f.online_images, compare_at_price: f.compare_at_price === '' ? null : toNumber(f.compare_at_price),
          ...(f.variant_of ? {} : { online_published: f.online_published }) } : {}),
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
      if (variantsWanted) {
        const payload = variantPayload(vRows, vOptions, attrLabels, { cost: opening.cost || f.purchase_cost, known: opening.known });
        if (payload.length) await rpc('add_product_variants', { p_business: id, p_parent: pid, p_variants: payload });
      } else if (!editing && toNumber(opening.qty) > 0) {
        await rpc('record_opening_stock', { p_business: id, p_product: pid, p_quantity: toNumber(opening.qty),
          p_unit_cost: opening.known ? toNumber(opening.cost || f.purchase_cost) : null, p_cost_known: opening.known,
          p_batch_code: opening.batch || null, p_expiry: opening.expiry || null, p_client_ref: newId() });
      }
      return pid;
    }, t('common.saved'));
    if (result) nav(`/app/products/${result}`, { replace: true });
  };

  const margin = toNumber(f.selling_price) > 0 && f.purchase_cost !== '' ? ((toNumber(f.selling_price) - toNumber(f.purchase_cost)) / toNumber(f.selling_price)) * 100 : null;

  return (
    <form onSubmit={submit} noValidate={false}>
      <PageHeader title={editing ? t('products.editTitle') : t('products.newTitle')}
        back={<Link to={editing ? `/app/products/${productId}` : '/app/products'} className="mb-2 inline-flex items-center gap-1 text-sm text-ink-muted hover:text-ink"><ArrowLeft className="h-4 w-4" />{t('common.back')}</Link>}
        actions={<Button type="submit" loading={busy} disabled={!session}>{t('common.save')}</Button>} />
      <div className="mx-auto max-w-3xl space-y-4">
        <Card>
          <h2 className="text-base font-bold">{t('catalog.sections.basic')}</h2>
          <p className="mb-4 text-sm text-ink-muted dark:text-gray-400">{t('catalog.sections.basicSub')}</p>
          <div className="grid gap-4 sm:grid-cols-2">
            <Field label={t('common.name')} required className="sm:col-span-2"><Input required maxLength={160} value={f.name} onChange={set('name')} placeholder="T-shirt col V coton" /></Field>
            <Field label={t('products.sellingPrice')} required hint={margin !== null ? t('products.marginPreview', { pct: margin.toFixed(1) }) : undefined}>
              <Input type="number" min="0" step="any" inputMode="decimal" required value={f.selling_price} onChange={set('selling_price')} suffix="FCFA" />
            </Field>
            <Field label={t('products.brand')} optional><Input value={f.brand} onChange={set('brand')} /></Field>
            <Field label={t('common.category')} optional htmlFor="product-category" hint={<Link to="/app/products/categories" className="font-semibold text-brand-700 hover:underline">{t('catalog.manageCategories')}</Link>}>
              {newCat === null ? (
                <Select id="product-category" value={f.category_id} onChange={(e) => e.target.value === '__new' ? setNewCat('') : setF((x) => ({ ...x, category_id: e.target.value, subcategory: '' }))}>
                  <option value="">{t('catalog.noCategoryOption')}</option>
                  {tops.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}
                  <option value="__new">+ {t('products.newCategory')}</option>
                </Select>
              ) : (
                <div className="flex gap-2"><Input autoFocus value={newCat} onChange={(e) => setNewCat(e.target.value)} placeholder={t('products.newCategory')} aria-label={t('products.newCategory')} />
                  <Button variant="ghost" onClick={() => setNewCat(null)}>{t('common.cancel')}</Button></div>
              )}
            </Field>
            <Field label={t('products.subcategory')} optional>
              <Input list="subcategory-options" value={f.subcategory} onChange={set('subcategory')} placeholder={subs.length ? t('catalog.chooseSubcategory') : ''} />
              <datalist id="subcategory-options">{subs.map((s) => <option key={s.id} value={s.name} />)}</datalist>
            </Field>
          </div>
        </Card>

        <Section id="pricing" title={t('catalog.sections.pricing')} subtitle={t('catalog.sections.pricingSub')} open={open.pricing} onToggle={() => toggle('pricing')} optional>
          <div className="grid gap-4 sm:grid-cols-2">
            <Field label={t('products.purchaseCost')} optional hint={t('products.purchaseCostHint')}><Input type="number" min="0" step="any" inputMode="decimal" value={f.purchase_cost} onChange={set('purchase_cost')} suffix="FCFA" /></Field>
            <Field label={t('products.baseUnit')} optional hint={t('products.baseUnitHint')}>
              <Input list="unit-suggestions" value={f.base_unit} onChange={set('base_unit')} disabled={editing && existing.data?.hasHistory} />
              <datalist id="unit-suggestions">{COMMON_UNITS.map((u) => <option key={u} value={u} />)}</datalist>
            </Field>
            <Field label={t('products.minStock', { unit: f.base_unit })} optional hint={t('products.minStockHint')}><Input type="number" min="0" step="any" value={f.min_stock} onChange={set('min_stock')} /></Field>
            <div className="sm:pt-7"><Checkbox checked={f.allow_fraction} onChange={(v) => setF((x) => ({ ...x, allow_fraction: v }))} label={t('products.allowFraction')} hint={t('products.allowFractionHint')} /></div>
          </div>
          {!editing && !variantsWanted && (
            <div className="mt-5 rounded-xl bg-gray-50 p-4 dark:bg-gray-900">
              <p className="text-sm font-semibold">{t('products.openingStock')} <span className="text-xs font-normal text-ink-muted">({t('catalog.optional')})</span></p>
              <p className="mb-3 text-xs text-ink-muted">{t('products.openingStockSub')}</p>
              <div className="grid gap-4 sm:grid-cols-3">
                <Field label={t('products.openingQty', { unit: f.base_unit })}><Input type="number" min="0" step="any" value={opening.qty} onChange={(e) => setOpening((o) => ({ ...o, qty: e.target.value }))} /></Field>
                <Field label={t('products.openingCost', { unit: f.base_unit })} hint={!opening.known ? t('products.costUnknownHint') : undefined}>
                  <Input type="number" min="0" step="any" disabled={!opening.known} value={opening.known ? opening.cost : ''} placeholder={f.purchase_cost} onChange={(e) => setOpening((o) => ({ ...o, cost: e.target.value }))} suffix="FCFA" />
                </Field>
                <div className="sm:pt-7"><Checkbox checked={!opening.known} onChange={(v) => setOpening((o) => ({ ...o, known: !v }))} label={t('products.costUnknown')} /></div>
                {f.track_expiry && <>
                  <Field label={t('inventory.batchCode')} optional><Input value={opening.batch} onChange={(e) => setOpening((o) => ({ ...o, batch: e.target.value }))} /></Field>
                  <Field label={t('inventory.expiryDate')} optional><Input type="date" value={opening.expiry} onChange={(e) => setOpening((o) => ({ ...o, expiry: e.target.value }))} /></Field>
                </>}
              </div>
            </div>
          )}
          <div className="mt-4">
            {has('batch_tracking') ? <Checkbox checked={f.track_expiry} onChange={(v) => setF((x) => ({ ...x, track_expiry: v }))} label={t('products.trackExpiry')} hint={t('products.trackExpiryHint')} />
              : <UpgradeNotice feature="batch_tracking" compact />}
          </div>
          {editing && <div className="mt-4"><Alert tone="blue">{t('products.stockEditNote')}</Alert></div>}
        </Section>

        <Section id="identifiers" title={t('catalog.sections.identifiers')} subtitle={t('catalog.sections.identifiersSub')} open={open.identifiers} onToggle={() => toggle('identifiers')} optional>
          <div className="grid gap-4 sm:grid-cols-2">
            <Field label={t('products.sku')} optional hint={t('products.skuHint')}><Input value={f.sku} onChange={set('sku')} maxLength={64} autoCapitalize="characters" placeholder={editing ? '' : 'SKU-…'} /></Field>
            <Field label={t('products.barcode')} optional htmlFor="product-barcode" hint={barcodeWarn ? <span className="text-amber-700 dark:text-amber-400">{t('catalog.barcodeCheckDigit')}</span> : t('products.barcodeHint')}>
              <div className="flex gap-2">
                <div className="flex-1"><Input id="product-barcode" value={f.barcode} onChange={set('barcode')} inputMode="numeric" maxLength={64} /></div>
                {hasCamera && <Button variant="outline" onClick={() => setScanning(true)} icon={<Camera className="h-4 w-4" />}>{t('catalog.scanBarcode')}</Button>}
              </div>
            </Field>
          </div>
          {scanning && <CameraScanner onClose={() => setScanning(false)} onCode={(code) => { setScanning(false); setF((x) => ({ ...x, barcode: code })); }} />}
        </Section>

        <Section id="variants" title={t('catalog.sections.variants')} subtitle={t('catalog.sections.variantsSub')} open={open.variants} onToggle={() => toggle('variants')} optional>
          {f.variant_of ? (
            <div className="grid gap-4 sm:grid-cols-2">
              <Field label={t('catalog.variantOf')}>
                <Select value={f.variant_of} onChange={set('variant_of')}>
                  <option value="">—</option>{(parents.data ?? []).filter((v) => v.id !== productId).map((v) => <option key={v.id} value={v.id}>{v.name}</option>)}
                </Select>
              </Field>
              <Field label={t('products.variantLabel')} required><Input required value={f.variant_label} onChange={set('variant_label')} placeholder="M / Black, 500 ml…" /></Field>
              <div className="sm:col-span-2"><Link to={`/app/products/${f.variant_of}`} className="text-sm font-semibold text-brand-700 hover:underline">{t('catalog.openParent')}</Link></div>
            </div>
          ) : (
            <div className="space-y-4">
              {isParent && (
                <div>
                  <p className="mb-2 text-sm font-semibold">{t('catalog.existingVariants')}</p>
                  <ul className="divide-y divide-gray-100 rounded-xl border border-gray-200 text-sm dark:divide-gray-800 dark:border-gray-800">
                    {existing.data!.kids.map((k) => (
                      <li key={k.id} className="flex items-center justify-between gap-3 px-3 py-2">
                        <Link to={`/app/products/${k.id}`} className="font-medium hover:underline">{k.variant_label}</Link>
                        <span className="text-xs text-ink-muted">{k.sku} · {Number(k.selling_price).toLocaleString()} FCFA · {Number(k.qty_on_hand)} {f.base_unit}</span>
                      </li>
                    ))}
                  </ul>
                </div>
              )}
              {upgraded ? <Checkbox checked={useVariants} onChange={setUseVariants} label={t('catalog.variantCreate')} /> : <Alert tone="blue">{t('catalog.upgradeNeeded')}</Alert>}
              {useVariants && <VariantGenerator options={vOptions} onOptions={setVOptions} rows={vRows} onRows={setVRows} defaultPrice={f.selling_price} unit={f.base_unit} />}
              {!useVariants && !isParent && (parents.data ?? []).length > 0 && (
                <details className="text-sm">
                  <summary className="cursor-pointer text-ink-muted">{t('products.variantSub')}</summary>
                  <div className="mt-3 grid gap-4 sm:grid-cols-2">
                    <Field label={t('products.variantOf')} optional>
                      <Select value={f.variant_of} onChange={set('variant_of')}>
                        <option value="">—</option>{(parents.data ?? []).filter((v) => v.id !== productId).map((v) => <option key={v.id} value={v.id}>{v.name}</option>)}
                      </Select>
                    </Field>
                  </div>
                </details>
              )}
            </div>
          )}
        </Section>

        <Section id="details" title={t('catalog.sections.details')} subtitle={t('catalog.sections.detailsSub')} open={open.details} onToggle={() => toggle('details')} optional>
          <div className="grid gap-4 sm:grid-cols-2">
            {!upgraded && <div className="sm:col-span-2"><Alert tone="blue">{t('catalog.upgradeNeeded')}</Alert></div>}
            {upgraded && attrFields.map((a) => (
              <Field key={a.key} label={attrLabels[a.key] ?? a.key} optional>
                {a.kind === 'select' ? (
                  <Select value={attrs[a.key] ?? ''} onChange={(e) => setAttrs((x) => ({ ...x, [a.key]: e.target.value }))}>
                    <option value="">—</option>
                    {a.options!.map((o) => <option key={o} value={o}>{t(`catalog.opt.${o}`)}</option>)}
                  </Select>
                ) : (
                  <Input type={a.kind === 'number' ? 'number' : 'text'} min={a.kind === 'number' ? 0 : undefined} value={attrs[a.key] ?? ''} placeholder={a.placeholder}
                    suffix={a.unit === 'months' ? t('catalog.months') : undefined} onChange={(e) => setAttrs((x) => ({ ...x, [a.key]: e.target.value }))} maxLength={120} />
                )}
              </Field>
            ))}
            {upgraded && extraAttrKeys.map((k) => (
              <Field key={k} label={attrLabels[k] ?? k} optional><Input value={attrs[k] ?? ''} onChange={(e) => setAttrs((x) => ({ ...x, [k]: e.target.value }))} maxLength={120} /></Field>
            ))}
            <Field label={t('common.description')} optional className="sm:col-span-2"><Textarea rows={2} value={f.description} onChange={set('description')} /></Field>
            <div className="sm:col-span-2">
              <p className="mb-1.5 text-sm font-medium text-ink-soft dark:text-gray-300">{t('products.image')} <span className="text-xs font-normal text-ink-muted">({t('catalog.optional')})</span></p>
              <div className="flex items-center gap-4">
                <label className="flex h-28 w-28 shrink-0 cursor-pointer flex-col items-center justify-center gap-1 overflow-hidden rounded-xl border-2 border-dashed border-gray-300 text-xs text-ink-muted hover:border-brand-500 dark:border-gray-700">
                  {img.data ? <img src={img.data} alt="" className="h-full w-full object-cover" /> : <><ImagePlus className="h-6 w-6" />{uploading ? t('common.loading') : t('products.addImage')}</>}
                  <input type="file" accept="image/png,image/jpeg,image/webp" className="sr-only" onChange={(e) => onImage(e.target.files?.[0])} />
                </label>
                {f.image_path && <Button size="sm" variant="ghost" onClick={() => setF((x) => ({ ...x, image_path: null }))}>{t('products.removeImage')}</Button>}
              </div>
            </div>
          </div>
        </Section>

        {market && !f.variant_of && (
          <Section id="online" title={t('seller.product.sectionTitle')} subtitle={t('seller.product.sectionSub')} open={open.online} onToggle={() => toggle('online')} optional>
            <div className="space-y-4">
              <Checkbox checked={f.online_published} onChange={(v) => setF((x) => ({ ...x, online_published: v }))} label={t('seller.product.publish')}
                hint={isParent || useVariants ? t('seller.product.publishVariantsHint') : t('seller.product.publishHint')} />
              <Field label={t('seller.product.comparePrice')} optional hint={t('seller.product.comparePriceHint')}>
                <Input type="number" min="0" step="any" inputMode="decimal" value={f.compare_at_price} onChange={set('compare_at_price')} suffix="FCFA" />
              </Field>
              <div>
                <p className="mb-1.5 text-sm font-medium text-ink-soft dark:text-gray-300">{t('seller.product.photos')} <span className="text-xs font-normal text-ink-muted">({t('seller.product.photosHint')})</span></p>
                <div className="flex flex-wrap gap-3">
                  {f.online_images.map((p, i) => (
                    <div key={p} className="relative h-24 w-24 overflow-hidden rounded-xl border border-gray-200 dark:border-gray-700">
                      <img src={publicUrl(p) ?? ''} alt={t('seller.product.photoN', { n: i + 1 })} className="h-full w-full object-cover" />
                      {i === 0 && <span className="absolute left-1 top-1 rounded bg-brand-700 px-1.5 text-[10px] font-bold text-white">{t('seller.product.main')}</span>}
                      <button type="button" aria-label={t('seller.product.removePhoto', { n: i + 1 })} onClick={() => setF((x) => ({ ...x, online_images: x.online_images.filter((y) => y !== p) }))}
                        className="absolute right-1 top-1 rounded-full bg-white/90 p-1 text-red-600 shadow"><Trash2 className="h-3.5 w-3.5" /></button>
                    </div>
                  ))}
                  {f.online_images.length < 8 && (
                    <label className="flex h-24 w-24 cursor-pointer flex-col items-center justify-center gap-1 rounded-xl border-2 border-dashed border-gray-300 text-xs text-ink-muted hover:border-brand-500 dark:border-gray-700">
                      <ImagePlus className="h-6 w-6" />{onlineUploading ? t('common.loading') : t('products.addImage')}
                      <input type="file" accept="image/png,image/jpeg,image/webp" className="sr-only" onChange={(e) => addOnlineImage(e.target.files?.[0], e.target.files?.[0]?.name)} />
                    </label>
                  )}
                </div>
                {img.data && f.online_images.length < 8 && (
                  <Button size="sm" variant="ghost" className="mt-2" icon={<Copy className="h-4 w-4" />} onClick={copyShopPhoto}>{t('seller.product.useShopPhoto')}</Button>
                )}
                <p className="mt-2 flex items-start gap-1.5 text-xs text-ink-muted"><Globe className="mt-0.5 h-3.5 w-3.5 shrink-0" />{t('seller.product.photosPublic')}</p>
              </div>
            </div>
          </Section>
        )}

        <Section id="more" title={t('catalog.sections.more')} subtitle={t('catalog.sections.moreSub')} open={open.more} onToggle={() => toggle('more')} optional>
          <div className="grid gap-4 sm:grid-cols-2">
            {has('suppliers') && (
              <Field label={t('products.preferredSupplier')} optional>
                <Select value={f.preferred_supplier_id} onChange={set('preferred_supplier_id')}>
                  <option value="">—</option>{(sups.data ?? []).map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}
                </Select>
              </Field>
            )}
            <Field label={t('products.location')} optional hint={t('products.locationHint')}><Input value={f.location} onChange={set('location')} /></Field>
            <Field label={t('products.leadTime')} optional hint={t('products.leadTimeHint')}><Input type="number" min="0" max="365" value={f.lead_time_days} onChange={set('lead_time_days')} suffix={t('common.days')} /></Field>
            <Field label={t('products.minOrderQty', { unit: f.base_unit })} optional><Input type="number" min="0" step="any" value={f.min_order_qty} onChange={set('min_order_qty')} /></Field>
          </div>
          <div className="mt-5">
            <div className="mb-2 flex items-center justify-between gap-3">
              <div><p className="text-sm font-semibold">{t('products.units')}</p><p className="text-xs text-ink-muted">{t('products.unitsSub', { unit: f.base_unit || 'piece' })}</p></div>
              <Button size="sm" variant="secondary" icon={<Plus className="h-4 w-4" />} onClick={() => setUnits((u) => [...u, { key: newId(), name: '', factor: '', selling_price: '', barcode: '', is_default_purchase: u.length === 0, is_default_sale: false, active: true }])}>{t('products.addUnit')}</Button>
            </div>
            {units.length === 0 ? <p className="text-sm text-ink-muted">{t('products.noUnits')}</p> : (
              <div className="space-y-3">
                {units.map((u) => (
                  <div key={u.key} className="grid gap-3 rounded-xl border border-gray-200 p-3 dark:border-gray-800 sm:grid-cols-12">
                    <Field label={t('products.unitName')} className="sm:col-span-3"><Input list="unit-suggestions" value={u.name} disabled={u.used} onChange={(e) => setUnit(u.key, { name: e.target.value })} placeholder="carton" /></Field>
                    <Field label={t('products.unitFactor', { unit: f.base_unit })} className="sm:col-span-3" hint={u.used ? t('products.unitLocked') : undefined}><Input type="number" min="0" step="any" value={u.factor} disabled={u.used} onChange={(e) => setUnit(u.key, { factor: e.target.value })} placeholder="24" /></Field>
                    <Field label={t('products.unitPrice')} optional className="sm:col-span-3"><Input type="number" min="0" step="any" value={u.selling_price} onChange={(e) => setUnit(u.key, { selling_price: e.target.value })} placeholder={toNumber(u.factor) && toNumber(f.selling_price) ? String(toNumber(u.factor) * toNumber(f.selling_price)) : ''} suffix="FCFA" /></Field>
                    <Field label={t('products.barcode')} optional className="sm:col-span-3"><Input value={u.barcode} onChange={(e) => setUnit(u.key, { barcode: e.target.value })} /></Field>
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
          </div>
        </Section>
        {isParent && <Alert tone="blue">{t('catalog.variantParentNote')}</Alert>}
        <div className="flex justify-end"><Button type="submit" size="lg" loading={busy}>{t('common.save')}</Button></div>
      </div>
    </form>
  );
}
