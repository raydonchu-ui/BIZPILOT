// Regions and localities of Cameroon for delivery. The list is maintained in the database (market_locations) and
// the checkout falls back to typed entry when it is not available. A delivery area serves a location when it names
// no region and no locality (older areas), or when it names the customer's region, or the customer's town.
import { useQuery } from '@tanstack/react-query';
import { rpc } from './api';
import { cityKey } from './cities';

export interface RegionRow { code: string; name_en: string; name_fr: string }
export interface LocalityRow { region: string; name: string; key: string }
export interface ZoneCoverage { regions?: string[] | null; localities?: string[] | null }

export function zoneServes(zone: ZoneCoverage, region: string, city: string): boolean {
  const regions = zone.regions ?? [];
  const localities = zone.localities ?? [];
  if (regions.length === 0 && localities.length === 0) return true;
  return regions.includes(region) || localities.includes(cityKey(city));
}

export function regionName(r: RegionRow, lang: 'en' | 'fr') {
  return lang === 'fr' ? r.name_fr : r.name_en;
}

export function useMarketLocations() {
  return useQuery({
    queryKey: ['market-locations'],
    queryFn: () => rpc<{ regions: RegionRow[]; localities: LocalityRow[] }>('market_locations'),
    staleTime: 60 * 60_000,
    retry: false,
  });
}
