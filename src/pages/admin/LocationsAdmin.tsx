// Maintains the regions and towns that buyers and sellers choose from. A town's key is fixed by its name: a rename may
// correct spelling or accents, but not change the key that saved delivery areas and orders depend on.
import { FormEvent, useState } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { useI18n } from '../../i18n';
import { rpc } from '../../lib/api';
import { useAction } from '../../lib/useAction';
import { Badge, Button, Card, CardHeader, Checkbox, Field, Input, PageHeader, PageLoader, Select } from '../../components/ui';

export function LocationsAdmin() {
  const { t, lang } = useI18n();
  const { run, busy } = useAction();
  const qc = useQueryClient();
  const q = useQuery({ queryKey: ['admin-locations'], queryFn: () => rpc<any>('admin_locations_list') });
  const [region, setRegion] = useState('littoral');
  const [newName, setNewName] = useState('');
  const [edit, setEdit] = useState<Record<string, string>>({});
  if (q.isLoading) return <PageLoader />;
  const data = q.data ?? { regions: [], localities: [] };
  const refresh = () => qc.invalidateQueries({ queryKey: ['admin-locations'] });
  const add = async (e: FormEvent) => {
    e.preventDefault();
    const r = await run(() => rpc('admin_add_locality', { p_region: region, p_name: newName }), t('locations.added'));
    if (r !== undefined) { setNewName(''); refresh(); }
  };
  const rename = async (id: string) => {
    const r = await run(() => rpc('admin_update_locality', { p_id: id, p_name: edit[id] }), t('locations.saved'));
    if (r !== undefined) { setEdit((x) => ({ ...x, [id]: '' })); refresh(); }
  };
  const setActive = async (id: string, active: boolean) => {
    const r = await run(() => rpc('admin_update_locality', { p_id: id, p_active: active }), t('locations.saved'));
    if (r !== undefined) refresh();
  };
  const regionName = (r: any) => (lang === 'fr' ? r.name_fr : r.name_en);
  return (
    <div className="space-y-4">
      <PageHeader title={t('locations.title')} subtitle={t('locations.subtitle')} />
      <Card>
        <CardHeader title={t('locations.add')} subtitle={t('locations.addSub')} />
        <form onSubmit={add} className="grid gap-3 sm:grid-cols-[220px_minmax(0,1fr)_auto] sm:items-end">
          <Field label={t('locations.region')}>
            <Select value={region} onChange={(e) => setRegion(e.target.value)}>
              {data.regions.map((r: any) => <option key={r.code} value={r.code}>{regionName(r)}</option>)}
            </Select>
          </Field>
          <Field label={t('locations.town')} required><Input maxLength={80} value={newName} onChange={(e) => setNewName(e.target.value)} /></Field>
          <Button type="submit" loading={busy} disabled={newName.trim().length < 2}>{t('locations.addButton')}</Button>
        </form>
      </Card>
      {data.regions.map((r: any) => {
        const towns = data.localities.filter((l: any) => l.region === r.code);
        return (
          <Card key={r.code}>
            <CardHeader title={regionName(r)} subtitle={t('locations.count', { n: towns.length })} />
            <ul className="divide-y divide-gray-100 dark:divide-gray-800">
              {towns.map((l: any) => (
                <li key={l.id} className="flex flex-col gap-2 py-2 sm:flex-row sm:items-center sm:justify-between">
                  <div className="flex items-center gap-2">
                    <span className="font-medium">{l.name}</span>
                    {!l.active && <Badge tone="gray">{t('locations.hidden')}</Badge>}
                    <span className="font-mono text-xs text-ink-muted">{l.key}</span>
                  </div>
                  <div className="flex flex-wrap items-center gap-2">
                    <Input className="w-44" maxLength={80} aria-label={t('locations.newSpelling')} placeholder={l.name} value={edit[l.id] ?? ''}
                      onChange={(e) => setEdit((x) => ({ ...x, [l.id]: e.target.value }))} />
                    <Button size="sm" variant="outline" disabled={!edit[l.id]?.trim() || busy} onClick={() => rename(l.id)}>{t('locations.rename')}</Button>
                    <Checkbox label={t('locations.offered')} checked={l.active} disabled={busy} onChange={(v) => setActive(l.id, v)} />
                  </div>
                </li>
              ))}
            </ul>
          </Card>
        );
      })}
      <p className="text-sm text-ink-muted">{t('locations.note')}</p>
    </div>
  );
}
