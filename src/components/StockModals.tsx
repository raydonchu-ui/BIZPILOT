import { useEffect, useState } from 'react';
import { useQuery } from '@tanstack/react-query';
import { useI18n } from '../i18n';
import { useBiz } from '../lib/business';
import { rpc, unwrap } from '../lib/api';
import { supabase } from '../lib/supabase';
import { useAction } from '../lib/useAction';
import { newId } from '../lib/ids';
import { formatDate, formatNumber, toNumber } from '../lib/format';
import { Alert, Button, Checkbox, Field, Input, Modal, Select, Textarea } from './ui';

export function AdjustStockModal({ open, onClose, product }: { open: boolean; onClose: () => void; product: { id: string; name: string; base_unit: string; qty_on_hand: number; track_expiry: boolean } }) {
  const { t, lang } = useI18n();
  const { id } = useBiz();
  const { run, busy } = useAction();
  const [kind, setKind] = useState('damaged');
  const [qty, setQty] = useState('');
  const [reason, setReason] = useState('');
  const [batch, setBatch] = useState('');
  const [cost, setCost] = useState('');
  const [ref] = useState(newId);
  useEffect(() => { if (open) { setQty(''); setReason(''); setBatch(''); setCost(''); } }, [open]);
  const batches = useQuery({
    queryKey: ['batches', product.id], enabled: open && product.track_expiry,
    queryFn: async () => unwrap(await supabase.from('stock_batches').select('*').eq('product_id', product.id).gt('remaining_qty', 0).order('expiry_date')) as any[],
  });
  const signed = kind === 'found' ? toNumber(qty) : kind === 'correction' ? toNumber(qty) : -toNumber(qty);
  const submit = async () => {
    const ok = await run(() => rpc('adjust_stock', { p_business: id, p_product: product.id, p_kind: kind, p_quantity: kind === 'correction' ? toNumber(qty) : Math.abs(toNumber(qty)),
      p_reason: reason, p_batch: batch || null, p_unit_cost: kind === 'found' && cost ? toNumber(cost) : null, p_client_ref: ref }), t('inventory.adjusted'));
    if (ok !== undefined) onClose();
  };
  return (
    <Modal open={open} onClose={onClose} title={t('inventory.adjustTitle', { name: product.name })}
      footer={<><Button variant="outline" onClick={onClose}>{t('common.cancel')}</Button><Button loading={busy} disabled={!toNumber(qty) || !reason.trim()} onClick={submit}>{t('common.confirm')}</Button></>}>
      <div className="space-y-4">
        <p className="text-sm text-ink-muted">{t('inventory.currentStock')}: <b>{formatNumber(product.qty_on_hand, lang)} {product.base_unit}</b></p>
        <Field label={t('inventory.adjustType')}>
          <Select value={kind} onChange={(e) => setKind(e.target.value)}>
            {['damaged', 'expired', 'missing', 'found', 'correction'].map((k) => <option key={k} value={k}>{t(`movementTypes.${k}`)}</option>)}
          </Select>
        </Field>
        <Field label={kind === 'correction' ? t('inventory.correctionQty', { unit: product.base_unit }) : t('inventory.adjustQty', { unit: product.base_unit })}
          hint={kind === 'correction' ? t('inventory.correctionHint') : undefined}>
          <Input type="number" step="any" min={kind === 'correction' ? undefined : 0} value={qty} onChange={(e) => setQty(e.target.value)} />
        </Field>
        {kind === 'found' && <Field label={t('inventory.foundCost', { unit: product.base_unit })} hint={t('inventory.foundCostHint')}><Input type="number" min="0" step="any" value={cost} onChange={(e) => setCost(e.target.value)} suffix="FCFA" /></Field>}
        {product.track_expiry && (batches.data ?? []).length > 0 && (
          <Field label={t('inventory.batch')}>
            <Select value={batch} onChange={(e) => setBatch(e.target.value)}>
              <option value="">{t('inventory.anyBatch')}</option>
              {(batches.data ?? []).map((b) => <option key={b.id} value={b.id}>{b.batch_code ?? '—'} · {formatDate(b.expiry_date, lang)} · {formatNumber(b.remaining_qty, lang)}</option>)}
            </Select>
          </Field>
        )}
        <Field label={t('common.reason')} required><Textarea rows={2} value={reason} onChange={(e) => setReason(e.target.value)} placeholder={t('inventory.reasonPlaceholder')} /></Field>
        {toNumber(qty) !== 0 && <Alert tone="blue">{t('inventory.adjustPreview', { from: formatNumber(product.qty_on_hand, lang), to: formatNumber(Number(product.qty_on_hand) + signed, lang), unit: product.base_unit })}</Alert>}
      </div>
    </Modal>
  );
}

export function OpeningStockModal({ open, onClose, product }: { open: boolean; onClose: () => void; product: { id: string; name: string; base_unit: string; purchase_cost: number; track_expiry: boolean } }) {
  const { t } = useI18n();
  const { id } = useBiz();
  const { run, busy } = useAction();
  const [qty, setQty] = useState('');
  const [cost, setCost] = useState('');
  const [unknown, setUnknown] = useState(false);
  const [batch, setBatch] = useState('');
  const [expiry, setExpiry] = useState('');
  const [ref, setRef] = useState(newId);
  useEffect(() => { if (open) { setQty(''); setCost(String(product.purchase_cost || '')); setUnknown(false); setRef(newId()); } }, [open, product.purchase_cost]);
  const submit = async () => {
    const ok = await run(() => rpc('record_opening_stock', { p_business: id, p_product: product.id, p_quantity: toNumber(qty),
      p_unit_cost: unknown ? null : toNumber(cost), p_cost_known: !unknown, p_batch_code: batch || null, p_expiry: expiry || null, p_client_ref: ref }), t('common.saved'));
    if (ok !== undefined) onClose();
  };
  return (
    <Modal open={open} onClose={onClose} title={t('products.openingStock')}
      footer={<><Button variant="outline" onClick={onClose}>{t('common.cancel')}</Button><Button loading={busy} disabled={!(toNumber(qty) > 0)} onClick={submit}>{t('common.save')}</Button></>}>
      <div className="space-y-4">
        <p className="text-sm text-ink-muted">{t('products.openingStockSub')}</p>
        <Field label={t('products.openingQty', { unit: product.base_unit })}><Input type="number" min="0" step="any" value={qty} onChange={(e) => setQty(e.target.value)} /></Field>
        <Field label={t('products.openingCost', { unit: product.base_unit })} hint={unknown ? t('products.costUnknownHint') : undefined}><Input type="number" min="0" step="any" disabled={unknown} value={cost} onChange={(e) => setCost(e.target.value)} suffix="FCFA" /></Field>
        <Checkbox checked={unknown} onChange={setUnknown} label={t('products.costUnknown')} />
        {product.track_expiry && <div className="grid grid-cols-2 gap-3">
          <Field label={t('inventory.batchCode')}><Input value={batch} onChange={(e) => setBatch(e.target.value)} /></Field>
          <Field label={t('inventory.expiryDate')}><Input type="date" value={expiry} onChange={(e) => setExpiry(e.target.value)} /></Field>
        </div>}
      </div>
    </Modal>
  );
}
