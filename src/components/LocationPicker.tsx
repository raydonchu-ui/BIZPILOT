// Region, then town or locality: the region comes from the ten regions of Cameroon; the town is chosen from the
// maintained list for that region, or typed in when it is not listed. Works on small phone screens (one column).
import { useId } from 'react';
import { useI18n } from '../i18n';
import { cityKey } from '../lib/cities';
import { regionName, useMarketLocations } from '../lib/locations';
import { Field, Input, Select } from './ui';

export function LocationPicker({ region, city, onChange }: {
  region: string; city: string; onChange: (next: { region: string; city: string }) => void;
}) {
  const { t, lang } = useI18n();
  const locs = useMarketLocations();
  const listId = useId();
  const regions = locs.data?.regions ?? [];
  const inRegion = (locs.data?.localities ?? []).filter((l) => l.region === region);
  const needle = cityKey(city);
  const suggestions = inRegion.filter((l) => !needle || l.key.includes(needle)).slice(0, 8);
  const listed = inRegion.some((l) => l.key === needle);

  return (
    <div className="grid gap-4 sm:grid-cols-2">
      <Field label={t('market.loc.region')} htmlFor="loc-region" required className="sm:col-span-2">
        <Select id="loc-region" required value={region} onChange={(e) => onChange({ region: e.target.value, city: '' })}>
          <option value="">{t('market.loc.chooseRegion')}</option>
          {regions.map((r) => <option key={r.code} value={r.code}>{regionName(r, lang)}</option>)}
        </Select>
      </Field>
      <Field label={t('market.loc.town')} htmlFor="loc-town" required className="sm:col-span-2" hint={region ? t('market.loc.townHint') : t('market.loc.chooseRegionFirst')}>
        <Input id="loc-town" required value={city} disabled={!region} autoComplete="address-level2"
          placeholder={t('market.loc.townPlaceholder')} aria-autocomplete="list" aria-controls={listId}
          onChange={(e) => onChange({ region, city: e.target.value })} />
      </Field>
      {region && suggestions.length > 0 && needle && !listed && (
        <ul id={listId} aria-label={t('market.loc.suggestions')} className="sm:col-span-2 -mt-2 flex flex-wrap gap-2">
          {suggestions.map((l) => (
            <li key={l.key}>
              <button type="button" onClick={() => onChange({ region, city: l.name })}
                className="min-h-10 rounded-full bg-white px-3 text-sm font-semibold ring-1 ring-gray-200 hover:bg-brand-50 dark:bg-gray-900 dark:ring-gray-700">
                {l.name}
              </button>
            </li>
          ))}
        </ul>
      )}
      {region && needle && !listed && (
        <p className="sm:col-span-2 -mt-2 text-xs text-ink-muted">{t('market.loc.manualNote')}</p>
      )}
    </div>
  );
}
