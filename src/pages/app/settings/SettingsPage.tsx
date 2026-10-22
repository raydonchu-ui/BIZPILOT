import { useEffect, useState } from 'react';
import { useSearchParams } from 'react-router-dom';
import { useQuery } from '@tanstack/react-query';
import { Download, ImagePlus, LifeBuoy, ShieldAlert } from 'lucide-react';
import { useI18n } from '../../../i18n';
import { useBiz } from '../../../lib/business';
import { useAuth } from '../../../lib/auth';
import { supabase } from '../../../lib/supabase';
import { rpc, unwrap } from '../../../lib/api';
import { useAction } from '../../../lib/useAction';
import { uploadFile, useBusinessRow, useSettings, useSignedUrl } from '../../../lib/hooks';
import { downloadText } from '../../../lib/csv';
import { formatDateTime, toNumber } from '../../../lib/format';
import { Alert, Badge, Button, Card, CardHeader, Checkbox, ErrorState, Field, Input, LinkButton, PageHeader, PageLoader, Select, Tabs, Textarea } from '../../../components/ui';

type Tab = 'business' | 'operations' | 'receipts' | 'data' | 'audit';

export default function SettingsPage() {
  const { t } = useI18n();
  const { can } = useBiz();
  const [params, setParams] = useSearchParams();
  const tab = (params.get('tab') as Tab) || 'business';
  if (!can('settings.manage')) return <ErrorState error={{ message: 'permission_denied' }} />;
  return (
    <div>
      <PageHeader title={t('nav.settings')} subtitle={t('settings.subtitle')} />
      <Tabs className="mb-4" value={tab} onChange={(v) => setParams({ tab: v })} items={[
        { value: 'business', label: t('settings.tabBusiness') }, { value: 'operations', label: t('settings.tabOperations') },
        { value: 'receipts', label: t('settings.tabReceipts') }, { value: 'data', label: t('settings.tabData') }, { value: 'audit', label: t('settings.tabAudit'), hidden: !can('audit.view') }]} />
      {tab === 'business' && <BusinessTab />}
      {tab === 'operations' && <OperationsTab />}
      {tab === 'receipts' && <ReceiptsTab />}
      {tab === 'data' && <DataTab />}
      {tab === 'audit' && <AuditTab />}
    </div>
  );
}

function BusinessTab() {
  const { t } = useI18n();
  const { id } = useBiz();
  const { refreshContext } = useAuth();
  const b = useBusinessRow(id);
  const { run, busy } = useAction();
  const [f, setF] = useState<any>(null);
  useEffect(() => { if (b.data) setF({ ...b.data }); }, [b.data]);
  const logo = useSignedUrl(f?.logo_path);
  if (!f) return <PageLoader />;
  const set = (k: string) => (e: { target: { value: string } }) => setF((x: any) => ({ ...x, [k]: e.target.value }));
  const save = async () => {
    await run(() => rpc('update_business', { p_business: id, p: { name: f.name, owner_name: f.owner_name, email: f.email, phone: f.phone, address: f.address, city: f.city,
      language: f.language, category: f.category, logo_path: f.logo_path ?? '', tax_id: f.tax_id, trade_register: f.trade_register, reporting_start_date: f.reporting_start_date } }), t('common.saved'));
    refreshContext();
  };
  const onLogo = async (file?: File) => { if (!file) return; const p = await run(() => uploadFile(id, 'logos', file)); if (p) setF((x: any) => ({ ...x, logo_path: p })); };
  return (
    <div className="grid gap-4 lg:grid-cols-3">
      <Card className="lg:col-span-2">
        <div className="grid gap-4 sm:grid-cols-2">
          <Field label={t('onboarding.businessName')} required className="sm:col-span-2"><Input value={f.name ?? ''} onChange={set('name')} /></Field>
          <Field label={t('onboarding.ownerName')}><Input value={f.owner_name ?? ''} onChange={set('owner_name')} /></Field>
          <Field label={t('onboarding.category')}><Select value={f.category} onChange={set('category')}>{['grocery', 'general', 'drinks', 'hardware', 'electronics', 'fashion', 'cosmetics', 'other'].map((c) => <option key={c} value={c}>{t(`businessCategories.${c}`)}</option>)}</Select></Field>
          <Field label={t('onboarding.businessPhone')}><Input value={f.phone ?? ''} onChange={set('phone')} /></Field>
          <Field label={t('onboarding.businessEmail')}><Input value={f.email ?? ''} onChange={set('email')} /></Field>
          <Field label={t('onboarding.city')}><Input value={f.city ?? ''} onChange={set('city')} /></Field>
          <Field label={t('onboarding.address')}><Input value={f.address ?? ''} onChange={set('address')} /></Field>
          <Field label={t('settings.taxId')} hint={t('settings.taxIdHint')}><Input value={f.tax_id ?? ''} onChange={set('tax_id')} /></Field>
          <Field label={t('settings.tradeRegister')}><Input value={f.trade_register ?? ''} onChange={set('trade_register')} /></Field>
          <Field label={t('onboarding.language')}><Select value={f.language} onChange={set('language')}><option value="fr">Français</option><option value="en">English</option></Select></Field>
          <Field label={t('onboarding.reportingStart')}><Input type="date" value={f.reporting_start_date ?? ''} onChange={set('reporting_start_date')} /></Field>
          <Field label={t('onboarding.country')}><Input disabled value={`${f.country_code} · ${f.currency}`} /></Field>
        </div>
        <div className="mt-5 flex justify-end"><Button loading={busy} onClick={save}>{t('common.save')}</Button></div>
      </Card>
      <Card>
        <CardHeader title={t('settings.logo')} subtitle={t('settings.logoHint')} />
        <label className="flex aspect-[3/2] cursor-pointer flex-col items-center justify-center gap-2 overflow-hidden rounded-xl border-2 border-dashed border-gray-300 text-sm text-ink-muted hover:border-brand-500 dark:border-gray-700">
          {logo.data ? <img src={logo.data} alt="" className="h-full w-full object-contain p-2" /> : <><ImagePlus className="h-8 w-8" />{t('settings.uploadLogo')}</>}
          <input type="file" accept="image/png,image/jpeg,image/webp" className="sr-only" onChange={(e) => onLogo(e.target.files?.[0])} />
        </label>
        <p className="mt-2 text-xs text-ink-muted">{t('settings.logoSaveNote')}</p>
      </Card>
    </div>
  );
}

function OperationsTab() {
  const { t } = useI18n();
  const { id } = useBiz();
  const s = useSettings(id);
  const { run, busy } = useAction();
  const [f, setF] = useState<any>(null);
  useEffect(() => { if (s.data) setF({ ...s.data }); }, [s.data]);
  if (!f) return <PageLoader />;
  const num = (k: string) => (e: { target: { value: string } }) => setF((x: any) => ({ ...x, [k]: e.target.value }));
  const save = () => run(() => rpc('update_business_settings', { p_business: id, p: {
    allow_negative_stock: f.allow_negative_stock, cashier_max_discount_pct: toNumber(f.cashier_max_discount_pct), allow_credit_sales: f.allow_credit_sales,
    tax_enabled: f.tax_enabled, tax_rate: toNumber(f.tax_rate), tax_label: f.tax_label, default_lead_time_days: toNumber(f.default_lead_time_days),
    safety_stock_days: toNumber(f.safety_stock_days), planning_days: toNumber(f.planning_days), slow_moving_days: toNumber(f.slow_moving_days),
    expiry_alert_days: toNumber(f.expiry_alert_days), weak_margin_pct: toNumber(f.weak_margin_pct) } }), t('common.saved'));
  return (
    <div className="grid gap-4 lg:grid-cols-2">
      <Card>
        <CardHeader title={t('settings.salesRules')} />
        <div className="space-y-4">
          <Field label={t('settings.maxDiscount')} hint={t('settings.maxDiscountHint')}><Input type="number" min="0" max="100" value={f.cashier_max_discount_pct} onChange={num('cashier_max_discount_pct')} suffix="%" /></Field>
          <Checkbox checked={f.allow_credit_sales} onChange={(v) => setF({ ...f, allow_credit_sales: v })} label={t('settings.allowCredit')} hint={t('settings.allowCreditHint')} />
          <Checkbox checked={f.allow_negative_stock} onChange={(v) => setF({ ...f, allow_negative_stock: v })} label={t('settings.allowNegative')} hint={t('settings.allowNegativeHint')} />
          {f.allow_negative_stock && <Alert tone="amber">{t('settings.negativeWarning')}</Alert>}
        </div>
      </Card>
      <Card>
        <CardHeader title={t('settings.tax')} subtitle={t('settings.taxSub')} />
        <div className="space-y-4">
          <Checkbox checked={f.tax_enabled} onChange={(v) => setF({ ...f, tax_enabled: v })} label={t('settings.taxEnabled')} hint={t('settings.taxEnabledHint')} />
          <div className="grid grid-cols-2 gap-3">
            <Field label={t('settings.taxLabel')}><Input value={f.tax_label} onChange={num('tax_label')} /></Field>
            <Field label={t('settings.taxRate')}><Input type="number" min="0" max="100" step="0.01" value={f.tax_rate} onChange={num('tax_rate')} suffix="%" /></Field>
          </div>
          <Alert tone="blue">{t('settings.taxDisclaimer')}</Alert>
        </div>
      </Card>
      <Card className="lg:col-span-2">
        <CardHeader title={t('settings.analyticsRules')} subtitle={t('settings.analyticsRulesSub')} />
        <div className="grid gap-4 sm:grid-cols-3">
          <Field label={t('settings.leadTime')} hint={t('settings.leadTimeHint')}><Input type="number" min="0" value={f.default_lead_time_days} onChange={num('default_lead_time_days')} suffix={t('common.days')} /></Field>
          <Field label={t('settings.safetyDays')} hint={t('settings.safetyDaysHint')}><Input type="number" min="0" value={f.safety_stock_days} onChange={num('safety_stock_days')} suffix={t('common.days')} /></Field>
          <Field label={t('settings.planningDays')} hint={t('settings.planningDaysHint')}><Input type="number" min="1" value={f.planning_days} onChange={num('planning_days')} suffix={t('common.days')} /></Field>
          <Field label={t('settings.slowDays')} hint={t('settings.slowDaysHint')}><Input type="number" min="7" value={f.slow_moving_days} onChange={num('slow_moving_days')} suffix={t('common.days')} /></Field>
          <Field label={t('settings.expiryDays')}><Input type="number" min="1" value={f.expiry_alert_days} onChange={num('expiry_alert_days')} suffix={t('common.days')} /></Field>
          <Field label={t('settings.weakMargin')} hint={t('settings.weakMarginHint')}><Input type="number" value={f.weak_margin_pct} onChange={num('weak_margin_pct')} suffix="%" /></Field>
        </div>
      </Card>
      <div className="lg:col-span-2 flex justify-end"><Button loading={busy} onClick={save}>{t('common.save')}</Button></div>
    </div>
  );
}

function ReceiptsTab() {
  const { t } = useI18n();
  const { id } = useBiz();
  const s = useSettings(id);
  const { run, busy } = useAction();
  const [h, setH] = useState(''); const [fo, setFo] = useState('');
  useEffect(() => { if (s.data) { setH(s.data.receipt_header ?? ''); setFo(s.data.receipt_footer ?? ''); } }, [s.data]);
  return (
    <Card className="max-w-2xl">
      <CardHeader title={t('settings.receiptTemplate')} subtitle={t('settings.receiptTemplateSub')} />
      <div className="space-y-4">
        <Field label={t('settings.receiptHeader')}><Textarea rows={3} value={h} onChange={(e) => setH(e.target.value)} /></Field>
        <Field label={t('settings.receiptFooter')}><Textarea rows={3} value={fo} onChange={(e) => setFo(e.target.value)} /></Field>
        <Alert tone="amber">{t('settings.receiptDisclaimer')}</Alert>
        <div className="flex justify-end"><Button loading={busy} onClick={() => run(() => rpc('update_business_settings', { p_business: id, p: { receipt_header: h, receipt_footer: fo } }), t('common.saved'))}>{t('common.save')}</Button></div>
      </div>
    </Card>
  );
}

function DataTab() {
  const { t, lang } = useI18n();
  const { id, biz } = useBiz();
  const { run, busy } = useAction();
  const [hours, setHours] = useState('24');
  const [reason, setReason] = useState('');
  const grants = useQuery({ queryKey: ['grants', id], queryFn: async () => unwrap(await supabase.from('support_access_grants').select('*').eq('business_id', id).order('created_at', { ascending: false }).limit(10)) as any[] });
  const exportJson = async () => {
    const data = await run(() => rpc('export_business_data', { p_business: id }));
    if (data) downloadText(`bizpilot-export-${biz.name.replace(/\W+/g, '-')}-${new Date().toISOString().slice(0, 10)}.json`, JSON.stringify(data, null, 2), 'application/json');
  };
  const activeGrant = (grants.data ?? []).find((g) => !g.revoked_at && new Date(g.expires_at) > new Date());
  return (
    <div className="grid gap-4 lg:grid-cols-2">
      <Card>
        <CardHeader title={t('settings.exportTitle')} subtitle={t('settings.exportSub')} />
        <Button icon={<Download className="h-4 w-4" />} loading={busy} onClick={exportJson}>{t('settings.exportAll')}</Button>
        <p className="mt-3 text-xs text-ink-muted">{t('settings.exportCsvHint')}</p>
        <div className="mt-4"><LinkButton variant="outline" to="/app/import">{t('nav.import')}</LinkButton></div>
      </Card>
      <Card>
        <CardHeader title={<span className="flex items-center gap-2"><LifeBuoy className="h-5 w-5" />{t('settings.supportAccess')}</span>} subtitle={t('settings.supportAccessSub')} />
        {activeGrant ? (
          <div className="space-y-3">
            <Alert tone="amber">{t('settings.supportActive', { until: formatDateTime(activeGrant.expires_at, lang) })}</Alert>
            <Button variant="danger" loading={busy} onClick={() => run(() => rpc('revoke_support_access', { p_grant: activeGrant.id }), t('common.saved'))}>{t('settings.revokeAccess')}</Button>
          </div>
        ) : (
          <div className="space-y-3">
            <div className="grid grid-cols-3 gap-3">
              <Field label={t('settings.duration')}><Select value={hours} onChange={(e) => setHours(e.target.value)}>{['2', '24', '72'].map((h) => <option key={h} value={h}>{t('settings.hours', { n: h })}</option>)}</Select></Field>
              <Field label={t('common.reason')} className="col-span-2"><Input value={reason} onChange={(e) => setReason(e.target.value)} /></Field>
            </div>
            <Button variant="outline" loading={busy} disabled={!reason.trim()} onClick={() => run(() => rpc('grant_support_access', { p_business: id, p_hours: toNumber(hours), p_reason: reason }), t('common.saved'))}>{t('settings.grantAccess')}</Button>
          </div>
        )}
        {(grants.data ?? []).length > 0 && <ul className="mt-4 space-y-1 text-xs text-ink-muted">{grants.data!.map((g) => <li key={g.id}>{formatDateTime(g.created_at, lang)} · {g.reason} {g.revoked_at ? <Badge>{t('settings.revoked')}</Badge> : null}</li>)}</ul>}
      </Card>
      <Card className="lg:col-span-2 border-red-200 dark:border-red-900">
        <CardHeader title={<span className="flex items-center gap-2 text-red-700"><ShieldAlert className="h-5 w-5" />{t('settings.closeTitle')}</span>} subtitle={t('settings.closeSub')} />
        <LinkButton variant="outline" to="/app/help?topic=account_closure">{t('settings.requestClosure')}</LinkButton>
      </Card>
    </div>
  );
}

function AuditTab() {
  const { t, lang } = useI18n();
  const { id } = useBiz();
  const [action, setAction] = useState('');
  const { data, isLoading } = useQuery({
    queryKey: ['audit', id, action],
    queryFn: async () => {
      let q = supabase.from('audit_logs').select('*').eq('business_id', id).order('created_at', { ascending: false }).limit(200);
      if (action) q = q.ilike('action', `${action}%`);
      const rows = unwrap(await q) as any[];
      const ids = [...new Set(rows.map((r) => r.user_id).filter(Boolean))];
      const profiles = ids.length ? unwrap(await supabase.from('profiles').select('id,full_name').in('id', ids)) as any[] : [];
      return rows.map((r) => ({ ...r, who: profiles.find((p) => p.id === r.user_id)?.full_name ?? (r.user_id ? '—' : 'BizPilot') }));
    },
  });
  return (
    <Card>
      <div className="mb-3"><Select className="w-56" value={action} onChange={(e) => setAction(e.target.value)}>
        <option value="">{t('common.all')}</option>{['sale', 'purchase', 'stock', 'expense', 'customer', 'supplier', 'staff', 'settings', 'billing', 'import', 'support_access', 'admin'].map((a) => <option key={a} value={a}>{a}</option>)}
      </Select></div>
      {isLoading ? <PageLoader /> : (
        <div className="-mx-4 overflow-x-auto sm:mx-0">
          <table className="min-w-full text-sm">
            <thead><tr className="text-left text-xs uppercase text-ink-muted"><th className="px-3 py-2">{t('common.date')}</th><th className="px-3 py-2">{t('common.by')}</th><th className="px-3 py-2">{t('settings.action')}</th><th className="px-3 py-2">{t('common.details')}</th></tr></thead>
            <tbody className="divide-y divide-gray-100 dark:divide-gray-800">
              {(data ?? []).map((r) => <tr key={r.id}><td className="whitespace-nowrap px-3 py-2">{formatDateTime(r.created_at, lang)}</td><td className="px-3 py-2">{r.who}</td><td className="px-3 py-2 font-mono text-xs">{r.action}</td><td className="max-w-md truncate px-3 py-2 font-mono text-xs text-ink-muted">{r.details ? JSON.stringify(r.details) : ''}</td></tr>)}
            </tbody>
          </table>
        </div>
      )}
    </Card>
  );
}
