// Where one delivery area delivers: whole regions, and/or specific towns and localities from the maintained list.
// Used in the seller's zone editor. A town is stored by its key (the same key the checkout matches against).
import { useState } from 'react';
import { useI18n } from '../i18n';
import { cityKey } from '../lib/cities';
import { regionName, useMarketLocations } from '../lib/locations';
import { Checkbox, Input } from './ui';

export function DeliveryAreaPicker({ regions, localities, onChange }: {
  regions: string[]; localities: string[]; onChange: (next: { regions: string[]; localities: string[] }) => void;
}) {
  const { t, lang } = useI18n();
  const locs = useMarketLocations();
  const [q, setQ] = useState('');
  const needle = cityKey(q);
  const toggle = (list: string[], value: string) => (list.includes(value) ? list.filter((x) => x !== value) : [...list, value]);
  const towns = (locs.data?.localities ?? []).filter((l) => !needle || l.key.includes(needle)).slice(0, 60);
  const regionOf = (code: string) => locs.data?.regions.find((r) => r.code === code);

  return (
    <div className="space-y-3">
      <div>
        <p className="mb-1.5 text-sm font-medium text-ink-soft dark:text-gray-300">{t('seller.store.areaRegions')}</p>
        <div className="grid grid-cols-2 gap-x-4 gap-y-2 sm:grid-cols-3">
          {(locs.data?.regions ?? []).map((r) => (
            <Checkbox key={r.code} label={regionName(r, lang)} checked={regions.includes(r.code)}
              onChange={() => onChange({ regions: toggle(regions, r.code), localities })} />
          ))}
        </div>
      </div>
      <div>
        <p className="mb-1.5 text-sm font-medium text-ink-soft dark:text-gray-300">{t('seller.store.areaTowns')}</p>
        <Input type="search" value={q} onChange={(e) => setQ(e.target.value)} placeholder={t('seller.store.areaSearch')} aria-label={t('seller.store.areaSearch')} />
        <div className="mt-2 grid max-h-56 grid-cols-1 gap-y-1.5 overflow-y-auto rounded-xl border border-gray-200 p-2 sm:grid-cols-2 dark:border-gray-800">
          {towns.map((l) => (
            <Checkbox key={l.key} label={`${l.name} · ${regionName(regionOf(l.region) ?? { code: l.region, name_en: l.region, name_fr: l.region }, lang)}`}
              checked={localities.includes(l.key)} onChange={() => onChange({ regions, localities: toggle(localities, l.key) })} />
          ))}
          {towns.length === 0 && <p className="col-span-full py-3 text-center text-sm text-ink-muted">{t('seller.store.areaNoTown')}</p>}
        </div>
        <p className="mt-1.5 text-xs text-ink-muted">{t('seller.store.areaSummary', { regions: regions.length, towns: localities.length })}</p>
      </div>
    </div>
  );
}
