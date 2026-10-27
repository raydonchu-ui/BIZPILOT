import { describe, expect, it } from 'vitest';
import { zoneServes } from './locations';

describe('zoneServes', () => {
  it('an area with no region and no locality serves every location (older areas are not changed)', () => {
    expect(zoneServes({ regions: [], localities: [] }, 'north', 'Garoua')).toBe(true);
    expect(zoneServes({ regions: null, localities: null }, '', '')).toBe(true);
  });

  it('an area for a region serves that region, including towns typed in by the customer', () => {
    const littoral = { regions: ['littoral'], localities: [] };
    expect(zoneServes(littoral, 'littoral', 'Douala')).toBe(true);
    expect(zoneServes(littoral, 'littoral', 'Mbanga')).toBe(true);
    expect(zoneServes(littoral, 'centre', 'Yaoundé')).toBe(false);
  });

  it('an area for towns serves those towns, whatever the accents or capitals', () => {
    const yaounde = { regions: [], localities: ['yaounde'] };
    expect(zoneServes(yaounde, 'centre', 'Yaoundé')).toBe(true);
    expect(zoneServes(yaounde, 'centre', 'YAOUNDE ')).toBe(true);
    expect(zoneServes(yaounde, 'centre', 'Mfou')).toBe(false);
  });
});
