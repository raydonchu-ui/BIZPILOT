import { useState } from 'react';
import { useSearchParams } from 'react-router-dom';
import { useQuery } from '@tanstack/react-query';
import { Ban, CreditCard, Download, Paperclip, Plus, Receipt } from 'lucide-react';
import { useI18n } from '../../../i18n';
import { useBiz } from '../../../lib/business';
import { useAuth } from '../../../lib/auth';
import { supabase } from '../../../lib/supabase';
import { rpc, unwrap } from '../../../lib/api';
import { useAction } from '../../../lib/useAction';
import { attachFile, openFile } from '../../../lib/hooks';
import { newId } from '../../../lib/ids';
import { formatDate, toNumber } from '../../../lib/format';
import { downloadCsv } from '../../../lib/csv';
import { localToday } from '../../../lib/dates';
import { Alert, Badge, Button, Card, CardHeader, DataTable, EmptyState, ErrorState, Field, Input, Modal, PageHeader, PageLoader, Select, Textarea, Tone, UpgradeNotice, useMoney } from '../../../components/ui';
import { PeriodPicker, usePeriod } from '../../../components/PeriodPicker';
import { HBar } from '../../../components/charts';

export const EXPENSE_CATEGORIES = ['rent', 'salaries', 'utilities', 'transport', 'delivery', 'communication', 'packaging', 'repairs', 'marketing', 'bank_fees', 'taxes_licences', 'security', 'cleaning', 'other'];
const METHODS = ['cash', 'mtn_momo', 'orange_money', 'bank_transfer', 'card', 'other'];
const statusTone: Record<string, Tone> = { paid: 'green', partially_paid: 'amber', unpaid: 'red', voided: 'gray' };

export default function ExpensesPage() {
  const { t, lang } = useI18n();
  const { id, has } = useBiz();
  const money = useMoney();
  const [params, setParams] = useSearchParams();
  const [period, setPeriod] = usePeriod('this_month');
  const [cat, setCat] = useState('');
  const [status, setStatus] = useState('');
  const [payFor, setPayFor] = useState<any | null>(null);
  const [voidFor, setVoidFor] = useState<any | null>(null);
  const { data, isLoading, error, refetch } = useQuery({
    queryKey: ['expenses', id, period, cat, status],
    enabled: has('expenses'),
    queryFn: async () => {
      let q = supabase.from('expenses').select('*').eq('business_id', id).gte('expense_date', period.from).lte('expense_date', period.to).order('expense_date', { ascending: false }).order('created_at', { ascending: false }).limit(1000);
      if (cat) q = q.eq('category', cat);
      if (status) q = q.eq('status', status);
      return unwrap(await q) as any[];
    },
  });
  if (!has('expenses')) return <div><PageHeader title={t('nav.expenses')} /><UpgradeNotice feature="expenses" /></div>;
  const rows = data ?? [];
  const active = rows.filter((r) => r.status !== 'voided');
  const total = active.reduce((a, r) => a + Number(r.amount), 0);
  const unpaid = active.reduce((a, r) => a + Number(r.amount) - Number(r.paid_amount), 0);
  const byCat = EXPENSE_CATEGORIES.map((c) => ({ c, v: active.filter((r) => r.category === c).reduce((a, r) => a + Number(r.amount), 0) })).filter((x) => x.v > 0).sort((a, b) => b.v - a.v);
  return (
    <div>
      <PageHeader title={t('nav.expenses')} subtitle={t('expenses.subtitle')} actions={<>
        <PeriodPicker value={period} onChange={setPeriod} />
        <Button variant="outline" icon={<Download className="h-4 w-4" />} onClick={() => downloadCsv('bizpilot-expenses.csv', rows.map((r) => ({ number: r.number, date: r.expense_date, category: t(`expenseCategories.${r.category}`), description: r.description, payee: r.payee, amount: r.amount, paid: r.paid_amount, status: r.status, due_date: r.due_date })))}>{t('common.exportCsv')}</Button>
        <Button icon={<Plus className="h-4 w-4" />} onClick={() => setParams({ new: '1' })}>{t('nav.recordExpense')}</Button></>} />
      <div className="mb-4"><Alert tone="blue">{t('expenses.inventoryNote')}</Alert></div>
      <div className="grid gap-4 lg:grid-cols-3">
        <Card className="lg:col-span-2">
          <div className="mb-3 flex flex-col gap-3 sm:flex-row">
            <Select className="sm:w-56" value={cat} onChange={(e) => setCat(e.target.value)}><option value="">{t('expenses.allCategories')}</option>{EXPENSE_CATEGORIES.map((c) => <option key={c} value={c}>{t(`expenseCategories.${c}`)}</option>)}</Select>
            <Select className="sm:w-48" value={status} onChange={(e) => setStatus(e.target.value)}><option value="">{t('common.all')}</option>{Object.keys(statusTone).map((s) => <option key={s} value={s}>{t(`expenseStatus.${s}`)}</option>)}</Select>
          </div>
          {isLoading ? <PageLoader /> : error ? <ErrorState error={error} onRetry={() => refetch()} /> : (
            <DataTable rows={rows} rowKey={(r) => r.id} empty={<EmptyState icon={<Receipt className="h-6 w-6" />} title={t('expenses.empty')} body={t('expenses.emptyBody')} />} columns={[
              { key: 'd', header: t('common.date'), render: (r) => formatDate(r.expense_date, lang) },
              { key: 'x', header: t('common.description'), render: (r) => <div><p className="font-semibold">{r.description}</p><p className="text-xs text-ink-muted">{t(`expenseCategories.${r.category}`)}{r.payee ? ` · ${r.payee}` : ''}</p></div> },
              { key: 'a', header: t('common.amount'), align: 'right', render: (r) => <span className={r.status === 'voided' ? 'line-through opacity-60' : 'font-semibold'}>{money(r.amount)}</span> },
              { key: 's', header: t('common.status'), align: 'center', render: (r) => <Badge tone={statusTone[r.status]}>{t(`expenseStatus.${r.status}`)}</Badge> },
              { key: 'act', header: '', align: 'right', render: (r) => r.status === 'voided' ? null : (
                <div className="flex justify-end gap-1">
                  <AttachmentButton expense={r} />
                  {Number(r.paid_amount) < Number(r.amount) && <Button size="sm" variant="ghost" icon={<CreditCard className="h-4 w-4" />} onClick={() => setPayFor(r)}>{t('expenses.pay')}</Button>}
                  <Button size="sm" variant="ghost" icon={<Ban className="h-4 w-4" />} onClick={() => setVoidFor(r)} aria-label={t('expenses.void')} />
                </div>) },
            ]} />
          )}
        </Card>
        <Card>
          <CardHeader title={t('expenses.byCategory')} subtitle={`${formatDate(period.from, lang)} – ${formatDate(period.to, lang)}`} />
          <p className="text-3xl font-extrabold">{money(total)}</p>
          {unpaid > 0 && <p className="mt-1 text-sm text-red-600">{t('expenses.unpaidTotal', { amount: money(unpaid) })}</p>}
          <div className="mt-4 space-y-3">{byCat.map((x) => <HBar key={x.c} label={t(`expenseCategories.${x.c}`)} value={x.v} max={byCat[0]?.v ?? 1} color="#ef4444" right={money(x.v)} />)}</div>
        </Card>
      </div>
      <ExpenseModal open={params.get('new') === '1'} onClose={() => setParams({})} />
      {payFor && <PayExpenseModal expense={payFor} onClose={() => setPayFor(null)} />}
      {voidFor && <VoidExpenseModal expense={voidFor} onClose={() => setVoidFor(null)} />}
    </div>
  );
}

function AttachmentButton({ expense }: { expense: any }) {
  const { t } = useI18n();
  const { id } = useBiz();
  const { session } = useAuth();
  const { run } = useAction();
  const { data } = useQuery({ queryKey: ['attachments', 'expense', expense.id], queryFn: async () => unwrap(await supabase.from('attachments').select('*').eq('entity_type', 'expense').eq('entity_id', expense.id)) as any[] });
  if ((data ?? []).length) return <Button size="sm" variant="ghost" icon={<Paperclip className="h-4 w-4" />} onClick={() => openFile(data![0].path)} aria-label={t('expenses.viewReceipt')} />;
  return (
    <label className="inline-flex h-8 cursor-pointer items-center rounded-lg px-2 text-ink-muted hover:bg-gray-100 dark:hover:bg-gray-800" title={t('expenses.attachReceipt')}>
      <Paperclip className="h-4 w-4 opacity-50" />
      <input type="file" accept="image/*,application/pdf" className="sr-only" onChange={(e) => { const f = e.target.files?.[0]; if (f) run(() => attachFile(id, 'expense', expense.id, 'expenses', f, session!.user.id), t('common.saved')); }} />
    </label>
  );
}

function ExpenseModal({ open, onClose }: { open: boolean; onClose: () => void }) {
  const { t } = useI18n();
  const { id, biz } = useBiz();
  const { session } = useAuth();
  const { run, busy } = useAction();
  const [ref, setRef] = useState(newId);
  const [file, setFile] = useState<File | null>(null);
  const empty = { category: 'rent', description: '', amount: '', expense_date: localToday(biz.timezone), paid: 'full', paid_amount: '', method: 'cash', reference: '', payee: '', due_date: '', notes: '' };
  const [f, setF] = useState(empty);
  const set = (k: keyof typeof empty) => (e: { target: { value: string } }) => setF((x) => ({ ...x, [k]: e.target.value }));
  const submit = async () => {
    const paidAmount = f.paid === 'full' ? toNumber(f.amount) : f.paid === 'partial' ? toNumber(f.paid_amount) : 0;
    const eid = await run(async () => {
      const id2 = await rpc<string>('record_expense', { p_business: id, p: { client_ref: ref, category: f.category, description: f.description, amount: toNumber(f.amount),
        expense_date: f.expense_date, paid_amount: paidAmount, method: f.method, reference: f.reference || null, payee: f.payee || null, due_date: f.due_date || null, notes: f.notes || null } });
      if (file) await attachFile(id, 'expense', id2, 'expenses', file, session!.user.id);
      return id2;
    }, t('expenses.recorded'));
    if (eid) { setF(empty); setFile(null); setRef(newId()); onClose(); }
  };
  return (
    <Modal open={open} onClose={onClose} title={t('nav.recordExpense')} footer={<><Button variant="outline" onClick={onClose}>{t('common.cancel')}</Button><Button loading={busy} disabled={!f.description.trim() || !(toNumber(f.amount) > 0)} onClick={submit}>{t('common.save')}</Button></>}>
      <div className="grid gap-3 sm:grid-cols-2">
        <Field label={t('common.category')}><Select value={f.category} onChange={set('category')}>{EXPENSE_CATEGORIES.map((c) => <option key={c} value={c}>{t(`expenseCategories.${c}`)}</option>)}</Select></Field>
        <Field label={t('common.date')}><Input type="date" value={f.expense_date} onChange={set('expense_date')} /></Field>
        <Field label={t('common.description')} required className="sm:col-span-2"><Input value={f.description} onChange={set('description')} placeholder={t('expenses.descriptionPlaceholder')} /></Field>
        <Field label={t('common.amount')} required><Input type="number" min="0" step="any" value={f.amount} onChange={set('amount')} suffix="FCFA" /></Field>
        <Field label={t('expenses.payee')}><Input value={f.payee} onChange={set('payee')} /></Field>
        <Field label={t('expenses.paymentStatus')} className="sm:col-span-2">
          <Select value={f.paid} onChange={set('paid')}><option value="full">{t('expenses.paidInFull')}</option><option value="partial">{t('expenses.partlyPaid')}</option><option value="none">{t('expenses.notPaidYet')}</option></Select>
        </Field>
        {f.paid === 'partial' && <Field label={t('expenses.amountPaid')}><Input type="number" min="0" step="any" value={f.paid_amount} onChange={set('paid_amount')} suffix="FCFA" /></Field>}
        {f.paid !== 'none' && <>
          <Field label={t('common.method')}><Select value={f.method} onChange={set('method')}>{METHODS.map((m) => <option key={m} value={m}>{t(`methods.${m}`)}</option>)}</Select></Field>
          <Field label={t('common.reference')}><Input value={f.reference} onChange={set('reference')} /></Field>
        </>}
        {f.paid !== 'full' && <Field label={t('common.dueDate')}><Input type="date" value={f.due_date} onChange={set('due_date')} /></Field>}
        <Field label={t('expenses.receipt')} className="sm:col-span-2" hint={t('files.limits')}><Input type="file" accept="image/*,application/pdf" onChange={(e) => setFile(e.target.files?.[0] ?? null)} /></Field>
        <Field label={t('common.notes')} className="sm:col-span-2"><Textarea rows={2} value={f.notes} onChange={set('notes')} /></Field>
      </div>
    </Modal>
  );
}

function PayExpenseModal({ expense, onClose }: { expense: any; onClose: () => void }) {
  const { t } = useI18n();
  const { run, busy } = useAction();
  const [ref] = useState(newId);
  const [f, setF] = useState({ amount: String(Number(expense.amount) - Number(expense.paid_amount)), method: 'cash', reference: '' });
  const submit = async () => {
    const ok = await run(() => rpc('pay_expense', { p_expense: expense.id, p_amount: toNumber(f.amount), p_method: f.method, p_reference: f.reference || null, p_client_ref: ref }), t('common.saved'));
    if (ok !== undefined) onClose();
  };
  return (
    <Modal open onClose={onClose} title={t('expenses.pay')} size="sm" footer={<><Button variant="outline" onClick={onClose}>{t('common.cancel')}</Button><Button loading={busy} onClick={submit}>{t('common.save')}</Button></>}>
      <div className="space-y-3">
        <p className="text-sm text-ink-muted">{expense.description}</p>
        <Field label={t('common.amount')}><Input type="number" min="0" step="any" value={f.amount} onChange={(e) => setF({ ...f, amount: e.target.value })} suffix="FCFA" /></Field>
        <Field label={t('common.method')}><Select value={f.method} onChange={(e) => setF({ ...f, method: e.target.value })}>{METHODS.map((m) => <option key={m} value={m}>{t(`methods.${m}`)}</option>)}</Select></Field>
        <Field label={t('common.reference')}><Input value={f.reference} onChange={(e) => setF({ ...f, reference: e.target.value })} /></Field>
      </div>
    </Modal>
  );
}

function VoidExpenseModal({ expense, onClose }: { expense: any; onClose: () => void }) {
  const { t } = useI18n();
  const { run, busy } = useAction();
  const [reason, setReason] = useState('');
  const submit = async () => {
    const ok = await run(() => rpc('void_expense', { p_expense: expense.id, p_reason: reason }), t('common.saved'));
    if (ok !== undefined) onClose();
  };
  return (
    <Modal open onClose={onClose} title={t('expenses.void')} size="sm" footer={<><Button variant="outline" onClick={onClose}>{t('common.back')}</Button><Button variant="danger" loading={busy} disabled={!reason.trim()} onClick={submit}>{t('expenses.void')}</Button></>}>
      <p className="mb-3 text-sm text-ink-muted">{t('expenses.voidHelp')}</p>
      <Field label={t('common.reason')} required><Textarea rows={2} value={reason} onChange={(e) => setReason(e.target.value)} /></Field>
    </Modal>
  );
}
