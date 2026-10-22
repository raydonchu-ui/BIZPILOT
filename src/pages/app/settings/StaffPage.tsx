import { useState } from 'react';
import { useQuery } from '@tanstack/react-query';
import { Mail, ShieldCheck, UserPlus } from 'lucide-react';
import { useI18n } from '../../../i18n';
import { useBiz } from '../../../lib/business';
import { useAuth } from '../../../lib/auth';
import { supabase } from '../../../lib/supabase';
import { rpc, unwrap } from '../../../lib/api';
import { useAction } from '../../../lib/useAction';
import { formatDate } from '../../../lib/format';
import { Alert, Badge, Button, Card, CardHeader, Checkbox, ConfirmDialog, DataTable, ErrorState, Field, Input, Modal, PageHeader, PageLoader, Select, UpgradeNotice } from '../../../components/ui';

const ALL_PERMS = ['sales.create', 'sales.view', 'sales.refund', 'sales.discount_large', 'products.view', 'products.manage', 'inventory.view', 'stock.adjust',
  'purchases.manage', 'suppliers.manage', 'customers.manage', 'customers.credit', 'expenses.manage', 'reports.view', 'cash.manage', 'imports.manage'];
const DEFAULTS: Record<string, string[]> = {
  manager: ALL_PERMS,
  cashier: ['sales.create', 'sales.view', 'products.view', 'inventory.view', 'customers.manage'],
};

export default function StaffPage() {
  const { t, lang } = useI18n();
  const { id, has, limit } = useBiz();
  const { session } = useAuth();
  const { run, busy } = useAction();
  const [invite, setInvite] = useState(false);
  const [edit, setEdit] = useState<any | null>(null);
  const [transfer, setTransfer] = useState<any | null>(null);
  const members = useQuery({
    queryKey: ['members', id],
    queryFn: async () => {
      const rows = unwrap(await supabase.from('business_members').select('*').eq('business_id', id).order('created_at')) as any[];
      const profiles = unwrap(await supabase.from('profiles').select('id,full_name,phone').in('id', rows.map((r) => r.user_id))) as any[];
      return rows.map((r) => ({ ...r, profile: profiles.find((p) => p.id === r.user_id) }));
    },
  });
  const invites = useQuery({
    queryKey: ['invites', id],
    queryFn: async () => unwrap(await supabase.from('business_invites').select('*').eq('business_id', id).is('accepted_at', null).is('revoked_at', null).order('created_at', { ascending: false })) as any[],
  });
  if (!has('staff')) return <div><PageHeader title={t('nav.staff')} /><UpgradeNotice feature="staff" /></div>;
  if (members.isLoading) return <PageLoader />;
  if (members.error) return <ErrorState error={members.error} />;
  const max = limit('max_staff');
  const used = (members.data ?? []).filter((m) => m.active).length + (invites.data ?? []).length;
  return (
    <div>
      <PageHeader title={t('nav.staff')} subtitle={t('staff.subtitle')} actions={<Button icon={<UserPlus className="h-4 w-4" />} disabled={max !== null && used >= max} onClick={() => setInvite(true)}>{t('staff.invite')}</Button>} />
      {max !== null && <p className="mb-3 text-sm text-ink-muted">{t('staff.usage', { used, max })}</p>}
      <Card>
        <DataTable rows={members.data ?? []} rowKey={(r) => r.id} columns={[
          { key: 'n', header: t('common.name'), render: (m) => <div><p className="font-semibold">{m.display_name || m.profile?.full_name || '—'}{m.user_id === session?.user.id && <Badge tone="blue" className="ml-2">{t('staff.you')}</Badge>}</p><p className="text-xs text-ink-muted">{m.profile?.phone ?? ''}</p></div> },
          { key: 'r', header: t('staff.role'), render: (m) => <Badge tone={m.role === 'owner' ? 'green' : 'gray'}>{t(`roles.${m.role}`)}</Badge> },
          { key: 'c', header: t('staff.overrides'), hideOnMobile: true, render: (m) => Object.keys(m.permissions ?? {}).length ? <Badge tone="purple">{Object.keys(m.permissions).length}</Badge> : '—' },
          { key: 'a', header: t('common.status'), render: (m) => m.active ? <Badge tone="green">{t('common.active')}</Badge> : <Badge>{t('staff.deactivated')}</Badge> },
          { key: 'd', header: t('staff.since'), hideOnMobile: true, render: (m) => formatDate(m.created_at, lang) },
          { key: 'x', header: '', align: 'right', render: (m) => m.role !== 'owner' && m.user_id !== session?.user.id ? (
            <div className="flex justify-end gap-1">
              <Button size="sm" variant="ghost" onClick={() => setEdit(m)}>{t('common.edit')}</Button>
              {m.active && <Button size="sm" variant="ghost" icon={<ShieldCheck className="h-4 w-4" />} onClick={() => setTransfer(m)}>{t('staff.makeOwner')}</Button>}
            </div>) : null },
        ]} />
      </Card>
      {(invites.data ?? []).length > 0 && (
        <Card className="mt-4">
          <CardHeader title={t('staff.pendingInvites')} subtitle={t('staff.pendingHelp')} />
          <ul className="divide-y divide-gray-100 dark:divide-gray-800">
            {invites.data!.map((i) => (
              <li key={i.id} className="flex items-center gap-3 py-2.5 text-sm">
                <Mail className="h-4 w-4 text-ink-muted" /><span className="flex-1">{i.email} · {t(`roles.${i.role}`)}</span>
                <Button size="sm" variant="ghost" className="text-red-600" loading={busy} onClick={() => run(() => rpc('revoke_invite', { p_invite: i.id }), t('common.saved'))}>{t('staff.revoke')}</Button>
              </li>
            ))}
          </ul>
        </Card>
      )}
      {invite && <InviteModal onClose={() => setInvite(false)} />}
      {edit && <MemberModal member={edit} onClose={() => setEdit(null)} />}
      <ConfirmDialog open={Boolean(transfer)} onClose={() => setTransfer(null)} loading={busy} title={t('staff.transferTitle')}
        body={t('staff.transferBody', { name: transfer?.display_name || transfer?.profile?.full_name || '' })}
        onConfirm={async () => { await run(() => rpc('transfer_ownership', { p_business: id, p_member: transfer.id }), t('common.saved')); setTransfer(null); window.location.reload(); }} />
    </div>
  );
}

function PermissionGrid({ role, value, onChange }: { role: string; value: Record<string, boolean>; onChange: (v: Record<string, boolean>) => void }) {
  const { t } = useI18n();
  return (
    <div className="grid gap-2 sm:grid-cols-2">
      {ALL_PERMS.map((p) => {
        const dflt = DEFAULTS[role]?.includes(p) ?? false;
        const checked = p in value ? value[p] : dflt;
        return <Checkbox key={p} checked={checked} label={t(`permissions.${p}`)} hint={p in value ? t('staff.customised') : undefined}
          onChange={(v) => { const next = { ...value }; if (v === dflt) delete next[p]; else next[p] = v; onChange(next); }} />;
      })}
    </div>
  );
}

function InviteModal({ onClose }: { onClose: () => void }) {
  const { t } = useI18n();
  const { id } = useBiz();
  const { run, busy } = useAction();
  const [f, setF] = useState({ email: '', role: 'cashier', display_name: '' });
  const [perms, setPerms] = useState<Record<string, boolean>>({});
  const submit = async () => {
    const ok = await run(() => rpc('invite_member', { p_business: id, p_email: f.email, p_role: f.role, p_display_name: f.display_name || null, p_permissions: perms }), t('staff.invited'));
    if (ok) onClose();
  };
  return (
    <Modal open onClose={onClose} title={t('staff.invite')} size="lg" footer={<><Button variant="outline" onClick={onClose}>{t('common.cancel')}</Button><Button loading={busy} disabled={!f.email} onClick={submit}>{t('staff.sendInvite')}</Button></>}>
      <div className="space-y-4">
        <Alert tone="blue">{t('staff.inviteHelp')}</Alert>
        <div className="grid gap-3 sm:grid-cols-3">
          <Field label={t('common.email')} required className="sm:col-span-2"><Input type="email" value={f.email} onChange={(e) => setF({ ...f, email: e.target.value })} /></Field>
          <Field label={t('staff.role')}><Select value={f.role} onChange={(e) => { setF({ ...f, role: e.target.value }); setPerms({}); }}><option value="cashier">{t('roles.cashier')}</option><option value="manager">{t('roles.manager')}</option></Select></Field>
          <Field label={t('staff.displayName')} className="sm:col-span-3"><Input value={f.display_name} onChange={(e) => setF({ ...f, display_name: e.target.value })} /></Field>
        </div>
        <div><p className="mb-2 text-sm font-semibold">{t('staff.permissions')}</p><PermissionGrid role={f.role} value={perms} onChange={setPerms} /></div>
      </div>
    </Modal>
  );
}

function MemberModal({ member, onClose }: { member: any; onClose: () => void }) {
  const { t } = useI18n();
  const { run, busy } = useAction();
  const [role, setRole] = useState(member.role);
  const [perms, setPerms] = useState<Record<string, boolean>>(member.permissions ?? {});
  const [active, setActive] = useState(member.active);
  const [name, setName] = useState(member.display_name ?? '');
  const submit = async () => {
    const ok = await run(() => rpc('update_member', { p_member: member.id, p: { role, permissions: perms, active, display_name: name } }), t('common.saved'));
    if (ok !== undefined) onClose();
  };
  return (
    <Modal open onClose={onClose} title={t('staff.editMember')} size="lg" footer={<><Button variant="outline" onClick={onClose}>{t('common.cancel')}</Button><Button loading={busy} onClick={submit}>{t('common.save')}</Button></>}>
      <div className="space-y-4">
        <div className="grid gap-3 sm:grid-cols-2">
          <Field label={t('staff.displayName')}><Input value={name} onChange={(e) => setName(e.target.value)} /></Field>
          <Field label={t('staff.role')}><Select value={role} onChange={(e) => { setRole(e.target.value); setPerms({}); }}><option value="cashier">{t('roles.cashier')}</option><option value="manager">{t('roles.manager')}</option></Select></Field>
        </div>
        <Checkbox checked={active} onChange={setActive} label={t('common.active')} hint={t('staff.deactivateHint')} />
        <div><p className="mb-2 text-sm font-semibold">{t('staff.permissions')}</p><PermissionGrid role={role} value={perms} onChange={setPerms} /></div>
      </div>
    </Modal>
  );
}
