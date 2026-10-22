import { useEffect, useRef, useState } from 'react';
import { useQuery } from '@tanstack/react-query';
import { Camera, ScanLine, Search } from 'lucide-react';
import { useI18n } from '../i18n';
import { supabase } from '../lib/supabase';
import { unwrap } from '../lib/api';
import { formatMoney, formatNumber } from '../lib/format';
import { Product } from '../lib/hooks';
import { Badge, Button, Input, Modal } from './ui';

const SELECT = 'id,name,sku,barcode,base_unit,allow_fraction,selling_price,purchase_cost,avg_cost,qty_on_hand,min_stock,track_expiry,status,image_path,product_units(id,name,factor,selling_price,barcode,is_default_purchase,is_default_sale,active)';

export function useProductSearch(businessId: string, term: string, opts: { activeOnly?: boolean } = {}) {
  return useQuery({
    queryKey: ['product-search', businessId, term, opts.activeOnly],
    queryFn: async () => {
      let q = supabase.from('products').select(SELECT).eq('business_id', businessId).order('name').limit(20);
      if (opts.activeOnly !== false) q = q.eq('status', 'active');
      const tt = term.trim();
      if (tt) {
        const like = `%${tt.replace(/[%_,()]/g, ' ')}%`;
        q = q.or(`name.ilike.${like},sku.ilike.${like},barcode.eq.${tt.replace(/[,()]/g, '')}`);
      }
      return unwrap(await q) as Product[];
    },
  });
}

/** Exact barcode lookup (product barcode or a unit's barcode). */
export async function findByBarcode(businessId: string, code: string): Promise<{ product: Product; unitId: string | null } | null> {
  const c = code.trim().replace(/[,()]/g, '');
  if (!c) return null;
  const { data: p } = await supabase.from('products').select(SELECT).eq('business_id', businessId).eq('status', 'active').or(`barcode.eq.${c},sku.ilike.${c}`).limit(1);
  if (p && p.length) return { product: p[0] as unknown as Product, unitId: null };
  const { data: u } = await supabase.from('product_units').select('id, product_id').eq('business_id', businessId).eq('barcode', c).limit(1);
  if (u && u.length) {
    const { data: p2 } = await supabase.from('products').select(SELECT).eq('id', u[0].product_id).single();
    if (p2) return { product: p2 as unknown as Product, unitId: u[0].id };
  }
  return null;
}

export function ProductPicker({ businessId, onPick, showCost, placeholder, offlineProducts, autoFocus }:
  { businessId: string; onPick: (p: Product, unitId?: string | null) => void; showCost?: boolean; placeholder?: string;
    offlineProducts?: Product[] | null; autoFocus?: boolean }) {
  const { t, lang } = useI18n();
  const [term, setTerm] = useState('');
  const [open, setOpen] = useState(false);
  const [scan, setScan] = useState(false);
  const { data, isFetching, isError } = useProductSearch(businessId, term);
  const ref = useRef<HTMLDivElement>(null);
  useEffect(() => {
    const close = (e: MouseEvent) => { if (ref.current && !ref.current.contains(e.target as Node)) setOpen(false); };
    document.addEventListener('mousedown', close);
    return () => document.removeEventListener('mousedown', close);
  }, []);
  // When offline, search the last cached catalogue instead.
  const list: Product[] = isError && offlineProducts
    ? offlineProducts.filter((p) => !term || p.name.toLowerCase().includes(term.toLowerCase()) || p.sku.toLowerCase().includes(term.toLowerCase()) || p.barcode === term).slice(0, 20)
    : data ?? [];
  const pick = (p: Product, unitId?: string | null) => { onPick(p, unitId); setTerm(''); setOpen(false); };
  const onEnter = async () => {
    // Barcode scanners type the code and press Enter.
    const hit = await findByBarcode(businessId, term).catch(() => null);
    if (hit) pick(hit.product, hit.unitId);
    else if (list.length === 1) pick(list[0]);
  };
  const hasCamera = typeof window !== 'undefined' && 'BarcodeDetector' in window && !!navigator.mediaDevices?.getUserMedia;
  return (
    <div className="relative" ref={ref}>
      <div className="flex gap-2">
        <div className="flex-1">
          <Input autoFocus={autoFocus} prefixIcon={<Search className="h-4 w-4" />} value={term} placeholder={placeholder ?? t('pos.searchProduct')}
            onFocus={() => setOpen(true)} onChange={(e) => { setTerm(e.target.value); setOpen(true); }}
            onKeyDown={(e) => { if (e.key === 'Enter') { e.preventDefault(); onEnter(); } }} aria-label={t('pos.searchProduct')} />
        </div>
        {hasCamera && <Button variant="outline" onClick={() => setScan(true)} aria-label={t('pos.scan')} icon={<Camera className="h-4 w-4" />}><span className="hidden sm:inline">{t('pos.scan')}</span></Button>}
      </div>
      {open && (
        <div className="absolute z-30 mt-1 max-h-80 w-full overflow-y-auto rounded-xl border border-gray-200 bg-white shadow-xl dark:border-gray-700 dark:bg-gray-900">
          {isFetching && !list.length && <p className="p-3 text-sm text-ink-muted">{t('common.loading')}</p>}
          {!isFetching && !list.length && <p className="p-3 text-sm text-ink-muted">{t('common.noResults')}</p>}
          {list.map((p) => (
            <button key={p.id} type="button" onClick={() => pick(p)} className="flex w-full items-center justify-between gap-3 px-3 py-2.5 text-left hover:bg-gray-50 dark:hover:bg-gray-800">
              <span className="min-w-0">
                <span className="block truncate text-sm font-semibold">{p.name}</span>
                <span className="block truncate text-xs text-ink-muted">{p.sku}{p.barcode ? ` · ${p.barcode}` : ''}</span>
              </span>
              <span className="shrink-0 text-right">
                <span className="block text-sm font-semibold tabular-nums">{formatMoney(showCost ? p.purchase_cost : p.selling_price, lang)}</span>
                <Badge tone={Number(p.qty_on_hand) <= 0 ? 'red' : Number(p.qty_on_hand) <= Number(p.min_stock) ? 'amber' : 'green'}>
                  {formatNumber(p.qty_on_hand, lang)} {p.base_unit}
                </Badge>
              </span>
            </button>
          ))}
        </div>
      )}
      {scan && <CameraScanner onClose={() => setScan(false)} onCode={async (code) => {
        setScan(false);
        const hit = await findByBarcode(businessId, code).catch(() => null);
        if (hit) pick(hit.product, hit.unitId); else { setTerm(code); setOpen(true); }
      }} />}
    </div>
  );
}

function CameraScanner({ onClose, onCode }: { onClose: () => void; onCode: (c: string) => void }) {
  const { t } = useI18n();
  const video = useRef<HTMLVideoElement>(null);
  const [err, setErr] = useState<string | null>(null);
  useEffect(() => {
    let stream: MediaStream | null = null;
    let stop = false;
    (async () => {
      try {
        stream = await navigator.mediaDevices.getUserMedia({ video: { facingMode: 'environment' } });
        if (!video.current) return;
        video.current.srcObject = stream;
        await video.current.play();
        const Detector = (window as any).BarcodeDetector;
        const det = new Detector({ formats: ['ean_13', 'ean_8', 'upc_a', 'upc_e', 'code_128', 'code_39', 'qr_code'] });
        const loop = async () => {
          if (stop || !video.current) return;
          try {
            const codes = await det.detect(video.current);
            if (codes.length) { onCode(codes[0].rawValue); return; }
          } catch { /* frame not ready */ }
          requestAnimationFrame(loop);
        };
        loop();
      } catch {
        setErr(t('pos.cameraError'));
      }
    })();
    return () => { stop = true; stream?.getTracks().forEach((tr) => tr.stop()); };
  }, [onCode, t]);
  return (
    <Modal open onClose={onClose} title={<span className="flex items-center gap-2"><ScanLine className="h-5 w-5" />{t('pos.scan')}</span>}>
      {err ? <p className="text-sm text-red-600">{err}</p> : <video ref={video} className="aspect-video w-full rounded-xl bg-black object-cover" muted playsInline />}
    </Modal>
  );
}
