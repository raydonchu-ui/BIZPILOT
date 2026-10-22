import { useState } from 'react';
import { useQuery } from '@tanstack/react-query';
import { ArrowLeftRight, CheckCircle2, Settings2 } from 'lucide-react';
import { useI18n } from '../../../i18n';
import { useBiz } from '../../../lib/business';
import { supabase } from '../../../lib/supabase';
import { rpc, unwrap, useRpc } from '../../../lib/api';
import { useAction } from '../../../lib/useAction';
import { useAccounts } from '../../../lib/hooks';
import { newId } from '../../../lib/ids';
import { localToday } from '../../../lib/dates';
import { formatDate, formatDateTime, toNumber } from '../../../lib/format';
import { Alert, Button, Card, CardHeader, DataTable, ErrorState, Field, Input, Modal, PageHeader, PageLoader, Select, Textarea, UpgradeNotice, useMoney } from '../../../components/ui';

export default function CashPage() {
  const { t, lang } = useI18n();
  const { id, biz, has } = useBiz();
  const money = useMoney();
  const { run, busy } = useAction();
  const [date, setDate] = useState(localToday(biz.timezone));
  const [counted, setCounted] = useState<Record<string, string>>({});
  const [notes, setNotes] = useState('');
  const [move, setMove] = useState(false);
  const [manage, setManage] = useState(false);
  const pos = useRpc<any[]>('cash_position', { p_business: id, p_date: date });
  const history = useQuery({
    queryKey: ['recons', id],
    queryFn: async () => unwrap(await supabase.from('cash_reconciliations').select('*, cash_reconciliation_lines(*, cash_accounts(name,kind))').eq('business_id', id).order('created_at', { ascending: false }).limit(30)) as any[],
  });
  const movements = useQuery({
    queryKey: ['cash-movements', id],
    queryFn: async () => unwrap(await supabase.from('cash_movements').select('*, from:from_account_id(name), to:to_account_id(name)').eq('business_id', id).order('occurred_at', { ascending: false }).limit(30)) as any[],
  });
  const save = async () => {
    const ok = await run(() => rpc('save_cash_reconciliation', { p_business: id, p_date: date, p_notes: notes || null,
      p_lines: Object.entries(counted).filter(([, v]) => v !== '').map(([account_id, v]) => ({ account_id, counted: toNumber(v) })) }), t('cash.reconSaved'));
    if (ok) { setCounted({}); setNotes(''); }
  };
  const rows = pos.data ?? [];
  return (
    <div>
      <PageHeader title={t('nav.cash')} subtitle={t('cash.subtitle')} actions={<>
        <Input type="date" value={date} max={localToday(biz.timezone)} onChange={(e) => setDate(e.target.value)} className="w-44" aria-label={t('common.date')} />
        <Button variant="outline" icon={<Settings2 className="h-4 w-4" />} onClick={() => setManage(true)}>{t('cash.accounts')}</Button>
        <Button icon={<ArrowLeftRight className="h-4 w-4" />} onClick={() => setMove(true)}>{t('cash.recordMovement')}</Button></>} />
      {pos.isLoading ? <PageLoader /> : pos.error ? <ErrorState error={pos.error} /> : (
        <Card>
          <CardHeader title={t('cash.position', { date: formatDate(date, lang) })} subtitle={t('cash.positionSub')} />
          <div className="-mx-4 overflow-x-auto sm:mx-0">
            <table className="min-w-full text-sm">
              <thead><tr className="text-left text-xs uppercase text-ink-muted">
                <th className="px-3 py-2">{t('cash.account')}</th><th className="px-3 py-2 text-right">{t('cash.opening')}</th><th className="px-3 py-2 text-right">{t('cash.salesIn')}</th>
                <th className="px-3 py-2 text-right">{t('cash.debtCollected')}</th><th className="px-3 py-2 text-right">{t('cash.paidOut')}</th><th className="px-3 py-2 text-right">{t('cash.transfers')}</th>
                <th className="px-3 py-2 text-right">{t('cash.expected')}</th>{has('cash_reconciliation') && <><th className="px-3 py-2 text-right">{t('cash.counted')}</th><th className="px-3 py-2 text-right">{t('cash.difference')}</th></>}
              </tr></thead>
              <tbody className="divide-y divide-gray-100 dark:divide-gray-800">
                {rows.map((a) => {
                  const out = Number(a.refunds_out) + Number(a.supplier_out) + Number(a.expenses_out);
                  const tr = Number(a.transfers_in) - Number(a.transfers_out);
                  const c = counted[a.account_id];
                  const diff = c === undefined || c === '' ? null : toNumber(c) - Number(a.expected);
                  return (
                    <tr key={a.account_id}>
                      <td className="px-3 py-2 font-semibold">{a.name}</td>
                      <td className="px-3 py-2 text-right tabular-nums">{money(a.opening)}</td>
                      <td className="px-3 py-2 text-right tabular-nums text-brand-700">{money(a.sales_in)}</td>
                      <td className="px-3 py-2 text-right tabular-nums text-brand-700">{money(Number(a.debt_collected) + Number(a.other_in))}</td>
                      <td className="px-3 py-2 text-right tabular-nums text-red-600">{out ? `− ${money(out)}` : money(0)}</td>
                      <td className="px-3 py-2 text-right tabular-nums">{money(tr)}</td>
                      <td className="px-3 py-2 text-right font-bold tabular-nums">{money(a.expected)}</td>
                      {has('cash_reconciliation') && <>
                        <td className="px-3 py-2 text-right"><Input type="number" step="any" className="ml-auto w-28 text-right" value={c ?? ''} onChange={(e) => setCounted((x) => ({ ...x, [a.account_id]: e.target.value }))} aria-label={t('cash.counted')} /></td>
                        <td className={`px-3 py-2 text-right font-semibold tabular-nums ${diff === null ? '' : diff < 0 ? 'text-red-600' : diff > 0 ? 'text-amber-600' : 'text-brand-700'}`}>{diff === null ? '—' : money(diff)}</td>
                      </>}
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
          {has('cash_reconciliation') ? (
            <div className="mt-4 flex flex-col gap-3 sm:flex-row sm:items-end">
              <Field label={t('common.notes')} className="flex-1"><Input value={notes} onChange={(e) => setNotes(e.target.value)} placeholder={t('cash.notesPlaceholder')} /></Field>
              <Button icon={<CheckCircle2 className="h-4 w-4" />} loading={busy} disabled={!Object.values(counted).some((v) => v !== '')} onClick={save}>{t('cash.saveRecon')}</Button>
            </div>
          ) : <div className="mt-4"><UpgradeNotice feature="cash_reconciliation" compact /></div>}
          <p className="mt-3 text-xs text-ink-muted">{t('cash.reconExplain')}</p>
        </Card>
      )}
      <div className="mt-4 grid gap-4 lg:grid-cols-2">
        <Card>
          <CardHeader title={t('cash.history')} />
          <DataTable rows={history.data ?? []} rowKey={(r) => r.id} dense empty={<p className="py-6 text-center text-sm text-ink-muted">{t('common.noData')}</p>} columns={[
            { key: 'd', header: t('common.date'), render: (r) => <div><p className="font-semibold">{formatDate(r.recon_date, lang)}</p><p className="text-xs text-ink-muted">{r.cash_reconciliation_lines.map((l: any) => l.cash_accounts?.name).join(', ')}</p></div> },
            { key: 'e', header: t('cash.expected'), align: 'right', render: (r) => money(r.total_expected) },
            { key: 'c', header: t('cash.counted'), align: 'right', render: (r) => money(r.total_counted) },
            { key: 'x', header: t('cash.difference'), align: 'right', render: (r) => <span className={Number(r.total_difference) < 0 ? 'font-semibold text-red-600' : Number(r.total_difference) > 0 ? 'text-amber-600' : 'text-brand-700'}>{money(r.total_difference)}</span> },
          ]} />
        </Card>
        <Card>
          <CardHeader title={t('cash.movements')} subtitle={t('cash.movementsSub')} />
          <DataTable rows={movements.data ?? []} rowKey={(r) => r.id} dense empty={<p className="py-6 text-center text-sm text-ink-muted">{t('common.noData')}</p>} columns={[
            { key: 'd', header: t('common.date'), render: (r) => formatDateTime(r.occurred_at, lang) },
            { key: 'k', header: t('common.type'), render: (r) => <div><p>{t(`cash.kinds.${r.kind}`)}</p><p className="text-xs text-ink-muted">{[r.from?.name, r.to?.name].filter(Boolean).join(' → ')}{r.note ? ` · ${r.note}` : ''}</p></div> },
            { key: 'a', header: t('common.amount'), align: 'right', render: (r) => money(r.amount) },
          ]} />
        </Card>
      </div>
      {move && <MovementModal onClose={() => setMove(false)} />}
      {manage && <AccountsModal onClose={() => setManage(false)} />}
    </div>
  );
}

function MovementModal({ onClose }: { onClose: () => void }) {
  const { t } = useI18n();
  const { id } = useBiz();
  const accounts = useAccounts(id);
  const { run, busy } = useAction();
  const [ref] = useState(newId);
  const [f, setF] = useState({ kind: 'transfer', from: '', to: '', amount: '', note: '', direction: 'in' });
  const submit = async () => {
    const from = f.kind === 'transfer' || f.kind === 'withdrawal' || (f.kind === 'adjustment' && f.direction === 'out') ? f.from : null;
    const to = f.kind === 'transfer' || f.kind === 'deposit' || (f.kind === 'adjustment' && f.direction === 'in') ? f.to : null;
    const ok = await run(() => rpc('record_cash_movement', { p_business: id, p_kind: f.kind, p_from: from || null, p_to: to || null, p_amount: toNumber(f.amount), p_note: f.note, p_client_ref: ref }), t('common.saved'));
    if (ok !== undefined) onClose();
  };
  const needsFrom = f.kind === 'transfer' || f.kind === 'withdrawal' || (f.kind === 'adjustment' && f.direction === 'out');
  const needsTo = f.kind === 'transfer' || f.kind === 'deposit' || (f.kind === 'adjustment' && f.direction === 'in');
  const accts = (accounts.data ?? []).filter((a) => a.active);
  return (
    <Modal open onClose={onClose} title={t('cash.recordMovement')} footer={<><Button variant="outline" onClick={onClose}>{t('common.cancel')}</Button><Button loading={busy} disabled={!(toNumber(f.amount) > 0) || (needsFrom && !f.from) || (needsTo && !f.to)} onClick={submit}>{t('common.save')}</Button></>}>
      <div className="space-y-3">
        <Field label={t('common.type')}><Select value={f.kind} onChange={(e) => setF({ ...f, kind: e.target.value })}>{['transfer', 'deposit', 'withdrawal', 'adjustment'].map((k) => <option key={k} value={k}>{t(`cash.kinds.${k}`)}</option>)}</Select></Field>
        <Alert tone="blue">{t(`cash.kindHelp.${f.kind}`)}</Alert>
        {f.kind === 'adjustment' && <Field label={t('cash.direction')}><Select value={f.direction} onChange={(e) => setF({ ...f, direction: e.target.value })}><option value="in">{t('cash.adjIn')}</option><option value="out">{t('cash.adjOut')}</option></Select></Field>}
        {needsFrom && <Field label={t('cash.fromAccount')}><Select value={f.from} onChange={(e) => setF({ ...f, from: e.target.value })}><option value="">—</option>{accts.map((a) => <option key={a.id} value={a.id}>{a.name}</option>)}</Select></Field>}
        {needsTo && <Field label={t('cash.toAccount')}><Select value={f.to} onChange={(e) => setF({ ...f, to: e.target.value })}><option value="">—</option>{accts.filter((a) => a.id !== f.from).map((a) => <option key={a.id} value={a.id}>{a.name}</option>)}</Select></Field>}
        <Field label={t('common.amount')}><Input type="number" min="0" step="any" value={f.amount} onChange={(e) => setF({ ...f, amount: e.target.value })} suffix="FCFA" /></Field>
        <Field label={t('common.notes')} required={f.kind !== 'transfer' && f.kind !== 'deposit'}><Textarea rows={2} value={f.note} onChange={(e) => setF({ ...f, note: e.target.value })} /></Field>
      </div>
    </Modal>
  );
}

function AccountsModal({ onClose }: { onClose: () => void }) {
  const { t } = useI18n();
  const { id } = useBiz();
  const accounts = useAccounts(id);
  const { run, busy } = useAction();
  const [edits, setEdits] = useState<Record<string, { name: string; opening_balance: string; active: boolean }>>({});
  const rows = accounts.data ?? [];
  const val = (a: any) => edits[a.id] ?? { name: a.name, opening_balance: String(a.opening_balance), active: a.active };
  const save = async () => {
    const ok = await run(async () => {
      for (const [aid, e] of Object.entries(edits)) unwrap(await supabase.from('cash_accounts').update({ name: e.name, opening_balance: toNumber(e.opening_balance), active: e.active }).eq('id', aid));
      return true;
    }, t('common.saved'));
    if (ok) onClose();
  };
  return (
    <Modal open onClose={onClose} title={t('cash.accounts')} footer={<><Button variant="outline" onClick={onClose}>{t('common.cancel')}</Button><Button loading={busy} onClick={save}>{t('common.save')}</Button></>}>
      <p className="mb-3 text-sm text-ink-muted">{t('cash.accountsHelp')}</p>
      <div className="space-y-3">
        {rows.map((a) => (
          <div key={a.id} className="grid grid-cols-5 items-end gap-2">
            <Field label={t(`accountKinds.${a.kind}`)} className="col-span-2"><Input value={val(a).name} onChange={(e) => setEdits((x) => ({ ...x, [a.id]: { ...val(a), name: e.target.value } }))} /></Field>
            <Field label={t('cash.openingBalance')} className="col-span-2"><Input type="number" step="any" value={val(a).opening_balance} onChange={(e) => setEdits((x) => ({ ...x, [a.id]: { ...val(a), opening_balance: e.target.value } }))} /></Field>
            <label className="flex items-center gap-1 pb-2 text-xs"><input type="checkbox" checked={val(a).active} onChange={(e) => setEdits((x) => ({ ...x, [a.id]: { ...val(a), active: e.target.checked } }))} />{t('common.active')}</label>
          </div>
        ))}
      </div>
    </Modal>
  );
}
